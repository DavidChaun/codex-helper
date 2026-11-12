import Foundation

// CodeBuddy CLI 的 WebSearch / WebFetch 执行时并不走 /v2/chat/completions：
// 它另外打 /agenttool/v1/search 和 /agenttool/v1/webfetch（codebuddy.js 里的
// WEB_SEARCH_API_PATH / WEB_FETCH_API_PATH）。这里直连同一组端点，让接进来的
// harness 不必装 CodeBuddy CLI 也能补齐搜索/抓取能力。

struct WorkBuddySearchHit {
    let title: String
    let url: String
    let snippet: String
    let site: String?
    let favicon: String?
}

struct WorkBuddySearchOutcome {
    let provider: String
    let results: [WorkBuddySearchHit]
    let totalResults: Int
    let responseTimeMs: Int
}

struct WorkBuddyFetchOutcome {
    let url: String
    let contentType: String
    let content: String
}

enum WorkBuddySearchError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return "WorkBuddy search error"
    }
}

/// 搜索/抓取只认 product.json 里的 endpoint，这一点与真实 CLI 一致：
/// `CODEBUDDY_BASE_URL` 只影响模型请求，不影响 /agenttool/*（实测确认）。
final class WorkBuddySearchClient {
    static let searchPath = "/agenttool/v1/search"
    static let fetchPath = "/agenttool/v1/webfetch"
    /// 与 CLI 对齐：搜索 20s、抓取 20s 超时，抓取正文上限 100k 字符。
    static let searchTimeout: TimeInterval = 20
    static let fetchTimeout: TimeInterval = 20
    static let fetchMaxLength = 100_000

    private let accounts: WorkBuddyAccountPool

    init(accounts: WorkBuddyAccountPool) {
        self.accounts = accounts
    }

    private var endpoint: String {
        let product = (try? JSONSerialization.jsonObject(with: Data(contentsOf: workBuddyProductURL))) as? [String: Any]
        return (text(product?["endpoint"]) ?? "https://copilot.tencent.com")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - 搜索

    func search(_ arguments: [String: Any]) throws -> WorkBuddySearchOutcome {
        // 参数校验与 CLI 的 zod schema 保持一致。
        guard let rawQuery = arguments["query"] as? String else {
            throw WorkBuddySearchError.message("The 'query' parameter is required.")
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            throw WorkBuddySearchError.message("The 'query' parameter must be at least 2 characters long.")
        }
        let allowed = (arguments["allowed_domains"] as? [String]) ?? []
        let blocked = (arguments["blocked_domains"] as? [String]) ?? []
        let freshness = arguments["freshness"] as? String

        // CLI 把 blocked_domains 折进查询串：`query (-site:a -site:b)`。
        let suffix = blocked.isEmpty ? "" : " (" + blocked.map { "-site:\($0)" }.joined(separator: " ") + ")"
        var body: [String: Any] = ["query": query + suffix, "type": "text2text", "max_results": 5]
        if !allowed.isEmpty { body["allowed_domains"] = allowed }
        if let freshness, Self.isValidFreshness(freshness) { body["freshness"] = freshness }

        let root = try post(Self.searchPath, body: body, timeout: Self.searchTimeout)
        let results = (root["results"] as? [[String: Any]]) ?? []
        return WorkBuddySearchOutcome(
            provider: text(root["provider"]) ?? "",
            results: results.map {
                WorkBuddySearchHit(title: text($0["title"]) ?? "Untitled",
                                   url: text($0["url"]) ?? "",
                                   snippet: text($0["snippet"]) ?? "",
                                   site: text($0["site"]), favicon: text($0["favicon"]))
            },
            totalResults: (root["total_results"] as? NSNumber)?.intValue ?? results.count,
            responseTimeMs: (root["response_time_ms"] as? NSNumber)?.intValue ?? 0)
    }

    /// CLI 的正则：d1-d30 / m1-m12 / y1-y5，N 可省略。
    static func isValidFreshness(_ value: String) -> Bool {
        guard let first = value.first, "dmy".contains(first) else { return false }
        let digits = value.dropFirst()
        if digits.isEmpty { return true }
        guard digits.allSatisfy(\.isNumber), let n = Int(digits) else { return false }
        switch first {
        case "d": return (1...30).contains(n)
        case "m": return (1...12).contains(n)
        case "y": return (1...5).contains(n)
        default: return false
        }
    }

    // MARK: - 抓取

    func fetch(_ arguments: [String: Any], model: String? = nil) throws -> WorkBuddyFetchOutcome {
        guard let rawURL = arguments["url"] as? String, !rawURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WorkBuddySearchError.message("The 'url' parameter is required.")
        }
        guard let prompt = arguments["prompt"] as? String else {
            throw WorkBuddySearchError.message("The 'prompt' parameter is required.")
        }
        var url = rawURL.trimmingCharacters(in: .whitespaces)
        // CLI 会自动把 http 升级成 https。
        if url.hasPrefix("http://") { url = "https://" + url.dropFirst("http://".count) }
        guard url.hasPrefix("https://") else {
            throw WorkBuddySearchError.message("The URL must be a fully-formed https:// URL.")
        }

        var body: [String: Any] = [
            "url": url, "format": "markdown", "prompt": prompt,
            "timeout": Int(Self.fetchTimeout), "max_length": Self.fetchMaxLength
        ]
        if let model, !model.isEmpty { body["model_name"] = model }

        let root = try post(Self.fetchPath, body: body, timeout: Self.fetchTimeout)
        guard let content = root["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkBuddySearchError.message("No readable content found on the page.")
        }
        return WorkBuddyFetchOutcome(url: text(root["url"]) ?? url,
                                     contentType: text(root["content_type"]) ?? "text/markdown",
                                     content: content)
    }

    // MARK: - 传输

    private func post(_ path: String, body: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        guard let url = URL(string: endpoint + path) else {
            throw WorkBuddySearchError.message("WorkBuddy 搜索地址无效")
        }
        var lastError: Error?
        // 与聊天链路共用账号池：优先账号优先，失败换下一个。
        for context in try accounts.contexts(for: nil) {
            do {
                let request = try makeRequest(url: url, context: context, body: body, timeout: timeout)
                let (data, response) = try syncData(request, timeout: timeout + 5)
                if response.statusCode == 401 {
                    lastError = WorkBuddySearchError.message("WorkBuddy 登录已失效，请在 WorkBuddy 内重新登录")
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                        .flatMap { text($0["msg"]) } ?? "HTTP \(response.statusCode)"
                    lastError = WorkBuddySearchError.message(message)
                    continue
                }
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw WorkBuddySearchError.message("Search API 返回了非对象 JSON")
                }
                // 业务失败不能算账号成功：先判定 code，再决定是否换号。
                if let failure = Self.businessFailure(in: root) {
                    lastError = WorkBuddySearchError.message(failure.message)
                    continue
                }
                accounts.markSuccess(accountID: context.id)
                return root
            } catch {
                lastError = error
            }
        }
        throw lastError ?? WorkBuddySearchError.message("没有可用的 WorkBuddy 账号")
    }

    private func makeRequest(url: URL, context: WorkBuddyAccountContext,
                             body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try workBuddyJSONData(body)
        let ident = WorkBuddyTelemetry.identifiers()

        // 与 CLI 的 search / webfetch 请求同一套头部（codebuddy.js performWebSearch 的 header 表）。
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("CLI/\(codeBuddyCLIVersion) CodeBuddy/\(codeBuddyCLIVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(context.userID, forHTTPHeaderField: "X-User-Id")
        request.setValue("craft", forHTTPHeaderField: "X-Agent-Intent")
        request.setValue("other", forHTTPHeaderField: "X-Agent-Runtime")
        request.setValue("SaaS", forHTTPHeaderField: "X-Product")
        request.setValue("CLI", forHTTPHeaderField: "X-IDE-Type")
        request.setValue("CLI", forHTTPHeaderField: "X-IDE-Name")
        request.setValue(codeBuddyCLIVersion, forHTTPHeaderField: "X-IDE-Version")
        request.setValue(ident.conversationID, forHTTPHeaderField: "X-Conversation-ID")
        request.setValue(ident.rootRequestID, forHTTPHeaderField: "X-Conversation-Request-ID")
        request.setValue(ident.messageID, forHTTPHeaderField: "X-Conversation-Message-ID")
        request.setValue(ident.messageID, forHTTPHeaderField: "X-Request-ID")
        request.setValue(ident.traceID, forHTTPHeaderField: "X-Trace-ID")
        request.setValue("00-\(ident.traceID)-\(ident.spanID)-01", forHTTPHeaderField: "traceparent")
        request.setValue("\(ident.traceID)-\(ident.spanID)-1-\(ident.parentSpanID)", forHTTPHeaderField: "b3")
        request.setValue("codebuddy.session_id=\(ident.conversationID),codebuddy.conversation_request_id=\(ident.rootRequestID)",
                         forHTTPHeaderField: "baggage")
        if let domain = context.domain { request.setValue(domain, forHTTPHeaderField: "X-Domain") }
        if let enterprise = context.enterpriseID { request.setValue(enterprise, forHTTPHeaderField: "X-Enterprise-Id") }
        else { request.setValue("1", forHTTPHeaderField: "X-No-Enterprise-Id") }
        return request
    }

    private func syncData(_ request: URLRequest, timeout: TimeInterval) throws -> (Data, HTTPURLResponse) {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var captured: Result<(Data, HTTPURLResponse), Error>?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            lock.lock(); defer { lock.unlock(); done.signal() }
            if let error { captured = .failure(error); return }
            guard let http = response as? HTTPURLResponse else {
                captured = .failure(WorkBuddySearchError.message("Invalid HTTP response")); return
            }
            captured = .success((data ?? Data(), http))
        }
        task.resume()
        guard done.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw WorkBuddySearchError.message("Search API 请求超时")
        }
        lock.lock(); defer { lock.unlock() }
        return try captured!.get()
    }

    private func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let result = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    // MARK: - 对外工具定义

    /// 与 CodeBuddy 原生 schema 逐字段一致：strict=false，parameters 带 $schema 与 additionalProperties。
    static var toolDefinitions: [[String: Any]] { [searchDefinition, fetchDefinition] }

    static let searchDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "WebSearch",
            "description": """
            - Searches the web and uses the results to inform responses
            - Supports WeChat Official Account (微信公众号、公众号) content as a search source.
            - Provides up-to-date information for current events and recent data
            - Returns search result information formatted as search result blocks
            - Use this tool for accessing information beyond the knowledge cutoff
            - Searches are performed automatically within a single API call
            - You MUST use the current time provided in context when searching for recent information.
            """,
            "strict": false,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "minLength": 2, "description": "Search query to run"],
                    "allowed_domains": ["type": "array", "items": ["type": "string"],
                                        "description": "Return results only from these domains."],
                    "blocked_domains": ["type": "array", "items": ["type": "string"],
                                        "description": "Leave out results from these domains"],
                    "freshness": ["type": "string",
                                  "pattern": "^(?:d(?:[1-9]|[12]\\d|30)?|m(?:[1-9]|1[0-2])?|y[1-5]?)$",
                                  "description": "Filter results by time range: d[N] days, m[N] months, y[N] years."]
                ],
                "required": ["query"],
                "additionalProperties": false,
                "$schema": "http://json-schema.org/draft-07/schema#"
            ]
        ]
    ]

    static let fetchDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "WebFetch",
            "description": """
            - Fetches content from a specified URL and processes it using an AI model
            - Takes a URL and a prompt as input
            - Fetches the URL content, converts HTML to markdown
            - Processes the content with the prompt using a small, fast model
            - Returns the model's response about the content
            - Use this tool when you need to retrieve and analyze web content
            """,
            "strict": false,
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The URL to fetch content from"],
                    "prompt": ["type": "string", "description": "The prompt to run on the fetched content"]
                ],
                "required": ["url", "prompt"],
                "additionalProperties": false,
                "$schema": "http://json-schema.org/draft-07/schema#"
            ]
        ]
    ]

    // MARK: - Self test

    /// 业务结果判定：`code` 缺省或为 0 才算成功。抽出来是为了能脱离网络断言。
    static func businessFailure(in root: [String: Any]) -> (message: String, code: String)? {
        guard let code = root["code"], !(code is NSNull) else { return nil }
        let text = "\(code)"
        guard text != "0" else { return nil }
        let message = (root["msg"] as? String) ?? "Search API error \(text)"
        return (message, text)
    }

    static func selfTest() {
        for valid in ["d", "d1", "d30", "m", "m12", "y", "y5"] {
            precondition(isValidFreshness(valid), "应接受 \(valid)")
        }
        for invalid in ["d0", "d31", "m0", "m13", "y0", "y6", "x1", "dd", "d1x", ""] {
            precondition(!isValidFreshness(invalid), "应拒绝 \(invalid)")
        }
        // 工具定义形状与 CodeBuddy 原生一致。
        for definition in toolDefinitions {
            precondition(definition["type"] as? String == "function")
            let function = definition["function"] as! [String: Any]
            precondition(function["strict"] as? Bool == false)
            let parameters = function["parameters"] as! [String: Any]
            precondition(parameters["$schema"] as? String == "http://json-schema.org/draft-07/schema#")
            precondition(parameters["additionalProperties"] as? Bool == false)
            precondition(parameters["type"] as? String == "object")
        }
        precondition((searchDefinition["function"] as! [String: Any])["name"] as? String == "WebSearch")
        precondition((fetchDefinition["function"] as! [String: Any])["name"] as? String == "WebFetch")

        // P2c 回归：业务失败必须被识别，且不能当作账号成功。
        precondition(businessFailure(in: ["code": 50001, "msg": "频率限制"])?.code == "50001")
        precondition(businessFailure(in: ["code": "50001"])?.message == "Search API error 50001")
        precondition(businessFailure(in: ["code": 0]) == nil, "code=0 是成功")
        precondition(businessFailure(in: ["code": NSNull()]) == nil, "code=null 视为成功")
        precondition(businessFailure(in: [:]) == nil, "无 code 字段视为成功")
        // 真实成功响应里带 results，不应被判为失败。
        let okRoot: [String: Any] = ["provider": "p", "results": [], "total_results": 0]
        precondition(businessFailure(in: okRoot) == nil)
        // 字符串 "0" 也是成功（网关偶尔以字符串返回）。
        precondition(businessFailure(in: ["code": "0"]) == nil)
    }
}
