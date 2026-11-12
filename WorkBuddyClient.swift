import Foundation
import zlib

// 与 CodeBuddy CLI 对齐的客户端身份。版本号取自 ACP Registry 实际安装的
// `@tencent-ai/codebuddy-code`；CLI 由 registry 自动升级时这里需要同步跟上，
// 否则 User-Agent / X-IDE-Version 会落后于真实客户端。
let codeBuddyCLIVersion = "2.183.0"

/// 抓包中的 ID 使用 UUIDv7 布局：48 位毫秒时间戳，版本和变体位之外是 74 位随机数。
/// `X-Conversation-ID` 用 UUID 分段形态（8-4-4-4-12），其余头用裸 32 位十六进制。
/// 实测样本：01a1ce0d-345b-71d6-8fec-19708f5d4803 / 01a1ce0d35c673f8bc80661f9840da49
enum CodeBuddyID {
    private static let lock = NSLock()
    private static var lastTimestamp: UInt64 = 0
    private static var lastRandom: UInt64 = 0
    private static var lastRandomHigh: UInt64 = 0

    /// 去掉连字符的 UUIDv7；同一毫秒内递增随机部分。
    static func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        let now = UInt64(Date().timeIntervalSince1970 * 1000) & 0xFFFF_FFFF_FFFF
        if now > lastTimestamp {
            lastTimestamp = now
            lastRandomHigh = UInt64.random(in: 0..<0x1000)
            lastRandom = UInt64.random(in: 0..<0x4000_0000_0000_0000)
        } else {
            lastRandom = (lastRandom + 1) & 0x3FFF_FFFF_FFFF_FFFF
            if lastRandom == 0 { lastRandomHigh = (lastRandomHigh + 1) & 0x0FFF }
        }
        return hex(lastTimestamp, width: 12) + hex(0x7000 | lastRandomHigh, width: 4)
            + hex(0x8000_0000_0000_0000 | lastRandom, width: 16)
    }

    /// 同一底层值按 8-4-4-4-12 分段，得到 36 位 UUID 形态。
    static func uuidForm(_ value: String) -> String {
        guard value.count == 32 else { return value }
        let c = Array(value)
        return String(c[0..<8]) + "-" + String(c[8..<12]) + "-" + String(c[12..<16]) + "-"
            + String(c[16..<20]) + "-" + String(c[20..<32])
    }

    private static func hex(_ value: UInt64, width: Int) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

/// 一次代理调用（一次 chat）对应一个 CodeBuddy 会话；每个上游请求是它的一个轮次。
/// 用 class 是为了跨 `Task` 共享同一个可变轮次计数。
final class CodeBuddyConversationSession {
    let conversationID: String
    let rootRequestID: String
    let traceID: String
    private(set) var turnIndex = 0

    init(callerID: String? = nil) {
        conversationID = CodeBuddyID.uuidForm(CodeBuddyID.next())
        rootRequestID = CodeBuddyID.next()
        traceID = (callerID.flatMap(Self.normalizedTraceID)) ?? Self.randomHex(count: 32)
    }

    func nextTurnIdentifiers() -> CodeBuddyRequestIdentifiers {
        defer { turnIndex += 1 }
        // 首轮的 Conversation-Request-ID 必须等于 Root-Request-ID（与抓包一致）。
        let requestID = turnIndex == 0 ? rootRequestID : CodeBuddyID.next()
        return CodeBuddyRequestIdentifiers(
            conversationID: conversationID, messageID: CodeBuddyID.next(),
            requestID: requestID, rootRequestID: rootRequestID, traceID: traceID,
            spanID: Self.randomHex(count: 16), parentSpanID: Self.randomHex(count: 16))
    }

    /// 调用方传入的 `X-Request-ID` 可能是 UUID 或 W3C trace id，只有 32 位十六进制才能直接当 trace 用。
    static func normalizedTraceID(_ value: String) -> String? {
        let lower = value.lowercased()
        let isHex = lower.utf8.count == 32 && lower.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        return isHex && lower.contains(where: { $0 != "0" }) ? lower : nil
    }

    static func randomHex(count: Int) -> String {
        (0..<count).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
    }
}

struct CodeBuddyRequestIdentifiers {
    let conversationID: String
    let messageID: String
    let requestID: String
    let rootRequestID: String
    let traceID: String
    let spanID: String
    let parentSpanID: String
}

/// 搜索/抓取这类单次调用没有会话上下文，每次自成一个会话。
enum WorkBuddyTelemetry {
    static func identifiers() -> CodeBuddyRequestIdentifiers {
        CodeBuddyConversationSession().nextTurnIdentifiers()
    }
}

private func workBuddyGunzip(_ data: Data) -> Data? {
    var stream = z_stream()
    guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION,
                        Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { inflateEnd(&stream) }
    var input = [UInt8](data)
    return input.withUnsafeMutableBufferPointer { source -> Data? in
        stream.next_in = source.baseAddress
        stream.avail_in = uInt(source.count)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let status = buffer.withUnsafeMutableBufferPointer { target -> Int32 in
                stream.next_out = target.baseAddress
                stream.avail_out = uInt(target.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            guard status == Z_OK || status == Z_STREAM_END else { return nil }
            result.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
            guard result.count <= 10_000_000 else { return nil }
            if status == Z_STREAM_END { return result }
        }
    }
}

struct WorkBuddyModel {
    let id: String
    let name: String
    let type: String
    let credits: String?
    let maxInput: Int?
    let maxOutput: Int?
    let tools: Bool
    let images: Bool
    let reasoning: Bool

    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, !id.isEmpty else { return nil }
        let tags = value["tags"] as? [String] ?? []
        self.id = id
        name = value["name"] as? String ?? id
        type = tags.contains(where: { $0.contains("image") }) ? "image" :
            (tags.contains(where: { $0.contains("video") }) ? "video" : "chat")
        credits = value["credits"] as? String
        maxInput = (value["maxInputTokens"] as? NSNumber)?.intValue
        maxOutput = (value["maxOutputTokens"] as? NSNumber)?.intValue
        tools = value["supportsToolCall"] as? Bool ?? false
        images = value["supportsImages"] as? Bool ?? false
        reasoning = value["supportsReasoning"] as? Bool ?? false
    }

    var json: [String: Any] {
        var value: [String: Any] = [
            "id": id, "object": "model", "created": Int(Date().timeIntervalSince1970),
            "owned_by": "workbuddy", "name": name, "type": type,
            "supports_tool_call": tools, "supports_images": images,
            "supports_reasoning": reasoning
        ]
        value["credits"] = credits ?? NSNull()
        value["max_input_tokens"] = maxInput ?? NSNull()
        value["max_output_tokens"] = maxOutput ?? NSNull()
        return value
    }
}

struct WorkBuddyAccountState {
    let remaining: Double?
    let unit: String
    let checkedIn: Bool
    let checkinActive: Bool
    let todayCredit: Double
    let streakDays: Int

    var balanceText: String {
        guard let remaining else { return "暂无积分数据" }
        return "剩余积分：\(remaining.formatted(.number.precision(.fractionLength(0...2)))) \(unit)"
    }
}

enum WorkBuddyError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return "WorkBuddy error"
    }
}

private struct WorkBuddyRateLimit: Error {
    let message: String
    let resetAt: Date
}

func workBuddyJSONData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [])
}

private func syncRequest(_ request: URLRequest, timeout: TimeInterval = 300) throws -> (Data, HTTPURLResponse) {
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var captured: Result<(Data, HTTPURLResponse), Error>?
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        lock.lock()
        defer { lock.unlock(); done.signal() }
        if let error { captured = .failure(error); return }
        guard let http = response as? HTTPURLResponse else {
            captured = .failure(WorkBuddyError.message("Invalid HTTP response")); return
        }
        captured = .success((data ?? Data(), http))
    }
    task.resume()
    guard done.wait(timeout: .now() + timeout) == .success else {
        task.cancel()
        throw WorkBuddyError.message("Request timed out")
    }
    lock.lock()
    defer { lock.unlock() }
    return try captured!.get()
}

final class WorkBuddyClient {
    private let accounts: WorkBuddyAccountPool

    init(accounts: WorkBuddyAccountPool) {
        self.accounts = accounts
    }

    func chat(_ source: [String: Any], debug: ProxyDebugLog? = nil,
              session: CodeBuddyConversationSession = CodeBuddyConversationSession(),
              onStart: @escaping () -> Void,
              onData: @escaping (Data) -> Void, completion: @escaping (Error?) -> Void) {
        Task {
            do {
                let model = source["model"] as? String ?? "unknown"
                var lastLimit: WorkBuddyRateLimit?
                for context in try accounts.contexts(for: model) {
                    do {
                        try await request(source, context: context, session: session, retryAfterRefresh: true,
                                          debug: debug, onStart: onStart, onData: onData)
                        accounts.markSuccess(accountID: context.id, model: model)
                        completion(nil)
                        return
                    } catch let limit as WorkBuddyRateLimit {
                        accounts.markRateLimited(accountID: context.id, model: model, until: limit.resetAt)
                        lastLimit = limit
                    }
                }
                throw WorkBuddyError.message(lastLimit?.message ?? "没有可用的 WorkBuddy 账号")
            } catch { completion(error) }
        }
    }

    func models() throws -> [WorkBuddyModel] {
        let manager = FileManager.default
        let current = manager.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy/cache/acc-product-config-v3.json")
        if let data = try? Data(contentsOf: current),
           let value = try? JSONSerialization.jsonObject(with: data),
           let models = Self.cachedModels(value) { return models }
        let cache = manager.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy/local_storage")
        let files = (try? manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files.filter({ ($0.lastPathComponent.hasPrefix("entry_") || $0.lastPathComponent.hasPrefix("wb_entry_")) && $0.pathExtension == "info" })
            .sorted(by: { ($0.contentModificationDate ?? .distantPast) > ($1.contentModificationDate ?? .distantPast) }) {
            guard let value = try? JSONSerialization.jsonObject(with: Data(contentsOf: file), options: [.fragmentsAllowed]) else { continue }
            if let models = Self.cachedModels(value) { return models }
        }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: workBuddyProductURL)) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw WorkBuddyError.message("WorkBuddy model catalog not found")
        }
        return models.compactMap(WorkBuddyModel.init)
    }

    private static func cachedModels(_ value: Any) -> [WorkBuddyModel]? {
        if let root = value as? [String: Any], let models = root["models"] as? [[String: Any]], !models.isEmpty {
            let parsed = models.compactMap(WorkBuddyModel.init)
            if !parsed.isEmpty { return parsed }
        }
        if let text = value as? String,
           let compressed = Data(base64Encoded: text),
           let decoded = workBuddyGunzip(compressed),
           let root = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
           let models = root["models"] as? [[String: Any]], !models.isEmpty {
            return models.compactMap(WorkBuddyModel.init)
        }
        for entry in (value as? [[String: Any]]) ?? ((value as? [String: Any]).map { [$0] } ?? []) {
            if let data = entry["data"] as? [String: Any], let models = data["models"] as? [[String: Any]], !models.isEmpty {
                return models.compactMap(WorkBuddyModel.init)
            }
        }
        return nil
    }

    func snapshot(accountID: String? = nil) throws -> WorkBuddyAccountState {
        let context = try accountContext(accountID)
        let account = try post("/billing/meter/get-user-resource-summary", context: context)
        let checkin = try post("/v2/billing/meter/checkin-activity-status", context: context)["data"] as? [String: Any] ?? [:]
        return WorkBuddyAccountState(
            remaining: Self.summaryRemaining(account), unit: "积分",
            checkedIn: checkin["today_checked_in"] as? Bool ?? false,
            checkinActive: checkin["active"] as? Bool ?? false,
            todayCredit: Self.number(checkin["today_credit"] ?? checkin["daily_credit"]) ?? 0,
            streakDays: Int(Self.number(checkin["streak_days"]) ?? 0)
        )
    }

    fileprivate static func summaryRemaining(_ root: [String: Any]) -> Double? {
        guard let packages = (root["data"] as? [String: Any])?["Packages"] as? [[String: Any]] else { return nil }
        return packages.reduce(0) { total, package in
            guard let value = Self.number(package["CycleRemainCapacity"]), value.isFinite, value > 0 else { return total }
            return total + value
        }
    }

    func claimCheckin(accountID: String? = nil) throws -> WorkBuddyAccountState {
        let context = try accountContext(accountID)
        _ = try post("/v2/billing/meter/daily-checkin", context: context)
        return try snapshot(accountID: context.id)
    }

    private func accountContext(_ accountID: String?) throws -> WorkBuddyAccountContext {
        let contexts = try accounts.contexts(for: nil)
        guard let accountID else { return contexts[0] }
        guard let context = contexts.first(where: { $0.id == accountID }) else {
            throw WorkBuddyError.message("指定的 WorkBuddy 账号不可用")
        }
        return context
    }

    private func request(_ source: [String: Any], context: WorkBuddyAccountContext, session: CodeBuddyConversationSession,
                         retryAfterRefresh: Bool, debug: ProxyDebugLog?,
                         onStart: @escaping () -> Void, onData: @escaping (Data) -> Void) async throws {
        // 上游固定流式；客户端要不要 JSON 由代理层聚合决定（见 WorkBuddyProxy.chat）。
        let body = upstreamBody(source, sendStream: true)
        let idents = session.nextTurnIdentifiers()
        let request = try makeRequest(context: context, route: "/v2/chat/completions", body: body,
                                      accountAPI: false, idents: idents)
        debug?.record("upstream request (each attempt)", ["path": "/v2/chat/completions", "body": body])
        let (bytes, rawResponse) = try await URLSession.shared.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw WorkBuddyError.message("Invalid HTTP response")
        }
        debug?.upstream(status: response.statusCode)
        if response.statusCode == 401, retryAfterRefresh {
            let fresh = try refresh(context)
            return try await self.request(source, context: fresh, session: session, retryAfterRefresh: false,
                                          debug: debug, onStart: onStart, onData: onData)
        }
        guard (200..<300).contains(response.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            debug?.upstream(status: response.statusCode, errorBody: data)
            let message = upstreamMessage(data) ?? "WorkBuddy model returned HTTP \(response.statusCode)"
            if Self.isRateLimit(status: response.statusCode, message: message) {
                throw WorkBuddyRateLimit(message: message, resetAt: Self.resetDate(in: message) ?? Date().addingTimeInterval(300))
            }
            throw WorkBuddyError.message(message)
        }
        onStart()
        for try await line in bytes.lines {
            // AsyncLineSequence 跳过空行；模型的每个 JSON data 行是一条 SSE 事件。
            let separator = line.hasPrefix("data:") ? "\n\n" : "\n"
            onData(Data((line + separator).utf8))
        }
    }

    /// 上游始终流式（便于多账号间切换与错误早发现）；`sendStream` 只决定代理如何回应客户端。
    fileprivate func upstreamBody(_ source: [String: Any], sendStream: Bool = true) -> [String: Any] {
        var body = source
        body["stream"] = sendStream
        if let model = body["model"] as? String, model.hasPrefix("hy3") { body["reasoning_effort"] = "high" }
        // CodeBuddy 2.183.0 每轮都显式声明缓存寿命、推理摘要与用量回传；补齐后上游的缓存与计费
        // 行为才与真实 CLI 一致。调用方已显式给出时保持原值。
        if body["cache_retention"] == nil { body["cache_retention"] = "long" }
        if body["reasoning_summary"] == nil { body["reasoning_summary"] = "auto" }
        if var options = body["stream_options"] as? [String: Any] {
            if options["include_usage"] == nil { options["include_usage"] = true }
            body["stream_options"] = options
        } else if body["stream_options"] == nil {
            body["stream_options"] = ["include_usage": true]
        }
        injectHarnessMetadata(&body)
        sanitizeBlockedTemplates(&body)
        return body
    }

    /// 真实 CLI 每轮都在 `extra_vars.harnessMetadata` 里上报调用链（版本、步序号、上下文窗口、agent 深度）。
    /// 代理是单层对话，步序号恒为 0、深度恒为 0；调用方自带 `extra_vars` 时只补缺失字段。
    fileprivate func injectHarnessMetadata(_ body: inout [String: Any]) {
        if let supplied = body["extra_vars"], !(supplied is [String: Any]) { return }
        var extra = body["extra_vars"] as? [String: Any] ?? [:]
        if extra["harnessMetadata"] == nil {
            let metadata: [String: Any] = [
                "schemaVersion": 1, "harnessVersion": codeBuddyCLIVersion, "stepIndex": 0,
                "contextWindowId": CodeBuddyID.uuidForm(CodeBuddyID.next()), "agent": ["depth": 0]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                extra["harnessMetadata"] = json
            }
        }
        if extra["initiator"] == nil { extra["initiator"] = "user" }
        if extra["interactionType"] == nil { extra["interactionType"] = "prompt" }
        body["extra_vars"] = extra
    }

    private func post(_ route: String, context: WorkBuddyAccountContext, retryAfterRefresh: Bool = true) throws -> [String: Any] {
        let request = try makeRequest(context: context, route: route, body: [:], accountAPI: true)
        let (data, response) = try syncRequest(request, timeout: 30)
        if response.statusCode == 401, retryAfterRefresh {
            return try post(route, context: refresh(context), retryAfterRefresh: false)
        }
        guard (200..<300).contains(response.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              [nil, "0"].contains(root["code"].map(String.init(describing:))) else {
            throw WorkBuddyError.message(response.statusCode == 401 || response.statusCode == 403
                ? "WorkBuddy 登录已失效" : "WorkBuddy 账户服务返回 HTTP \(response.statusCode)")
        }
        return root
    }

    private func makeRequest(context: WorkBuddyAccountContext, route: String,
                             body: [String: Any], accountAPI: Bool,
                             idents: CodeBuddyRequestIdentifiers? = nil) throws -> URLRequest {
        let product = try JSONSerialization.jsonObject(with: Data(contentsOf: workBuddyProductURL)) as? [String: Any] ?? [:]
        let endpoint = (text(product["endpoint"]) ?? "https://copilot.tencent.com")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: endpoint + route) else { throw WorkBuddyError.message("WorkBuddy 地址无效") }
        let version = text(product["genieVersion"]) ?? "5.5.3"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = accountAPI ? 30 : 300
        request.httpBody = try workBuddyJSONData(body)
        if accountAPI {
            // 账户类接口（余额、签到、刷新 Token）走 WorkBuddy 桌面端身份，与模型请求无关。
            [
                "Authorization": "Bearer \(context.accessToken)", "X-User-Id": context.userID,
                "Content-Type": "application/json", "Accept": "application/json",
                "User-Agent": "WorkBuddy/\(version)", "X-Product": "WorkBuddy",
                "X-IDE-Type": "WorkBuddy", "X-IDE-Name": "WorkBuddy", "X-IDE-Version": version
            ].forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            if let refreshToken = context.refreshToken { request.setValue(refreshToken, forHTTPHeaderField: "X-Refresh-Token") }
            if let domain = context.domain { request.setValue(domain, forHTTPHeaderField: "X-Domain") }
            else { request.setValue("1", forHTTPHeaderField: "X-No-Department-Info") }
            if let enterprise = context.enterpriseID {
                request.setValue(enterprise, forHTTPHeaderField: "X-Enterprise-Id")
                request.setValue(enterprise, forHTTPHeaderField: "X-Tenant-Id")
            } else { request.setValue("1", forHTTPHeaderField: "X-No-Enterprise-Id") }
            return request
        }
        // 模型请求：按 CodeBuddy CLI 2.183.0 实测头部逐项复刻（见 README「请求一致性」）。
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("1", forHTTPHeaderField: "x-codebuddy-request")
        request.setValue("CLI/\(codeBuddyCLIVersion) CodeBuddy/\(codeBuddyCLIVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("CLI", forHTTPHeaderField: "X-IDE-Type")
        request.setValue("CLI", forHTTPHeaderField: "X-IDE-Name")
        request.setValue(codeBuddyCLIVersion, forHTTPHeaderField: "X-IDE-Version")
        request.setValue("false", forHTTPHeaderField: "X-Private-Data")
        request.setValue("SaaS", forHTTPHeaderField: "X-Product")
        request.setValue("craft", forHTTPHeaderField: "X-Agent-Intent")
        request.setValue("other", forHTTPHeaderField: "X-Agent-Runtime")
        request.setValue("conversation", forHTTPHeaderField: "X-Agent-Purpose")
        request.setValue("main", forHTTPHeaderField: "X-Agent-Type")
        request.setValue("js", forHTTPHeaderField: "x-stainless-lang")
        request.setValue("MacOS", forHTTPHeaderField: "x-stainless-os")
        request.setValue(Self.stainlessArch, forHTTPHeaderField: "x-stainless-arch")
        request.setValue("node", forHTTPHeaderField: "x-stainless-runtime")
        request.setValue("v22.14.0", forHTTPHeaderField: "x-stainless-runtime-version")
        request.setValue("7.39.0", forHTTPHeaderField: "x-stainless-package-version")
        request.setValue("0", forHTTPHeaderField: "x-stainless-retry-count")
        request.setValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(context.userID, forHTTPHeaderField: "X-User-Id")
        if let domain = context.domain { request.setValue(domain, forHTTPHeaderField: "X-Domain") }
        else { request.setValue("1", forHTTPHeaderField: "X-No-Department-Info") }
        if let enterprise = context.enterpriseID {
            request.setValue(enterprise, forHTTPHeaderField: "X-Enterprise-Id")
        } else { request.setValue("1", forHTTPHeaderField: "X-No-Enterprise-Id") }
        // 会话关联 ID 与 W3C/B3 追踪头：同一会话内顺序一致，网关据此串联轮次。
        if let idents {
            request.setValue(idents.conversationID, forHTTPHeaderField: "X-Conversation-ID")
            request.setValue(idents.messageID, forHTTPHeaderField: "X-Conversation-Message-ID")
            request.setValue(idents.requestID, forHTTPHeaderField: "X-Conversation-Request-ID")
            request.setValue(idents.rootRequestID, forHTTPHeaderField: "X-Root-Request-ID")
            request.setValue(idents.messageID, forHTTPHeaderField: "X-Request-ID")
            let trace = idents.traceID
            request.setValue("00-\(trace)-\(idents.spanID)-01", forHTTPHeaderField: "traceparent")
            request.setValue("\(trace)-\(idents.spanID)-1-\(idents.parentSpanID)", forHTTPHeaderField: "b3")
            request.setValue(trace, forHTTPHeaderField: "X-B3-TraceId")
            request.setValue(idents.parentSpanID, forHTTPHeaderField: "X-B3-ParentSpanId")
            request.setValue(idents.spanID, forHTTPHeaderField: "X-B3-SpanId")
            request.setValue("1", forHTTPHeaderField: "X-B3-Sampled")
            request.setValue(trace, forHTTPHeaderField: "X-Trace-ID")
            request.setValue("codebuddy.session_id=\(idents.conversationID),codebuddy.conversation_request_id=\(idents.rootRequestID)",
                             forHTTPHeaderField: "baggage")
        }
        return request
    }

    /// 与真实 CLI 一致的 Node 运行时架构标签（网关侧只用于客户端识别）。
    private static var stainlessArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    private func refresh(_ context: WorkBuddyAccountContext) throws -> WorkBuddyAccountContext {
        guard let refreshToken = context.refreshToken, !refreshToken.isEmpty else {
            throw WorkBuddyError.message("WorkBuddy 登录已失效，请重新登录")
        }
        var request = try makeRequest(context: context, route: "/v2/plugin/auth/token/refresh", body: [:], accountAPI: false)
        request.setValue(refreshToken, forHTTPHeaderField: "X-Refresh-Token")
        request.setValue("workbuddy", forHTTPHeaderField: "X-Auth-Refresh-Source")
        let (data, response) = try syncRequest(request, timeout: 30)
        guard (200..<300).contains(response.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fresh = root["data"] as? [String: Any],
              let accessToken = text(fresh["accessToken"]) else {
            throw WorkBuddyError.message("WorkBuddy 登录已失效，请重新登录")
        }
        return try accounts.updateTokens(accountID: context.id, accessToken: accessToken,
                                         refreshToken: text(fresh["refreshToken"]) ?? refreshToken)
    }

    private func sanitizeBlockedTemplates(_ body: inout [String: Any]) {
        guard var messages = body["messages"] as? [[String: Any]] else { return }
        func clean(_ value: String, role: String?) -> String {
            var value = value
            if role == "system" || role == "developer" {
                value = value.replacingOccurrences(
                    of: "You are Claude Code, Anthropic's official CLI for Claude, running within the Claude Agent SDK.",
                    with: "You are Claude Code, Anthropic's official CLI tool for Claude.")
            }
            return value.replacingOccurrences(of: "You are Claude Code, Anthropic's official CLI for Claude.",
                                       with: "You are Claude Code, Anthropic's official CLI tool for Claude.")
                .replacingOccurrences(of: "Main branch (you will usually use this for PRs)",
                                      with: "Default branch (you will usually use this for PRs)")
        }
        for index in messages.indices {
            if let content = messages[index]["content"] as? String {
                messages[index]["content"] = clean(content, role: messages[index]["role"] as? String)
            } else if var parts = messages[index]["content"] as? [[String: Any]] {
                for part in parts.indices where parts[part]["text"] is String {
                    parts[part]["text"] = clean(parts[part]["text"] as! String, role: messages[index]["role"] as? String)
                }
                messages[index]["content"] = parts
            }
        }
        body["messages"] = messages
    }

    private func upstreamMessage(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return text(root["msg"] ?? root["displayMsg"] ?? (root["error"] as? [String: Any])?["message"])
    }

    fileprivate static func isRateLimit(status: Int, message: String) -> Bool {
        let lower = message.lowercased()
        return (status == 429 || status == 500) &&
            (message.contains("频率限制") || message.contains("使用量已超出") || lower.contains("rate limit"))
    }

    fileprivate static func resetDate(in message: String) -> Date? {
        let pattern = #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#
        guard let range = message.range(of: pattern, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: String(message[range]))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let result = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    static func selfTest() {
        let pool = WorkBuddyAccountPool()
        let client = WorkBuddyClient(accounts: pool)
        let body = client.upstreamBody([
            "model": "hy3-preview", "stream": false,
            "messages": [["role": "system", "content": "You are Claude Code, Anthropic's official CLI for Claude."]],
            "tools": [["type": "function", "function": ["name": "exec"]]]
        ])
        precondition(body["stream"] as? Bool == true)
        precondition(body["reasoning_effort"] as? String == "high")
        precondition(((body["messages"] as? [[String: Any]])?.first?["content"] as? String)?.contains("CLI tool") == true)
        precondition((body["tools"] as? [[String: Any]])?.count == 1)
        let desktopIdentity = "You are Claude Code, Anthropic's official CLI for Claude, running within the Claude Agent SDK."
        let cliIdentity = "You are Claude Code, Anthropic's official CLI tool for Claude."
        let rules = "\nFollow workspace rules. Refuse unsafe requests."
        let desktopTools: [[String: Any]] = [["type": "function", "function": ["name": "mcp__ccd_test"]]]
        let desktop = client.upstreamBody([
            "model": "deepseek-v4.1-flash", "max_tokens": 64000, "tools": desktopTools,
            "messages": [["role": "system", "content": desktopIdentity + rules],
                         ["role": "developer", "content": [["type": "text", "text": desktopIdentity]]],
                         ["role": "user", "content": desktopIdentity]]
        ])
        let messages = desktop["messages"] as! [[String: Any]]
        precondition(messages[0]["content"] as? String == cliIdentity + rules)
        precondition((messages[1]["content"] as? [[String: String]])?.first?["text"] == cliIdentity)
        precondition(messages[2]["content"] as? String == desktopIdentity)
        precondition(NSArray(array: desktop["tools"] as! [Any]).isEqual(to: desktopTools))
        precondition(desktop["max_tokens"] as? Int == 64000)
        precondition(NSDictionary(dictionary: client.upstreamBody(desktop)).isEqual(to: desktop))
        // CodeBuddy 2.183.0 的 body 适配：缓存寿命、推理摘要、用量回传与 harness 元数据。
        precondition(desktop["cache_retention"] as? String == "long")
        precondition(desktop["reasoning_summary"] as? String == "auto")
        let streamOptions = desktop["stream_options"] as? [String: Any]
        precondition(streamOptions?["include_usage"] as? Bool == true)
        let extraVars = desktop["extra_vars"] as? [String: Any]
        precondition(extraVars?["initiator"] as? String == "user")
        precondition(extraVars?["interactionType"] as? String == "prompt")
        let harnessJSON = extraVars?["harnessMetadata"] as? String
        let harness = harnessJSON.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        precondition(harness?["schemaVersion"] as? Int == 1)
        precondition(harness?["harnessVersion"] as? String == codeBuddyCLIVersion)
        precondition(harness?["stepIndex"] as? Int == 0)
        precondition((harness?["agent"] as? [String: Any])?["depth"] as? Int == 0)
        precondition(harness?["contextWindowId"] is String)
        // 显式给过的值不被覆盖。
        let explicit = client.upstreamBody(["model": "glm-5.3", "cache_retention": "short",
                                            "stream_options": ["include_usage": false],
                                            "extra_vars": ["initiator": "tool"]])
        precondition(explicit["cache_retention"] as? String == "short")
        precondition((explicit["stream_options"] as? [String: Any])?["include_usage"] as? Bool == false)
        precondition((explicit["extra_vars"] as? [String: Any])?["initiator"] as? String == "tool")
        precondition(client.upstreamBody(["extra_vars": NSNull()])["extra_vars"] is NSNull)
        // 第二步起 harnessMetadata 每次注入新的 contextWindowId。
        let second = client.upstreamBody(["model": "glm-5.3"])
        precondition((second["extra_vars"] as? [String: Any])?["harnessMetadata"] as? String != harnessJSON)
        // 会话关联 ID：同一会话内 root 不变、消息 ID 递增、trace 贯穿。
        let session = CodeBuddyConversationSession(callerID: nil)
        let firstTurn = session.nextTurnIdentifiers()
        let secondTurn = session.nextTurnIdentifiers()
        precondition(firstTurn.conversationID == secondTurn.conversationID)
        precondition(firstTurn.rootRequestID == secondTurn.rootRequestID)
        precondition(firstTurn.traceID == secondTurn.traceID)
        precondition(firstTurn.messageID != secondTurn.messageID)
        precondition(firstTurn.messageID != firstTurn.requestID)
        // 实测样本：X-Conversation-ID 是 8-4-4-4-12 的 UUID 形态，其余是裸 32 位十六进制。
        precondition(firstTurn.conversationID.count == 36)
        precondition(firstTurn.conversationID.filter { $0 == "-" }.count == 4)
        precondition(firstTurn.conversationID.replacingOccurrences(of: "-", with: "").count == 32)
        precondition(firstTurn.conversationID.allSatisfy { $0.isHexDigit || $0 == "-" })
        for value in [firstTurn.messageID, firstTurn.requestID, firstTurn.rootRequestID] {
            precondition(value.count == 32 && value.allSatisfy(\.isHexDigit))
        }
        // 首轮的 Conversation-Request-ID 必须等于 Root-Request-ID（与抓包一致）。
        precondition(firstTurn.requestID == firstTurn.rootRequestID)
        precondition(secondTurn.requestID != secondTurn.rootRequestID)
        let conversationHex = firstTurn.conversationID.replacingOccurrences(of: "-", with: "")
        precondition(conversationHex != firstTurn.rootRequestID)
        for id in [conversationHex, firstTurn.rootRequestID, firstTurn.messageID] {
            let digits = Array(id)
            precondition(digits[12] == "7" && "89ab".contains(digits[16]))
        }
        precondition(firstTurn.spanID.count == 16 && firstTurn.spanID.allSatisfy(\.isHexDigit))
        // 调用方给的 32 位十六进制 request id 可直接作为 trace id；UUID 则退回随机。
        let hexCaller = String(repeating: "ab", count: 16)
        precondition(CodeBuddyConversationSession.normalizedTraceID(hexCaller) == hexCaller)
        precondition(CodeBuddyConversationSession.normalizedTraceID(String(repeating: "0", count: 32)) == nil)
        precondition(CodeBuddyConversationSession.normalizedTraceID("3F2504E0-4F89-11D3-9A0C-0305E82C3301") == nil)
        precondition(isRateLimit(status: 500, message: "您的使用量已超出频率限制"))
        precondition(!isRateLimit(status: 500, message: "普通服务器错误"))
        precondition(resetDate(in: "将在 2026-09-11 19:13:41 UTC+8 重置") != nil)
        precondition(summaryRemaining(["data": ["Packages": [
            ["CycleRemainCapacity": "2400.25"], ["CycleRemainCapacity": 43.5]
        ]]]) == 2443.75)
        let compressed = "H4sIAAAAAAAAA6tWys1PSc0pVrKKrlbKTFGyUkpJTS0oTk3N1i0z0TPUTctJLM5Q0lHKS8xNBUq6wCTDQJJuUMnkotSUzBKgGUoVBnqGhkq1sbUAyNQhK1gAAAA="
        precondition(cachedModels(compressed)?.first?.credits == "x0.11")
        precondition(cachedModels([["data": ["models": [["id": "old", "credits": "x0.03"]]]]])?.first?.credits == "x0.03")
        let currentModels = cachedModels(["models": [["id": "step-5-preview", "name": "Step-5-Preview", "credits": "x0.00"]]])
        precondition(currentModels?.first?.id == "step-5-preview")
        precondition(currentModels?.first?.credits == "x0.00")
        precondition(cachedModels(["models": []]) == nil)
        precondition(cachedModels(["models": [["name": "invalid"]]]) == nil)
    }
}

private extension URL {
    var contentModificationDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
