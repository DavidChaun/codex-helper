import Foundation

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

    func chat(_ source: [String: Any], onStart: @escaping () -> Void,
              onData: @escaping (Data) -> Void, completion: @escaping (Error?) -> Void) {
        Task {
            do {
                let model = source["model"] as? String ?? "unknown"
                var lastLimit: WorkBuddyRateLimit?
                for context in try accounts.contexts(for: model) {
                    do {
                        try await request(source, context: context, retryAfterRefresh: true,
                                          onStart: onStart, onData: onData)
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
        let cache = manager.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy/local_storage")
        let files = (try? manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files.filter({ $0.lastPathComponent.hasPrefix("entry_") && $0.pathExtension == "info" })
            .sorted(by: { ($0.contentModificationDate ?? .distantPast) > ($1.contentModificationDate ?? .distantPast) }) {
            guard let value = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) else { continue }
            for entry in (value as? [[String: Any]]) ?? ((value as? [String: Any]).map { [$0] } ?? []) {
                if let data = entry["data"] as? [String: Any], let models = data["models"] as? [[String: Any]], !models.isEmpty {
                    return models.compactMap(WorkBuddyModel.init)
                }
            }
        }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: workBuddyProductURL)) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw WorkBuddyError.message("WorkBuddy model catalog not found")
        }
        return models.compactMap(WorkBuddyModel.init)
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

    private func request(_ source: [String: Any], context: WorkBuddyAccountContext, retryAfterRefresh: Bool,
                         onStart: @escaping () -> Void, onData: @escaping (Data) -> Void) async throws {
        let body = upstreamBody(source)
        let request = try makeRequest(context: context, route: "/v2/chat/completions", body: body, accountAPI: false)
        let (bytes, rawResponse) = try await URLSession.shared.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw WorkBuddyError.message("Invalid HTTP response")
        }
        if response.statusCode == 401, retryAfterRefresh {
            let fresh = try refresh(context)
            return try await self.request(source, context: fresh, retryAfterRefresh: false,
                                          onStart: onStart, onData: onData)
        }
        guard (200..<300).contains(response.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let message = upstreamMessage(data) ?? "WorkBuddy model returned HTTP \(response.statusCode)"
            if Self.isRateLimit(status: response.statusCode, message: message) {
                throw WorkBuddyRateLimit(message: message, resetAt: Self.resetDate(in: message) ?? Date().addingTimeInterval(300))
            }
            throw WorkBuddyError.message(message)
        }
        onStart()
        for try await line in bytes.lines { onData(Data((line + "\n").utf8)) }
    }

    fileprivate func upstreamBody(_ source: [String: Any]) -> [String: Any] {
        var body = source
        body["stream"] = true
        if let model = body["model"] as? String, model.hasPrefix("hy3") { body["reasoning_effort"] = "high" }
        sanitizeBlockedTemplates(&body)
        return body
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
                             body: [String: Any], accountAPI: Bool) throws -> URLRequest {
        let product = try JSONSerialization.jsonObject(with: Data(contentsOf: workBuddyProductURL)) as? [String: Any] ?? [:]
        let endpoint = (text(product["endpoint"]) ?? "https://copilot.tencent.com")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: endpoint + route) else { throw WorkBuddyError.message("WorkBuddy 地址无效") }
        let version = text(product["genieVersion"]) ?? "5.5.3"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = accountAPI ? 30 : 300
        request.httpBody = try workBuddyJSONData(body)
        [
            "Authorization": "Bearer \(context.accessToken)", "X-User-Id": context.userID,
            "Content-Type": "application/json", "Accept": accountAPI ? "application/json" : "application/json, text/plain, */*",
            "User-Agent": accountAPI ? "WorkBuddy/\(version)" : "CLI/2.63.2 CodeBuddy/2.63.2",
            "X-Product": accountAPI ? "WorkBuddy" : "SaaS"
        ].forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if accountAPI {
            request.setValue("WorkBuddy", forHTTPHeaderField: "X-IDE-Type")
            request.setValue("WorkBuddy", forHTTPHeaderField: "X-IDE-Name")
            request.setValue(version, forHTTPHeaderField: "X-IDE-Version")
        } else {
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("https://www.codebuddy.cn", forHTTPHeaderField: "Origin")
            request.setValue("https://www.codebuddy.cn/", forHTTPHeaderField: "Referer")
        }
        if let refreshToken = context.refreshToken { request.setValue(refreshToken, forHTTPHeaderField: "X-Refresh-Token") }
        if let domain = context.domain { request.setValue(domain, forHTTPHeaderField: "X-Domain") }
        else { request.setValue("1", forHTTPHeaderField: "X-No-Department-Info") }
        if let enterprise = context.enterpriseID {
            request.setValue(enterprise, forHTTPHeaderField: "X-Enterprise-Id")
            if accountAPI { request.setValue(enterprise, forHTTPHeaderField: "X-Tenant-Id") }
        } else { request.setValue("1", forHTTPHeaderField: "X-No-Enterprise-Id") }
        return request
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
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: "You are Claude Code, Anthropic's official CLI for Claude.",
                                       with: "You are Claude Code, Anthropic's official CLI tool for Claude.")
                .replacingOccurrences(of: "Main branch (you will usually use this for PRs)",
                                      with: "Default branch (you will usually use this for PRs)")
        }
        for index in messages.indices {
            if let content = messages[index]["content"] as? String {
                messages[index]["content"] = clean(content)
            } else if var parts = messages[index]["content"] as? [[String: Any]] {
                for part in parts.indices where parts[part]["text"] is String {
                    parts[part]["text"] = clean(parts[part]["text"] as! String)
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
        precondition(isRateLimit(status: 500, message: "您的使用量已超出频率限制"))
        precondition(!isRateLimit(status: 500, message: "普通服务器错误"))
        precondition(resetDate(in: "将在 2026-09-11 19:13:41 UTC+8 重置") != nil)
        precondition(summaryRemaining(["data": ["Packages": [
            ["CycleRemainCapacity": "2400.25"], ["CycleRemainCapacity": 43.5]
        ]]]) == 2443.75)
    }
}

private extension URL {
    var contentModificationDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
