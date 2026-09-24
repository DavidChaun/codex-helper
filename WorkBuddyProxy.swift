import Foundation
import Network

private let workBuddyPort: UInt16 = 58100
// 仅在验证时用环境变量换端口，正常运行始终是 58100。
private var proxyPort: UInt16 {
    ProcessInfo.processInfo.environment["CODEX_HELPER_PROXY_PORT"].flatMap { UInt16($0) } ?? workBuddyPort
}
let workBuddyAPIKey = "workbuddy-local"
let workBuddyAPIPrefix = "/workbuddy/v1"

// 两条路由的纯状态：listener 只在任一上游需要时启动，关闭其中一个不影响另一个。
// 单独抽出来是为了能脱离 58100 端口直接断言（见 selfTest）。
struct ProxyRouteState: Equatable {
    var workBuddy = false
    var trae = false

    var listenerNeeded: Bool { workBuddy || trae }
}

private struct ProxyRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

final class WorkBuddyProxy {
    static var port: Int { Int(proxyPort) }

    private let queue = DispatchQueue(label: "local.codex-helper.workbuddy.proxy", qos: .utility)
    private let client: WorkBuddyClient
    private let traeClient: TraeClient
    private var listener: NWListener?
    private var routeState = ProxyRouteState()
    private(set) var isRunning = false

    init(client: WorkBuddyClient, traeClient: TraeClient) {
        self.client = client
        self.traeClient = traeClient
    }

    var isWorkBuddyRunning: Bool { routeState.workBuddy && isRunning }
    var isTraeRunning: Bool { routeState.trae && isRunning }
    var isWorkBuddyRouteEnabled: Bool { routeState.workBuddy }
    var isTraeRouteEnabled: Bool { routeState.trae }

    func setWorkBuddyRunning(_ running: Bool) throws {
        routeState.workBuddy = running
        try updateListener()
    }

    func setTraeRunning(_ running: Bool) throws {
        routeState.trae = running
        try updateListener()
    }

    // 两个路由都关闭时才真正停 listener。
    private func updateListener() throws {
        if routeState.listenerNeeded { try start() } else { stop() }
    }

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            self?.isRunning = {
                if case .ready = state { return true }
                return false
            }()
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var next = buffer
            if let data { next.append(data) }
            if next.count > 10 * 1024 * 1024 {
                self.sendJSON(connection, status: 413, ["error": ["message": "Request too large"]])
                return
            }
            if let request = self.parseRequest(next) {
                DispatchQueue.global(qos: .userInitiated).async { self.handle(connection, request) }
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: next)
            }
        }
    }

    private func parseRequest(_ data: Data) -> ProxyRequest? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<boundary.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = boundary.upperBound
        guard data.count >= bodyStart + length else { return nil }
        return ProxyRequest(method: String(requestLine[0]),
                            path: String(requestLine[1]).split(separator: "?").first.map(String.init) ?? "/",
                            headers: headers, body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }

    private func handle(_ connection: NWConnection, _ request: ProxyRequest) {
        switch proxyRoute(for: request.path) {
        case .health:
            sendJSON(connection, ["status": "ok", "app": "Codex Helper", "port": Int(proxyPort),
                                  "workbuddy": routeState.workBuddy, "trae": routeState.trae])
        // 同一个 listener 下共用 HTTP/SSE 管线，按前缀分流到各自上游与 API Key；
        // 前缀不匹配的一律 404，绝不在两个 provider 之间回退。
        case .workBuddy:
            handleWorkBuddy(connection, request)
        case .trae:
            handleTrae(connection, request)
        case .unknown:
            sendJSON(connection, status: 404, ["error": ["message": "Not found", "type": "invalid_request_error"]])
        }
    }

    private func handleWorkBuddy(_ connection: NWConnection, _ request: ProxyRequest) {
        do {
            guard routeState.workBuddy else {
                sendJSON(connection, status: 404,
                         ["error": ["message": "WorkBuddy 代理路由未启用", "type": "invalid_request_error"]])
                return
            }
            guard request.headers["authorization"] == "Bearer " + workBuddyAPIKey ||
                    request.headers["x-api-key"] == workBuddyAPIKey else {
                sendJSON(connection, status: 401, ["error": ["message": "API key mismatch", "type": "authentication_error"]])
                return
            }
            let path = String(request.path.dropFirst(workBuddyAPIPrefix.count))
            if request.method == "GET", path == "/models" {
                sendJSON(connection, ["object": "list", "data": try client.models().map(\.json), "has_more": false])
                return
            }
            guard request.method == "POST", path == "/chat/completions",
                  let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                sendJSON(connection, status: 404, ["error": ["message": "Not found", "type": "invalid_request_error"]])
                return
            }
            streamChat(connection, body)
        } catch {
            sendJSON(connection, status: 500, ["error": ["message": error.localizedDescription, "type": "server_error"]])
        }
    }

    private func streamChat(_ connection: NWConnection, _ body: [String: Any]) {
        stream(connection) { client.chat(body, onStart: $0, onData: $1, completion: $2) }
    }

    private func handleTrae(_ connection: NWConnection, _ request: ProxyRequest) {
        do {
            guard routeState.trae else {
                sendJSON(connection, status: 404,
                         ["error": ["message": "Trae 代理路由未启用", "type": "invalid_request_error"]])
                return
            }
            guard request.headers["authorization"] == "Bearer " + TraeClient.apiKey ||
                    request.headers["x-api-key"] == TraeClient.apiKey else {
                sendJSON(connection, status: 401, ["error": ["message": "API key mismatch", "type": "authentication_error"]])
                return
            }
            let path = String(request.path.dropFirst(traeAPIPrefix.count))
            if request.method == "GET", path == "/models" {
                sendJSON(connection, ["object": "list", "data": try traeClient.models().map(\.json), "has_more": false])
                return
            }
            guard request.method == "POST", path == "/chat/completions",
                  let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                sendJSON(connection, status: 404, ["error": ["message": "Not found", "type": "invalid_request_error"]])
                return
            }
            stream(connection) { traeClient.chat(body, onStart: $0, onData: $1, completion: $2) }
        } catch {
            sendJSON(connection, status: 500, ["error": ["message": error.localizedDescription, "type": "server_error"]])
        }
    }

    // 两个上游共用同一段 SSE 框架：启动时写 200 头，随后逐块整编，最后补结束块。
    private func stream(_ connection: NWConnection,
                        _ produce: (@escaping () -> Void, @escaping (Data) -> Void, @escaping (Error?) -> Void) -> Void) {
        var started = false
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        produce({
            started = true
            connection.send(content: Data(header.utf8), completion: .idempotent)
        }, { data in
            connection.send(content: Self.httpChunk(data), completion: .idempotent)
        }, { [weak self] error in
            if let error, !started {
                self?.sendJSON(connection, status: 500,
                               ["error": ["message": error.localizedDescription, "type": "server_error"]])
                return
            }
            connection.send(content: Data("0\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        })
    }

    fileprivate static func httpChunk(_ data: Data) -> Data {
        var chunk = Data(String(data.count, radix: 16).utf8)
        chunk.append(Data("\r\n".utf8))
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        return chunk
    }

    private func sendJSON(_ connection: NWConnection, status: Int = 200, _ value: Any) {
        let body = (try? workBuddyJSONData(value)) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : (status == 404 ? "Not Found" : "Error"))
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func selfTest() {
        precondition(String(data: httpChunk(Data("abc".utf8)), encoding: .utf8) == "3\r\nabc\r\n")

        // 路由状态互不影响：关一个不影响另一个，两个都关才停 listener。
        var state = ProxyRouteState()
        precondition(!state.listenerNeeded)
        state.workBuddy = true
        precondition(state.listenerNeeded && !state.trae)
        state.trae = true
        precondition(state.workBuddy && state.trae)
        state.workBuddy = false
        precondition(state.listenerNeeded && !state.workBuddy && state.trae)
        state.trae = false
        precondition(!state.listenerNeeded)

        // 前缀判定：旧 /v1 别名不再属于 WorkBuddy，两个 provider 之间没有回退。
        precondition(proxyRoute(for: "/workbuddy/v1/models") == .workBuddy)
        precondition(proxyRoute(for: "/workbuddy/v1/chat/completions") == .workBuddy)
        precondition(proxyRoute(for: "/workbuddy/v1") == .workBuddy)
        precondition(proxyRoute(for: "/trae/v1/models") == .trae)
        precondition(proxyRoute(for: "/trae/v1/chat/completions") == .trae)
        precondition(proxyRoute(for: "/trae/v1") == .trae)
        precondition(proxyRoute(for: "/health") == .health)
        precondition(proxyRoute(for: "/v1/models") == .unknown)
        precondition(proxyRoute(for: "/v1/chat/completions") == .unknown)
        // 前缀边界：只有 / 分隔的后继才算命中，v1x 之类必须落到 unknown。
        precondition(proxyRoute(for: "/trae/v1x") == .unknown)
        precondition(proxyRoute(for: "/trae/v1x/models") == .unknown)
        precondition(proxyRoute(for: "/workbuddy/v1x") == .unknown)
        precondition(proxyRoute(for: "/workbuddy/v1x/models") == .unknown)
        precondition(proxyRoute(for: "/workbuddy/v1abc/chat/completions") == .unknown)
        precondition(proxyRoute(for: "/workbuddy/v10") == .unknown)
        precondition(proxyRoute(for: "/trae") == .unknown)
        precondition(proxyRoute(for: "/healthz") == .unknown)
        precondition(proxyRoute(for: "/") == .unknown)
    }
}

enum ProxyRoute: Equatable {
    case health, workBuddy, trae, unknown
}

// 纯函数，便于脱离监听端口断言；handle 里按同一顺序使用。
func proxyRoute(for path: String) -> ProxyRoute {
    if path == "/health" { return .health }
    if proxyPathMatches(path, prefix: workBuddyAPIPrefix) { return .workBuddy }
    if proxyPathMatches(path, prefix: traeAPIPrefix) { return .trae }
    return .unknown
}

// 前缀必须落在路径边界上：/trae/v1 与 /trae/v1/models 属于 Trae，/trae/v1x 不属于任何 provider。
func proxyPathMatches(_ path: String, prefix: String) -> Bool {
    path == prefix || path.hasPrefix(prefix + "/")
}
