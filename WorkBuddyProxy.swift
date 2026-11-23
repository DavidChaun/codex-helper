import Foundation
import Network

private let workBuddyPort: UInt16 = 58100
// 仅在验证时用环境变量换端口，正常运行始终是 58100。
private var proxyPort: UInt16 {
    ProcessInfo.processInfo.environment["CODEX_HELPER_PROXY_PORT"].flatMap { UInt16($0) } ?? workBuddyPort
}
let workBuddyAPIKey = "workbuddy-local"
let workBuddyAPIPrefix = "/workbuddy/v1"

// 路由开关决定 listener 是否要起。单独抽出来是为了能脱离 58100 端口直接断言（见 selfTest）。
struct ProxyRouteState: Equatable {
    var workBuddy = false

    var listenerNeeded: Bool { workBuddy }
}

private struct ProxyRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private func chatWantsStream(_ body: [String: Any]) -> Bool { body["stream"] as? Bool == true }

/// 上游按「行」回调（见 WorkBuddyClient.request），一次回调可能只是半帧 JSON，
/// 也可能在某行里挤着多帧。所以必须增量累积，只在 JSON 完整时才吐出一整帧；
/// 否则半帧会被判成「不可解析 => 暂留」，正文就永远发不出去。
private func unsupportedSearchParameter(_ body: [String: Any]) -> String? {
    func isServerSearch(_ tool: [String: Any]) -> Bool {
        let type = tool["type"] as? String ?? ""
        return type == "web_search" || type.hasPrefix("web_search_") ||
            type == "web_fetch" || type.hasPrefix("web_fetch_")
    }
    if let options = body["web_search_options"], !(options is NSNull) { return "web_search_options" }
    for (index, tool) in (body["tools"] as? [[String: Any]] ?? []).enumerated() where isServerSearch(tool) {
        return "tools[\(index)].type"
    }
    if let choice = body["tool_choice"] as? [String: Any], isServerSearch(choice) { return "tool_choice.type" }
    return nil
}

private final class ChatCompletionCollector {
    private var pending = ""
    private var id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var created = Int(Date().timeIntervalSince1970)
    private var model: String
    private var message: [String: Any] = ["role": "assistant"]
    private var calls: [Int: [String: Any]] = [:]
    private var finishReason: String?
    private var usage: [String: Any]?
    private var sawChoice = false
    private(set) var sawDone = false
    private(set) var errorMessage: String?

    init(model: String) { self.model = model }

    func consume(_ data: Data) {
        pending += String(decoding: data, as: UTF8.self)
        while let end = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let line = String(pending[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...end)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { sawDone = true; continue }
            guard let frame = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                errorMessage = "Invalid upstream stream"
                continue
            }
            if let error = frame["error"] as? [String: Any] {
                errorMessage = error["message"] as? String ?? "Upstream stream failed"
                continue
            }
            if let value = frame["id"] as? String { id = value }
            if let value = frame["created"] as? Int { created = value }
            if let value = frame["model"] as? String { model = value }
            if let value = frame["usage"] as? [String: Any] { usage = value }
            guard let choice = (frame["choices"] as? [[String: Any]])?.first else { continue }
            sawChoice = true
            if let value = choice["finish_reason"] as? String { finishReason = value }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let role = delta["role"] as? String { message["role"] = role }
            for key in ["content", "reasoning_content", "refusal"] {
                if let value = delta[key] as? String {
                    message[key] = (message[key] as? String ?? "") + value
                }
            }
            if let function = delta["function_call"] as? [String: String] {
                var merged = message["function_call"] as? [String: String] ?? [:]
                for (key, value) in function { merged[key] = (merged[key] ?? "") + value }
                message["function_call"] = merged
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = call["index"] as? Int ?? 0
                var merged = calls[index] ?? ["type": "function"]
                for key in ["id", "type"] {
                    if let value = call[key] as? String { merged[key] = value }
                }
                if let function = call["function"] as? [String: String] {
                    var parts = merged["function"] as? [String: String] ?? [:]
                    for (key, value) in function { parts[key] = (parts[key] ?? "") + value }
                    merged["function"] = parts
                }
                calls[index] = merged
            }
        }
    }

    func result() -> [String: Any]? {
        guard sawChoice, finishReason != nil || sawDone, errorMessage == nil else { return nil }
        var output = message
        if output["content"] == nil { output["content"] = NSNull() }
        if !calls.isEmpty { output["tool_calls"] = calls.keys.sorted().compactMap { calls[$0] } }
        var response: [String: Any] = [
            "id": id, "object": "chat.completion", "created": created, "model": model,
            "choices": [["index": 0, "message": output, "finish_reason": finishReason ?? "stop"]],
        ]
        if let usage { response["usage"] = usage }
        return response
    }
}

final class WorkBuddyProxy {
    static var port: Int { Int(proxyPort) }

    private let queue = DispatchQueue(label: "local.codex-helper.workbuddy.proxy", qos: .utility)
    private let client: WorkBuddyClient
    private var listener: NWListener?
    private var routeState = ProxyRouteState()
    private(set) var isRunning = false

    init(client: WorkBuddyClient) {
        self.client = client
    }

    var isWorkBuddyRunning: Bool { routeState.workBuddy && isRunning }
    var isWorkBuddyRouteEnabled: Bool { routeState.workBuddy }

    func setWorkBuddyRunning(_ running: Bool) throws {
        routeState.workBuddy = running
        try updateListener()
    }

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
                                  "workbuddy": routeState.workBuddy])
        case .workBuddy:
            handleWorkBuddy(connection, request)
        case .unknown:
            sendJSON(connection, status: 404, ["error": ["message": "Not found", "type": "invalid_request_error"]])
        }
    }

    private func handleWorkBuddy(_ connection: NWConnection, _ request: ProxyRequest) {
        let path = request.path == "/model" ? "/models" : String(request.path.dropFirst(workBuddyAPIPrefix.count))
        let messages = request.method == "POST" && path == "/messages"
        do {
            guard routeState.workBuddy else {
                let message = "WorkBuddy 代理路由未启用"
                let error: [String: Any] = messages ? WorkBuddyMessages.error(message, type: "not_found_error") :
                    ["error": ["message": message, "type": "invalid_request_error"]]
                sendJSON(connection, status: 404, error)
                return
            }
            guard request.headers["authorization"] == "Bearer " + workBuddyAPIKey ||
                    request.headers["x-api-key"] == workBuddyAPIKey else {
                let message = "API key mismatch"
                let error: [String: Any] = messages ? WorkBuddyMessages.error(message, type: "authentication_error") :
                    ["error": ["message": message, "type": "authentication_error"]]
                sendJSON(connection, status: 401, error)
                return
            }
            if messages {
                handleWorkBuddyMessages(connection, request)
                return
            }
            if request.method == "GET", path == "/models" {
                sendJSON(connection, ["object": "list", "data": try client.models().map(\.json), "has_more": false])
                return
            }
            guard request.method == "POST", path == "/chat/completions",
                  let parsedBody = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                sendJSON(connection, status: 404, ["error": ["message": "Not found", "type": "invalid_request_error"]])
                return
            }
            // 代理不注入、也不代执行任何工具：工具循环属于客户端。
            // 这里只拒绝上游不支持的服务端内置搜索。
            let body = parsedBody
            if let parameter = unsupportedSearchParameter(body) {
                sendJSON(connection, status: 400,
                         ["error": ["message": Self.unsupportedSearchMessage, "type": "invalid_request_error",
                                    "code": "unsupported_server_search", "param": parameter]])
                return
            }
            let callerID = request.headers["x-request-id"] ?? request.headers["x-ocx-request-id"]
            let debug = ProxyDebugLog.begin(provider: "workbuddy", body: body, callerID: callerID)
            chat(connection, body, debug: debug) {
                self.client.chat(body, debug: debug,
                                 session: CodeBuddyConversationSession(callerID: callerID),
                                 onStart: $0, onData: $1, completion: $2)
            }
        } catch {
            sendJSON(connection, status: 500, ["error": ["message": error.localizedDescription, "type": "server_error"]])
        }
    }

    private func handleWorkBuddyMessages(_ connection: NWConnection, _ request: ProxyRequest) {
        let body: [String: Any]
        let model: String
        do {
            guard let source = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                throw WorkBuddyError.message("Expected a JSON object")
            }
            body = try WorkBuddyMessages.chatBody(source)
            model = source["model"] as? String ?? "unknown"
        } catch {
            sendJSON(connection, status: 400, WorkBuddyMessages.error(error.localizedDescription, type: "invalid_request_error"))
            return
        }
        let callerID = request.headers["x-request-id"] ?? request.headers["x-ocx-request-id"]
        let debug = ProxyDebugLog.begin(provider: "workbuddy", body: body, callerID: callerID)
        let produce: (@escaping () -> Void, ((Data) -> Void)?, @escaping (Result<[String: Any], Error>) -> Void) -> Void = { start, emit, done in
            let response = WorkBuddyMessagesResponse(model: model, emit: emit)
            self.client.chat(body, debug: debug, session: CodeBuddyConversationSession(callerID: callerID),
                             onStart: start, onData: { chunk in
                debug?.observe(chunk)
                response.consume(chunk)
            }, completion: { error in
                let result = Result {
                    if let error { throw error }
                    return try response.finish()
                }
                switch result {
                case .success: debug?.finish(nil)
                case .failure(let error): debug?.finish(error)
                }
                done(result)
            })
        }
        if chatWantsStream(body) {
            stream(connection, messagesErrors: true) { start, data, done in
                produce(start, data) { result in
                    switch result {
                    case .success: done(nil)
                    case .failure(let error): done(error)
                    }
                }
            }
        } else {
            produce({}, nil) { result in
                switch result {
                case .success(let message): self.sendJSON(connection, message)
                case .failure(let error): self.sendJSON(connection, status: 502, WorkBuddyMessages.error(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - 原生搜索工具

    static let unsupportedSearchMessage = "WorkBuddy 代理不支持服务端 web_search / web_fetch 或 web_search_options。请使用 type=function 的普通搜索工具，由客户端或 MCP 服务执行并回传结果。"

    private func chat(_ connection: NWConnection, _ body: [String: Any], debug: ProxyDebugLog?,
                      _ upstream: @escaping (@escaping () -> Void, @escaping (Data) -> Void, @escaping (Error?) -> Void) -> Void) {
        if let parameter = unsupportedSearchParameter(body) {
            debug?.finish(NSError(domain: "CodexHelper.Proxy", code: 400,
                                  userInfo: [NSLocalizedDescriptionKey: Self.unsupportedSearchMessage]))
            sendJSON(connection, status: 400,
                     ["error": ["message": Self.unsupportedSearchMessage, "type": "invalid_request_error",
                                "code": "unsupported_server_search", "param": parameter]])
            return
        }
        let produce: (@escaping () -> Void, @escaping (Data) -> Void, @escaping (Error?) -> Void) -> Void = { start, data, done in
            upstream(start, { chunk in debug?.observe(chunk); data(chunk) }, { error in debug?.finish(error); done(error) })
        }
        if chatWantsStream(body) { stream(connection, produce); return }
        let collector = ChatCompletionCollector(model: body["model"] as? String ?? "unknown")
        produce({}, { collector.consume($0) }, { [weak self] error in
            if let error {
                self?.sendJSON(connection, status: 502,
                               ["error": ["message": error.localizedDescription, "type": "upstream_error"]])
            } else if let message = collector.errorMessage {
                self?.sendJSON(connection, status: 502,
                               ["error": ["message": message, "type": "upstream_error"]])
            } else if let result = collector.result() {
                self?.sendJSON(connection, result)
            } else {
                self?.sendJSON(connection, status: 502,
                               ["error": ["message": "Empty upstream response", "type": "upstream_error"]])
            }
        })
    }

    // 两个上游共用同一段 SSE 框架：启动时写 200 头，随后逐块整编，最后补结束块。
    private func stream(_ connection: NWConnection, messagesErrors: Bool = false,
                        _ produce: (@escaping () -> Void, @escaping (Data) -> Void, @escaping (Error?) -> Void) -> Void) {
        var started = false
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        produce({
            started = true
            connection.send(content: Data(header.utf8), completion: .idempotent)
        }, { data in
            connection.send(content: Self.httpChunk(data), completion: .idempotent)
        }, { [weak self] error in
            if let error {
                if messagesErrors {
                    let body = WorkBuddyMessages.error(error.localizedDescription)
                    if !started {
                        self?.sendJSON(connection, status: 502, body)
                        return
                    }
                    let event = WorkBuddyMessages.event("error", body)
                    connection.send(content: Self.httpChunk(event), completion: .idempotent)
                } else if !started {
                    self?.sendJSON(connection, status: 500,
                                   ["error": ["message": error.localizedDescription, "type": "server_error"]])
                    return
                }
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
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 502: "Bad Gateway"][status] ?? "Error"
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func selfTest() {
        precondition(String(data: httpChunk(Data("abc".utf8)), encoding: .utf8) == "3\r\nabc\r\n")
        WorkBuddyMessages.selfTest()

        // 按工具类型而非名称识别：普通 function 搜索工具仍由客户端 / MCP 执行。
        precondition(unsupportedSearchParameter([:]) == nil)
        precondition(unsupportedSearchParameter(["web_search_options": NSNull()]) == nil)
        precondition(unsupportedSearchParameter(["web_search_options": [:]]) == "web_search_options")
        for type in ["web_search", "web_search_preview", "web_search_20250305", "web_fetch", "web_fetch_20250910"] {
            precondition(unsupportedSearchParameter(["tools": [["type": type]]]) == "tools[0].type")
            precondition(unsupportedSearchParameter(["tool_choice": ["type": type]]) == "tool_choice.type")
        }
        let searchTools: [[String: Any]] = ["web_search", "WebSearch", "web_fetch", "mcp__search"].map {
            ["type": "function", "function": ["name": $0, "parameters": ["type": "object", "properties": [:]]]]
        }
        let searchBody: [String: Any] = ["tools": searchTools,
            "tool_choice": ["type": "function", "function": ["name": "web_search"]]]
        precondition(unsupportedSearchParameter(searchBody) == nil)
        precondition(unsupportedSearchParameter(["tools": searchTools + [["type": "web_search"]]]) == "tools[4].type")
        precondition(unsupportedSearchParameter(["tool_choice": "web_search"]) == nil)

        // 非流式默认值与 SSE 聚合：跨块 JSON、正文、工具调用和 usage 都不能丢。
        precondition(!chatWantsStream([:]))
        precondition(!chatWantsStream(["stream": false]))
        precondition(chatWantsStream(["stream": true]))
        let collector = ChatCompletionCollector(model: "fallback")
        collector.consume(Data("data: {".utf8))
        collector.consume(Data("\"id\":\"chatcmpl-test\",\"created\":1,\"model\":\"test\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"你\"},\"finish_reason\":null}]}\n".utf8))
        collector.consume(Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"好\",\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"echo\",\"arguments\":\"{\"}}]},\"finish_reason\":null}]}\n".utf8))
        collector.consume(Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"total_tokens\":3}}\n\ndata: [DONE]\n\n".utf8))
        let result = collector.result()
        let choice = (result?["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        precondition(result?["object"] as? String == "chat.completion")
        precondition(result?["id"] as? String == "chatcmpl-test")
        precondition(result?["model"] as? String == "test")
        precondition(message?["content"] as? String == "你好")
        precondition(choice?["finish_reason"] as? String == "tool_calls")
        let call = (message?["tool_calls"] as? [[String: Any]])?.first
        precondition(call?["id"] as? String == "call_1")
        precondition((call?["function"] as? [String: String])?["arguments"] == "{}")
        precondition((result?["usage"] as? [String: Any])?["total_tokens"] as? Int == 3)
        for newline in ["\n", "\r\n", "\r"] {
            let framed = ChatCompletionCollector(model: "test")
            for line in [#"data: {"choices":[{"delta":{"content":"你好"}}]}"#, "", "data: [DONE]", ""] {
                framed.consume(Data((line + newline).utf8))
            }
            let choice = (framed.result()?["choices"] as? [[String: Any]])?.first
            precondition((choice?["message"] as? [String: Any])?["content"] as? String == "你好")
        }
        let failed = ChatCompletionCollector(model: "test")
        failed.consume(Data("data: {\"error\":{\"message\":\"upstream failed\"}}\n\n".utf8))
        precondition(failed.errorMessage == "upstream failed" && failed.result() == nil)
        let truncated = ChatCompletionCollector(model: "test")
        truncated.consume(Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n".utf8))
        precondition(truncated.result() == nil)
        // 路由状态：关掉后 listener 停，重新开启重新起。
        var state = ProxyRouteState()
        precondition(!state.listenerNeeded)
        state.workBuddy = true
        precondition(state.listenerNeeded)
        state.workBuddy = false
        precondition(!state.listenerNeeded)

        // 前缀判定：旧 /v1 别名不再属于 WorkBuddy，未登记的前缀一律 unknown。
        precondition(proxyRoute(for: "/model") == .workBuddy)
        precondition(proxyRoute(for: "/workbuddy/v1/models") == .workBuddy)
        precondition(proxyRoute(for: "/workbuddy/v1/chat/completions") == .workBuddy)
        precondition(proxyRoute(for: "/workbuddy/v1") == .workBuddy)
        precondition(proxyRoute(for: "/health") == .health)
        precondition(proxyRoute(for: "/v1/models") == .unknown)
        precondition(proxyRoute(for: "/v1/chat/completions") == .unknown)
        // 前缀边界：只有 / 分隔的后继才算命中，v1x 之类必须落到 unknown。
        precondition(proxyRoute(for: "/workbuddy/v1x") == .unknown)
        precondition(proxyRoute(for: "/workbuddy/v1x/models") == .unknown)
        precondition(proxyRoute(for: "/workbuddy/v1abc/chat/completions") == .unknown)
        precondition(proxyRoute(for: "/workbuddy/v10") == .unknown)
        precondition(proxyRoute(for: "/trae/v1") == .unknown)
        precondition(proxyRoute(for: "/healthz") == .unknown)
        precondition(proxyRoute(for: "/") == .unknown)

        // 服务端内置搜索仍要拒绝；普通 function 工具一律放行（工具循环属于客户端）。
        precondition(unsupportedSearchParameter(["web_search_options": [:]]) == "web_search_options")
        precondition(unsupportedSearchParameter(["tools": [["type": "web_search"]]]) == "tools[0].type")
    }
}

enum ProxyRoute: Equatable {
    case health, workBuddy, unknown
}

// 纯函数，便于脱离监听端口断言；handle 里按同一顺序使用。
func proxyRoute(for path: String) -> ProxyRoute {
    if path == "/health" { return .health }
    if path == "/model" || proxyPathMatches(path, prefix: workBuddyAPIPrefix) { return .workBuddy }
    return .unknown
}

// 前缀必须落在路径边界上：/workbuddy/v1 与 /workbuddy/v1/models 命中，/workbuddy/v1x 不命中。
func proxyPathMatches(_ path: String, prefix: String) -> Bool {
    path == prefix || path.hasPrefix(prefix + "/")
}
