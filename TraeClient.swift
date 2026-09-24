import Foundation
import CommonCrypto

// Trae(国内版 SOLO)上游客户端：登录态读自本机 storage.json，对话走
// /api/agent/v3/llm_utils_chat（SSE），模型表走 /api/ide/v1/get_detail_param。
// accessToken 只在请求头里使用，任何路径都不写日志、不进错误信息。

private let traeAgentHost = "https://trae-api-cn.mchost.guru"
private let traeUgHost = "https://api.trae.cn"
private let traeAppID = "6eefa01c-1036-4c7e-9ca5-d891f63bfcd8"
private let traeIdeVersion = "0.1.69"
private let traeIdeVersionCode = "20260922"
private let traeFunction = "solo_work_lite"
private let traeStorageURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/TRAE SOLO CN/User/globalStorage/storage.json")
private let traeStateDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/TRAE SOLO CN/User/globalStorage/state.vscdb")

let traeAPIPrefix = "/trae/v1"
let traeDefaultModel = "glm-5.2"

// 共享代理是否值得启动：装了 Trae 应用或已有登录态（登录态失效由上游 401 暴露）。
var traeInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/TRAE SOLO CN.app") }
var traeLoggedIn: Bool { FileManager.default.fileExists(atPath: traeStorageURL.path) }

struct TraeModel {
    let id: String
    let name: String
    let context: Int
    let multiplier: String?

    var json: [String: Any] {
        var value: [String: Any] = [
            "id": id, "object": "model", "created": Int(Date().timeIntervalSince1970),
            "owned_by": "trae", "name": name, "type": "chat", "supports_tool_call": true
        ]
        value["context_window_tokens"] = context > 0 ? context : NSNull()
        value["credits"] = multiplier ?? NSNull()
        return value
    }
}

struct TraeCheckinState {
    let checkedIn: Bool
    let didCheckedIn: Bool
    let checkinActive: Bool
    let baseCredit: Double
    let bonusCredit: Double

    var todayCredit: Double { baseCredit + bonusCredit }
}

struct TraeCredits {
    let remaining: Int?
    let unlimited: Bool

    var text: String {
        if unlimited { return "不限积分" }
        return remaining.map { "\($0.formatted()) 积分" } ?? "积分未知"
    }
}

struct TraeAuth {
    let token: String
    let uid: String
    let deviceID: String
    let machineID: String
    let refreshToken: String?
    let displayName: String
}

enum TraeError: Error, LocalizedError {
    case message(String)
    // 账号级上游错误：只在流开始前抛出，调用方据此换号；已开始输出时绝不会走到这里。
    case account(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .account(_, let detail): return detail
        }
    }

    var isAccountFailure: Bool {
        if case .account(let status, _) = self { return traeAccountFailure(status: status) }
        return false
    }
}

// 账号级失败：仅这些状态码才值得换下一个账号；其他 4xx 是请求本身的问题，换号也没用。
func traeAccountFailure(status: Int) -> Bool {
    status == 401 || status == 403 || status == 429 || (500..<600).contains(status)
}

// MARK: - 登录态

// Trae 前端 JS 里的两段 64 字节盐，按位异或后参与密钥派生（明文版直接是 JSON）。
private let traeSaltA: [UInt8] = [
    82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251,
    124, 227, 57, 130, 155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203,
    84, 123, 148, 50, 166, 194, 35, 61, 238, 76, 149, 11, 66, 250, 195, 78,
    8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37,
]
private let traeSaltB: [UInt8] = [
    31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95,
    96, 81, 127, 169, 25, 181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239,
    160, 224, 59, 77, 174, 42, 245, 176, 200, 235, 187, 60, 131, 83, 153, 97,
    23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125,
]

private func traeSHA512(_ bytes: [UInt8]) -> [UInt8] {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
    CC_SHA512(bytes, CC_LONG(bytes.count), &digest)
    return digest
}

private func traeAESDecrypt(key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
    var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                         key, key.count, iv, data, data.count, &out, out.count, &moved)
    guard status == kCCSuccess else { throw TraeError.message("Trae 登录态解密失败") }
    return Array(out[0..<moved])
}

// storage.json 的值：明文 JSON 直接返回，否则按 [6B 头][32B 随机数][密文] 解出 JSON。
func traeDecodeAuth(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") { return trimmed }
    var encoded = trimmed
    while encoded.count % 4 != 0 { encoded += "=" }
    guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), data.count > 38 else {
        throw TraeError.message("Trae 登录态格式无法识别")
    }
    let bytes = [UInt8](data)
    let random = Array(bytes[6..<38])
    let salt = zip(traeSaltA, traeSaltB).map(^)
    let keyMaterial = traeSHA512(traeSHA512(random) + salt)
    let decrypted = try traeAESDecrypt(key: Array(keyMaterial[0..<16]), iv: Array(keyMaterial[16..<32]),
                                       data: Array(bytes[38...]))
    guard decrypted.count > 64, Array(decrypted[0..<64]) == traeSHA512(Array(decrypted[64...])),
          let text = String(bytes: decrypted[64...], encoding: .utf8) else {
        throw TraeError.message("Trae 登录态校验失败，请重新登录 Trae")
    }
    return text
}

private func traeStorageValue(_ storage: [String: Any]) -> String? {
    guard let value = storage["iCubeAuthInfo://icube.cloudide"] else { return nil }
    if let text = value as? String, !text.isEmpty { return text }
    guard let data = try? workBuddyJSONData(value), let text = String(data: data, encoding: .utf8),
          !text.isEmpty else { return nil }
    return text
}

private func traeDeviceID(_ storage: [String: Any]) -> String {
    storage.keys.first { $0.hasPrefix("iCubeAuthInfo://icube-dc:") }?
        .split(separator: ":").last.map(String.init) ?? ""
}

// MARK: - 请求体翻译（OpenAI → llm_utils_chat）

// llm_utils_chat 只稳定接受 messages/function/stream/config_name/model 与工具、
// 采样字段，白名单之外的键（stream_options/reasoning_effort 之外的 agent 字段）
// 曾触发上游 4001/4023，这里显式构造而不透传。
func traeUpstreamBody(_ source: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    out["messages"] = traeMessages(source["messages"] as? [[String: Any]] ?? [])
    out["function"] = traeFunction
    out["stream"] = true
    let model = ((source["model"] as? String)?
        .split(separator: "/").last.map(String.init) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    out["config_name"] = model.isEmpty ? traeDefaultModel : model
    out["model"] = out["config_name"]
    if let tools = traeTools(source["tools"]) { out["tools"] = tools }
    if let choice = traeToolChoice(source["tool_choice"]) { out["tool_choice"] = choice }
    for key in ["temperature", "top_p", "presence_penalty", "frequency_penalty", "seed"] {
        if let value = source[key] as? NSNumber { out[key] = value }
    }
    // 只有调用方显式给了 max_tokens 才转发，不替上游默认值做主。
    if let maxTokens = source["max_tokens"] as? NSNumber { out["max_tokens"] = maxTokens }
    if let stop = source["stop"] { out["stop"] = stop }
    return out
}

func traeMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
    messages.map { message in
        var result = message
        // developer 是 OpenAI 新角色，上游不认（静默空流），归一为 system。
        if result["role"] as? String == "developer" { result["role"] = "system" }
        // assistant 回传的工具调用要转成上游的 function_call；上游 FunctionCall.Name 必填，
        // OpenAI 结构直接送过去会在入参反序列化时报 2001 "required field Name is not set"。
        if result["role"] as? String == "assistant", let calls = traeAssistantToolCalls(result["tool_calls"]) {
            result["tool_calls"] = calls
        }
        if let parts = result["content"] as? [[String: Any]] {
            result["content"] = parts.map { part in
                var copy = part
                if copy["type"] == nil { copy["type"] = "text" }
                return copy
            }
        } else if let text = result["content"] as? String {
            result["content"] = [["type": "text", "text": text]]
        }
        return result
    }
}

// assistant 消息里的 tool_calls：OpenAI function → 上游 function_call；无 name 的调用剔除。
func traeAssistantToolCalls(_ raw: Any?) -> [[String: Any]]? {
    guard let list = raw as? [[String: Any]] else { return nil }
    let calls = list.compactMap { item -> [String: Any]? in
        guard var call = item["function"] as? [String: Any] ?? item["function_call"] as? [String: Any] else { return nil }
        if let name = call["name"] as? String {
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        } else { return nil }
        if let arguments = call["arguments"], !(arguments is String), let text = try? workBuddyJSONData(arguments) {
            call["arguments"] = String(data: text, encoding: .utf8)
        }
        var translated = item
        translated["function_call"] = call
        translated.removeValue(forKey: "function")
        return translated
    }
    return calls.isEmpty ? nil : calls
}

// 上游 Go struct 里 tools[].function.parameters 是 string（OpenAI 是 object）。
func traeTools(_ raw: Any?) -> [[String: Any]]? {
    guard let list = raw as? [[String: Any]] else { return nil }
    let tools = list.compactMap { item -> [String: Any]? in
        guard var function = item["function"] as? [String: Any] else { return nil }
        if let parameters = function["parameters"], !(parameters is String),
           let text = try? workBuddyJSONData(parameters) {
            function["parameters"] = String(data: text, encoding: .utf8)
        }
        var tool = item
        tool["function"] = function
        return tool
    }
    return tools.isEmpty ? nil : tools
}

func traeToolChoice(_ raw: Any?) -> Any? {
    switch raw {
    case let text as String:
        return text.lowercased() == "none" ? nil : text
    case let object as [String: Any]:
        switch (object["type"] as? String)?.lowercased() {
        case "none":
            return nil
        case "auto", "required":
            return (object["type"] as? String)?.lowercased()
        case "function":
            let name = ((object["function"] as? [String: Any])?["name"] as? String ?? object["name"] as? String ?? "")
            return name.isEmpty ? "auto" : name
        default:
            return nil
        }
    default:
        return nil
    }
}

func traeToolCalls(_ raw: Any?) -> [[String: Any]]? {
    guard let raw, !(raw is NSNull) else { return nil }
    let entries: [[String: Any]]
    if let list = raw as? [[String: Any]] { entries = list }
    else if let one = raw as? [String: Any] { entries = [one] }
    else { return nil }
    let calls = entries.map { entry -> [String: Any] in
        var call = entry
        // SOLO 用 function_call，OpenAI 用 function；namespace/partial_arguments 是上游私有字段。
        if let function = call["function_call"] as? [String: Any] {
            call["function"] = traeCleanFunction(function)
            call.removeValue(forKey: "function_call")
        } else if let function = call["function"] as? [String: Any] {
            call["function"] = traeCleanFunction(function)
        }
        return call
    }
    return calls.isEmpty ? nil : calls
}

private func traeCleanFunction(_ function: [String: Any]) -> [String: Any] {
    var clean = function
    clean.removeValue(forKey: "namespace")
    clean.removeValue(forKey: "partial_arguments")
    return clean
}

func traeModel(_ entry: [String: Any]) -> TraeModel? {
    guard let id = entry["config_name"] as? String, !id.isEmpty else { return nil }
    if let enabled = entry["config_switch"] as? Bool, !enabled { return nil }
    if let hidden = entry["is_invisible_to_user"] as? Bool, hidden { return nil }
    guard let display = (entry["display_config"] as? [String: Any])?["display_name"] as? String,
          !display.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let context = ((entry["context_window_tokens"] as? [String: Any])?["dev"] as? NSNumber)?.intValue ?? 0
    let detail = ((entry["metadata"] as? [String: Any])?["detail"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return TraeModel(id: id, name: display, context: context,
                     multiplier: detail.flatMap { $0.isEmpty ? nil : $0 })
}

func traeModelMultipliers(_ root: [String: Any], function: String = traeFunction) -> [String: String] {
    guard let models = root[function] as? [[String: Any]] else { return [:] }
    return models.reduce(into: [:]) { result, model in
        guard let id = model["config_name"] as? String,
              let features = model["features"] as? [String: Any] else { return }
        let base = (((features["consumption_rate"] as? [String: Any])?["data"] as? [String: Any])?["rate"] as? NSNumber)?.doubleValue
        let discount = (features["discount"] as? [String: Any])?["data"] as? [String: Any]
        let activity = (features["activity_discount"] as? [String: Any])?["data"] as? [String: Any]
        let matched = discount?["is_discount_matched"] as? Bool == true
        let rate = matched
            ? (discount?["consumption_rate"] as? NSNumber)?.doubleValue
            : ((((activity?["current"] as? [String: Any])?["consumption_rate"] as? NSNumber)?.doubleValue) ?? base)
        guard let rate else { return }
        result[id] = String(format: "%.2fx", rate)
    }
}

func traeCredits(_ root: [String: Any]) -> TraeCredits {
    let value = root["data"] as? [String: Any] ?? root
    let billing = value["is_credits_billing"] as? Bool == true
    let packs = value["user_entitlement_pack_list"] as? [[String: Any]] ?? []
    var total = 0, known = billing
    for pack in packs {
        let info = pack["entitlement_base_info"] as? [String: Any] ?? [:]
        if (info["product_type"] as? NSNumber)?.intValue == 3 || info["is_hide"] as? Bool == true
            || (info["status"] as? NSNumber)?.intValue == 3 { continue }
        let extra = info["product_extra"] as? [String: Any] ?? [:]
        let subscription = extra["subscription_extra"] as? [String: Any] ?? [:]
        let package = extra["package_extra"] as? [String: Any] ?? [:]
        let quotaKeys = ["basic_usage_limit", "bonus_usage_limit", "premium_model_fast_request_limit", "credits_limit"]
        let quota = [info["quota"], subscription["quota"], package["quota"]]
            .compactMap { $0 as? [String: Any] }
            .first { quota in quotaKeys.contains { quota[$0] != nil } } ?? [:]
        guard let limit = (quota["credits_limit"] as? NSNumber)?.doubleValue else { continue }
        known = true
        if limit == -1 { return TraeCredits(remaining: nil, unlimited: true) }
        let usage = pack["usage"] as? [String: Any] ?? [:]
        let used = (usage["credits_amount"] as? NSNumber)?.doubleValue ?? 0
        total += Int(max(limit - used, 0).rounded())
    }
    return TraeCredits(remaining: known ? total : nil, unlimited: false)
}

func traeCheckinState(_ root: [String: Any]) throws -> TraeCheckinState {
    let value = root["data"] as? [String: Any] ?? root
    let code = ((root["code"] ?? value["code"]) as? NSNumber)?.intValue ?? -1
    guard code == 0 else {
        throw TraeError.message((root["message"] ?? value["message"]) as? String
                                ?? "Trae 签到接口返回错误（\(code)）")
    }
    return TraeCheckinState(
        checkedIn: value["checked_in"] as? Bool ?? false,
        didCheckedIn: value["did_checked_in"] as? Bool ?? false,
        checkinActive: value["enable"] as? Bool ?? false,
        baseCredit: (value["credits"] as? NSNumber)?.doubleValue ?? 0,
        bonusCredit: (value["extra_credits"] as? NSNumber)?.doubleValue ?? 0
    )
}

private func traeCheckinDeviceID() -> String {
    String((0..<16).map { _ in Character(String(Int.random(in: 0...9))) })
}

// MARK: - SSE 翻译（SOLO events → OpenAI choices[].delta）

struct TraeStreamTranslator {
    private let model: String
    private let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let created = Int(Date().timeIntervalSince1970)
    private var event = ""
    private var payload = ""
    private var started = false
    private var finished = false
    private var sentDone = false
    private var pendingUsage: [String: Any]?
    private var toolIDs: [Int: String] = [:]
    private var toolTypes: Set<Int> = []
    private var toolNames: Set<Int> = []
    private var sawToolCalls = false

    init(model: String) {
        self.model = model
    }

    mutating func consume(_ rawLine: String) -> Data? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        // 实测发现 URLSession.bytes.lines 不产出 SSE 的空行，事件边界只能靠下一条
        // event: 判定（曾按空行收口，导致所有 output 事件被丢弃、正文全空）。
        if line.hasPrefix("data:") {
            // 多 data 行按 SSE 规则拼接；id:/注释行忽略。
            let text = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            payload = payload.isEmpty ? text : payload + "\n" + text
            return nil
        }
        if line.isEmpty { return flush() }
        guard line.hasPrefix("event:") else { return nil }
        let pending = flush()
        event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        return pending
    }

    // 收口最后一条事件；上游没有 done（断流）时补兜底 finish frame；[DONE] 恰好一次。
    mutating func finish() -> Data? {
        var out = Data()
        if let pending = flush() { out.append(pending) }
        if !finished { out.append(frame([:], finish: normalFinish(nil))) }
        if !sentDone {
            sentDone = true
            out.append(Data("data: [DONE]\n\n".utf8))
        }
        return out.isEmpty ? nil : out
    }

    private mutating func flush() -> Data? {
        let name = event
        let body = payload
        event = ""
        payload = ""
        guard !body.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        switch name {
        case "output":
            var delta: [String: Any] = [:]
            if let text = value["response"] as? String, !text.isEmpty { delta["content"] = text }
            if let think = value["reasoning_content"] as? String, !think.isEmpty { delta["reasoning_content"] = think }
            if let calls = normalizedToolCalls(value["tool_calls"]) { delta["tool_calls"] = calls }
            return delta.isEmpty ? nil : frame(delta, finish: nil)
        case "token_usage":
            pendingUsage = value
            return nil
        case "done":
            return frame([:], finish: normalFinish(value["finish_reason"] as? String))
        case "error":
            let code = (value["code"] as? NSNumber)?.intValue ?? 0
            let message = value["message"] as? String ?? "unknown"
            // 上游错误不进 choices.delta.content（否则会混进正文），改成 OpenAI 风格错误对象，
            // 消息裁长并复用入参过滤器，避免回显请求头里的凭证。
            return errorFrame(code: code, message: message)
        default:
            return nil
        }
    }

    // 上游 done 常把工具调用报成 stop；见过 tool_calls 就规范为 tool_calls，
    // 但上游明确给出的失败原因（error/length 等）原样保留。
    private func normalFinish(_ raw: String?) -> String {
        let reason = raw.flatMap { $0.isEmpty ? nil : $0 } ?? "stop"
        return sawToolCalls && reason == "stop" ? "tool_calls" : reason
    }

    // 按 OpenAI 流式规范整理工具调用：index 稳定；id/type/name 每个 index 只发一次
    // （上游常给空串），缺 id 时生成稳定的 call_... ；arguments 保持增量片段原样透出。
    private mutating func normalizedToolCalls(_ raw: Any?) -> [[String: Any]]? {
        guard let entries = traeToolCalls(raw) else { return nil }
        sawToolCalls = true
        var out: [[String: Any]] = []
        for (position, entry) in entries.enumerated() {
            let index = (entry["index"] as? NSNumber)?.intValue ?? position
            let function = entry["function"] as? [String: Any] ?? [:]
            var call: [String: Any] = ["index": index]
            if !toolIDs.keys.contains(index) {
                let provided = (entry["id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let identifier = provided.isEmpty
                    ? "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
                    : provided
                toolIDs[index] = identifier
                call["id"] = identifier
            }
            if toolTypes.insert(index).inserted {
                let kind = (entry["type"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                call["type"] = kind.isEmpty ? "function" : kind
            }
            var payload: [String: Any] = [:]
            if !toolNames.contains(index) {
                let name = (function["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                if !name.isEmpty {
                    toolNames.insert(index)
                    payload["name"] = name
                }
            }
            if let arguments = function["arguments"] as? String { payload["arguments"] = arguments }
            if !payload.isEmpty { call["function"] = payload }
            if call.count > 1 { out.append(call) }
        }
        return out.isEmpty ? nil : out
    }

    private mutating func frame(_ delta: [String: Any], finish: String?) -> Data {
        var out = Data()
        if !started {
            started = true
            out.append(encode(["role": "assistant"], finish: nil, usage: nil))
        }
        out.append(encode(delta, finish: finish, usage: finish == nil ? nil : pendingUsage))
        if finish != nil {
            finished = true
            pendingUsage = nil
        }
        return out
    }

    private mutating func errorFrame(code: Int, message: String) -> Data {
        var out = frame([:], finish: "stop")
        let detail = traeUpstreamMessage(Data(message.utf8)) ?? message
        let payload: [String: Any] = [
            "id": id, "object": "chat.completion.chunk", "created": created,
            "choices": [] as [Any],
            "error": ["message": "Trae 上游错误 code=\(code)：\(String(detail.prefix(300)))",
                      "type": "upstream_error", "code": code],
        ]
        if let data = try? workBuddyJSONData(payload), let text = String(data: data, encoding: .utf8) {
            out.append(Data(("data: " + text + "\n\n").utf8))
        }
        return out
    }

    private func encode(_ delta: [String: Any], finish: String?, usage: [String: Any]?) -> Data {
        let choice: [String: Any] = ["index": 0, "delta": delta, "finish_reason": finish ?? NSNull()]
        var chunk: [String: Any] = [
            "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
            "choices": [choice],
        ]
        if let usage {
            var normalized = usage
            var promptDetails = usage["prompt_tokens_details"] as? [String: Any] ?? [:]
            if let value = usage["cache_read_input_tokens"] as? NSNumber { promptDetails["cached_tokens"] = value }
            if let value = usage["cache_creation_input_tokens"] as? NSNumber { promptDetails["cache_write_tokens"] = value }
            if !promptDetails.isEmpty { normalized["prompt_tokens_details"] = promptDetails }
            var completionDetails = usage["completion_tokens_details"] as? [String: Any] ?? [:]
            if let value = usage["reasoning_tokens"] as? NSNumber { completionDetails["reasoning_tokens"] = value }
            if !completionDetails.isEmpty { normalized["completion_tokens_details"] = completionDetails }
            chunk["usage"] = normalized
        }
        let text = (try? workBuddyJSONData(chunk)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Data(("data: " + text + "\n\n").utf8)
    }
}

// MARK: - 客户端

// 本机 Trae 当前登录态（读 storage.json 并解密），与进程内缓存分离，
// 供账号池导入使用：池外的调用一律不走这里。
func traeLocalAuth() throws -> TraeAuth {
    guard let data = try? Data(contentsOf: traeStorageURL),
          let storage = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = traeStorageValue(storage),
          let text = try? traeDecodeAuth(raw),
          let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          let token = (root["token"] as? String), !token.isEmpty else {
        throw TraeError.message("未找到 Trae 登录态，请先登录 Trae SOLO CN")
    }
    let account = root["account"] as? [String: Any] ?? [:]
    let userId = (root["userId"] ?? account["uid"] ?? account["oneidAccountId"])
        .map { ($0 as? NSNumber)?.stringValue ?? String(describing: $0) } ?? ""
    let nickname = (account["username"] ?? account["nickname"]).map { String(describing: $0) } ?? ""
    return TraeAuth(
        token: token,
        // 本机 storage.json 里 uid 只在根层 userId（account 段是资料字段）。
        uid: userId,
        deviceID: traeDeviceID(storage),
        machineID: storage["telemetry.machineId"] as? String ?? "",
        refreshToken: root["refreshToken"] as? String,
        displayName: nickname.isEmpty ? "Trae ···" + String(userId.suffix(4)) : nickname
    )
}

final class TraeClient {
    static let apiKey = "trae-local"

    private let accounts: TraeAccountPool

    init(accounts: TraeAccountPool) {
        self.accounts = accounts
    }

    // 池里的 Token + 本机机器标识（deviceID/machineID 与账号无关，永远取自本机 storage.json）。
    private func auth(_ context: TraeAccountContext) -> TraeAuth {
        let machine = (try? Data(contentsOf: traeStorageURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return TraeAuth(token: context.accessToken, uid: context.uid,
                        deviceID: traeDeviceID(machine),
                        machineID: machine["telemetry.machineId"] as? String ?? "",
                        refreshToken: context.refreshToken, displayName: context.name)
    }

    func models() throws -> [TraeModel] {
        // 模型表按账号返回：与 chat 同一套规则，账号级失败才换下一个账号。
        var lastAccountError: Error?
        for context in try accounts.contexts() {
            do {
                let models = try models(context: context)
                accounts.markUsed(accountID: context.id)
                return models
            } catch let error as TraeError where error.isAccountFailure {
                lastAccountError = error
            }
        }
        if let lastAccountError { throw lastAccountError }
        throw TraeError.message("没有可用的 Trae 账号")
    }

    func checkinStatus(accountID: String? = nil) throws -> TraeCheckinState {
        try checkinStatus(context: checkinContext(accountID: accountID), deviceID: nil)
    }

    func credits(accountID: String? = nil) throws -> TraeCredits {
        let context = try checkinContext(accountID: accountID)
        var request = checkinRequest(path: "/trae/api/v2/pay/ide_user_ent_usage",
                                     context: context, deviceID: nil)
        request.httpBody = try workBuddyJSONData([:])
        let root = try traeJSON(request) ?? [:]
        if let code = (root["code"] as? NSNumber)?.intValue, code != 0 {
            throw TraeError.message(root["message"] as? String ?? "Trae 积分查询失败（\(code)）")
        }
        return traeCredits(root)
    }

    func claimCheckin(accountID: String? = nil) throws -> TraeCheckinState {
        let context = try checkinContext(accountID: accountID)
        let deviceID = traeCheckinDeviceID()
        let before = try checkinStatus(context: context, deviceID: deviceID)
        guard before.checkinActive, !before.checkedIn, !before.didCheckedIn else { return before }
        var request = checkinRequest(path: "/trae/api/v2/ug/checkin_credits/claim",
                                     context: context, deviceID: deviceID)
        request.httpBody = try workBuddyJSONData(["req_source": 2])
        let root = try traeJSON(request) ?? [:]
        let value = root["data"] as? [String: Any] ?? root
        let code = ((root["code"] ?? value["code"]) as? NSNumber)?.intValue ?? -1
        guard code == 0 else {
            throw TraeError.message((root["message"] ?? value["message"]) as? String
                                    ?? "Trae 签到失败（\(code)）")
        }
        return try checkinStatus(context: context, deviceID: deviceID)
    }

    private func checkinContext(accountID: String?) throws -> TraeAccountContext {
        let contexts = try accounts.contexts()
        if let accountID, let context = contexts.first(where: { $0.id == accountID }) { return context }
        guard accountID == nil, let context = contexts.first else {
            throw TraeError.message("找不到指定的 Trae 账号")
        }
        return context
    }

    private func checkinStatus(context: TraeAccountContext, deviceID: String?) throws -> TraeCheckinState {
        var request = checkinRequest(path: "/trae/api/v2/ug/checkin_credits/status",
                                     context: context, deviceID: deviceID)
        request.httpBody = try workBuddyJSONData(["req_source": 2])
        return try traeCheckinState(traeJSON(request) ?? [:])
    }

    private func checkinRequest(path: String, context: TraeAccountContext, deviceID: String?) -> URLRequest {
        var request = traeRequest(path: path, auth: auth(context), accept: "application/json")
        request.url = URL(string: traeUgHost + path)!
        if let deviceID { request.setValue(deviceID, forHTTPHeaderField: "x-device-id") }
        return request
    }

    private func models(context: TraeAccountContext) throws -> [TraeModel] {
        var request = traeRequest(path: "/api/ide/v1/get_detail_param", auth: auth(context),
                                  accept: "application/json")
        request.httpBody = try workBuddyJSONData([
            "function": traeFunction, "config_names": NSNull(), "need_prompt": false,
            "current_config_info": NSNull(), "poly_prompt": true, "mode_type": NSNull(), "agent_type": NSNull(),
        ])
        let root = try traeJSON(request) ?? [:]
        let list = root["config_info_list"] as? [[String: Any]] ?? []
        let multipliers = cachedModelMultipliers(uid: context.uid)
        let models = list.compactMap(traeModel).map {
            TraeModel(id: $0.id, name: $0.name, context: $0.context,
                      multiplier: multipliers[$0.id] ?? $0.multiplier)
        }
        guard !models.isEmpty else { throw TraeError.message("Trae 模型目录为空，请重新登录 Trae") }
        return models
    }

    // 官方客户端按 uid 缓存完整模型特性；get_detail_param 本身不返回 consumption_rate。
    private func cachedModelMultipliers(uid: String) -> [String: String] {
        guard FileManager.default.fileExists(atPath: traeStateDatabaseURL.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return [:] }
        let escaped = uid.replacingOccurrences(of: "'", with: "''")
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", traeStateDatabaseURL.path,
                             "SELECT value FROM ItemTable WHERE key='\(escaped):AI.agent.model.model_list_map' LIMIT 1;"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return traeModelMultipliers(root)
    }

    func chat(_ source: [String: Any], onStart: @escaping () -> Void,
              onData: @escaping (Data) -> Void, completion: @escaping (Error?) -> Void) {
        Task {
            do {
                var lastAccountError: Error?
                for context in try accounts.contexts() {
                    do {
                        try await streamRequest(source, context: context,
                                                onStart: onStart, onData: onData)
                        accounts.markUsed(accountID: context.id)
                        completion(nil)
                        return
                    } catch let error as TraeError where error.isAccountFailure {
                        // 仅在流尚未开始时换号；onStart 之后的错误由 streamRequest 直接抛出。
                        lastAccountError = error
                    }
                }
                if let lastAccountError { throw lastAccountError }
                throw TraeError.message("没有可用的 Trae 账号")
            } catch { completion(error) }
        }
    }

    private func streamRequest(_ source: [String: Any], context: TraeAccountContext,
                               onStart: @escaping () -> Void,
                               onData: @escaping (Data) -> Void) async throws {
        let body = traeUpstreamBody(source)
        var request = traeRequest(path: "/api/agent/v3/llm_utils_chat", auth: auth(context),
                                  accept: "text/event-stream")
        request.httpBody = try workBuddyJSONData(body)
        request.timeoutInterval = 300
        let (bytes, rawResponse) = try await URLSession.shared.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw TraeError.message("Trae 响应无效")
        }
        guard (200..<300).contains(response.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            // 流未开始：账号级错误交给外层换号，其余原样抛出。
            throw TraeError.account(status: response.statusCode,
                                    detail: traeUpstreamMessage(data) ?? "Trae 返回 HTTP \(response.statusCode)")
        }
        var translator = TraeStreamTranslator(model: body["model"] as? String ?? traeDefaultModel)
        onStart()
        for try await line in bytes.lines {
            if let chunk = translator.consume(line) { onData(chunk) }
        }
        if let tail = translator.finish() { onData(tail) }
    }

    private func traeRequest(path: String, auth: TraeAuth, accept: String) -> URLRequest {
        var request = URLRequest(url: URL(string: traeAgentHost + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        [
            "Content-Type": "application/json", "Accept": accept,
            "Authorization": "Cloud-IDE-JWT \(auth.token)", "X-Cloudide-Token": auth.token,
            "x-app-id": traeAppID, "x-app-version": "default", "x-app-version-code": traeIdeVersionCode,
            "x-ide-version": traeIdeVersion, "x-ide-version-code": traeIdeVersionCode,
            "x-ide-version-type": "stable", "x-device-id": auth.deviceID, "x-machine-id": auth.machineID,
            "x-device-type": "darwin", "x-device-cpu": "arm64", "x-os-version": "darwin",
            "x-request-id": UUID().uuidString, "x-uid": auth.uid, "request-traffic-type": "prod",
        ].forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }

    private func traeJSON(_ request: URLRequest) throws -> [String: Any]? {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var captured: Result<Data, Error>?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            lock.lock()
            defer { lock.unlock(); done.signal() }
            if let error { captured = .failure(error); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                // 带上状态码，调用方才能区分账号级失败（换号）与普通 4xx（直接返回）。
                captured = .failure(TraeError.account(
                    status: status,
                    detail: traeUpstreamMessage(data ?? Data()) ?? "Trae 返回 HTTP \(status)"))
                return
            }
            captured = .success(data ?? Data())
        }
        task.resume()
        guard done.wait(timeout: .now() + 30) == .success else {
            task.cancel()
            throw TraeError.message("Trae 请求超时")
        }
        lock.lock()
        defer { lock.unlock() }
        let data = try captured!.get()
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func selfTest() {
        // 账号级失败判定：只有这几类状态码才换号，普通 4xx/解析错误立即返回。
        precondition(traeAccountFailure(status: 401))
        precondition(traeAccountFailure(status: 403))
        precondition(traeAccountFailure(status: 429))
        precondition(traeAccountFailure(status: 500))
        precondition(traeAccountFailure(status: 599))
        precondition(!traeAccountFailure(status: 400))
        precondition(!traeAccountFailure(status: 404))
        precondition(!traeAccountFailure(status: 422))
        precondition(!traeAccountFailure(status: 200))
        precondition(!traeAccountFailure(status: 600))
        precondition(!TraeError.message("解析失败").isAccountFailure)
        precondition(TraeError.account(status: 401, detail: "x").isAccountFailure)
        precondition(!TraeError.account(status: 400, detail: "x").isAccountFailure)
        // 账号级错误对外只暴露 detail，不泄露 token。
        precondition(TraeError.account(status: 500, detail: "上游错误").errorDescription == "上游错误")

        let fixtures: [[String: Any]] = [
            ["config_name": "glm-5.3", "config_switch": true, "is_invisible_to_user": false,
             "display_config": ["display_name": "GLM-5.3"], "context_window_tokens": ["dev": 200_000],
             "metadata": ["detail": "0.5x"]],
            ["config_name": "browser_use_subagent", "is_invisible_to_user": true,
             "display_config": ["display_name": "subagent"]],
            ["config_name": "custom_model_x", "display_config": ["display_name": ""]],
            ["config_name": "retired", "config_switch": false, "display_config": ["display_name": "Retired"]],
        ]
        let models = fixtures.compactMap(traeModel)
        precondition(models.count == 1)
        precondition(models[0].id == "glm-5.3" && models[0].context == 200_000)
        precondition(models[0].multiplier == "0.5x")
        let rates = traeModelMultipliers([traeFunction: [
            ["config_name": "base", "features": ["consumption_rate": ["data": ["rate": 0.78]]]],
            ["config_name": "member", "features": [
                "consumption_rate": ["data": ["rate": 0.78]],
                "discount": ["data": ["is_discount_matched": true, "consumption_rate": 0.39]],
            ]],
            ["config_name": "activity", "features": [
                "consumption_rate": ["data": ["rate": 0.16]],
                "activity_discount": ["data": ["current": ["consumption_rate": 0.08]]],
            ]],
        ]])
        precondition(rates == ["base": "0.78x", "member": "0.39x", "activity": "0.08x"])
        let credits = traeCredits(["is_credits_billing": true, "user_entitlement_pack_list": [
            ["entitlement_base_info": ["product_type": 1, "quota": ["credits_limit": 200]],
             "usage": ["credits_amount": 49.4]],
            ["entitlement_base_info": ["product_type": 0, "quota": ["credits_limit": 50]]],
            ["entitlement_base_info": ["product_type": 3, "quota": ["credits_limit": 999]]],
        ]])
        precondition(credits.remaining == 201 && !credits.unlimited)
        let checkin = try! traeCheckinState(["code": 0, "checked_in": false, "did_checked_in": false,
                                             "enable": true, "credits": 150, "extra_credits": 50])
        precondition(checkin.checkinActive && checkin.todayCredit == 200)

        let body = traeUpstreamBody([
            "model": "trae/GLM-5.2", "stream": false, "stream_options": ["include_usage": true],
            "messages": [
                ["role": "developer", "content": "you are helpful"],
                ["role": "user", "content": [["text": "hi"]]],
            ],
            "tools": [["type": "function", "function": ["name": "exec",
                                                       "parameters": ["type": "object", "properties": [:]]]]],
            "tool_choice": ["type": "function", "function": ["name": "exec"]],
        ])
        precondition(body["function"] as? String == "solo_work_lite")
        precondition(body["stream"] as? Bool == true)
        precondition(body["config_name"] as? String == "GLM-5.2")
        precondition(body["model"] as? String == "GLM-5.2")
        precondition(body["stream_options"] == nil)
        precondition(body["max_tokens"] == nil)
        precondition(traeUpstreamBody(["model": "x", "messages": [], "max_tokens": 4096])["max_tokens"] as? Int == 4096)
        precondition(body["tool_choice"] as? String == "exec")
        let messages = body["messages"] as? [[String: Any]] ?? []
        precondition(messages.count == 2)
        precondition(messages[0]["role"] as? String == "system")
        precondition((messages[0]["content"] as? [[String: Any]])?.first?["type"] as? String == "text")
        precondition((messages[1]["content"] as? [[String: Any]])?.first?["text"] as? String == "hi")
        let tools = body["tools"] as? [[String: Any]] ?? []
        precondition((tools.first?["function"] as? [String: Any])?["parameters"] is String)
        precondition(traeUpstreamBody(["model": "", "messages": []])["model"] as? String == traeDefaultModel)
        precondition(traeToolChoice("none") == nil)
        precondition(traeToolChoice(["type": "auto"]) as? String == "auto")

        // assistant 工具调用回传：OpenAI function → 上游 function_call，无 name 的调用剔除。
        let assistant = traeMessages([[
            "role": "assistant", "content": "普通文本",
            "tool_calls": [
                ["id": "call_1", "type": "function", "index": 0,
                 "function": ["name": "echo_probe", "arguments": ["text": "OK"]]],
                ["id": "call_2", "type": "function", "function": ["name": "   ", "arguments": "{}"]],
                ["id": "call_3", "type": "function", "function": ["arguments": "{}"]],
            ],
        ], ["role": "tool", "tool_call_id": "call_1", "content": "OK"]])
        let translatedCalls = assistant[0]["tool_calls"] as? [[String: Any]] ?? []
        precondition(translatedCalls.count == 1)
        precondition(translatedCalls[0]["id"] as? String == "call_1")
        precondition(translatedCalls[0]["type"] as? String == "function")
        precondition(translatedCalls[0]["function"] == nil)
        let translatedFunction = translatedCalls[0]["function_call"] as? [String: Any]
        precondition(translatedFunction?["name"] as? String == "echo_probe")
        precondition(translatedFunction?["arguments"] as? String == "{\"text\":\"OK\"}")
        precondition((assistant[0]["content"] as? [[String: Any]])?.first?["text"] as? String == "普通文本")
        precondition(assistant[1]["role"] as? String == "tool")
        // 纯文本 assistant 不受影响。
        let plain = traeMessages([["role": "assistant", "content": "hi"]])
        precondition(plain[0]["tool_calls"] == nil)
        precondition((plain[0]["content"] as? [[String: Any]])?.first?["text"] as? String == "hi")

        var translator = TraeStreamTranslator(model: "glm-5.2")
        var output = Data()
        // 真实投递形状：URLSession.bytes.lines 不产出空行（旧实现按空行收口，正文全空）。
        let lines = [
            "id:1",
            "event:metadata", "data:{\"model\":\"\",\"session_id\":\"s\"}",
            "event:output", "data:{\"response\":\"你\",\"reasoning_content\":\"hmm\"}",
            "event:output", "data:{\"response\":\"好\"}",
            "event:output", "data:{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\","
                + "\"function_call\":{\"name\":\"exec\",\"namespace\":\"x\",\"arguments\":\"{}\"}}]}",
            "event:token_usage", "data:{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7,"
                + "\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":1,\"reasoning_tokens\":3}",
            "event:done", "data:{\"finish_reason\":\"tool_calls\"}",
        ]
        for line in lines {
            if let chunk = translator.consume(line) { output.append(chunk) }
        }
        if let tail = translator.finish() { output.append(tail) }
        let frames = traeTestFrames(output)
        precondition(frames.first?["object"] as? String == "chat.completion.chunk")
        precondition((frames.first?["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
            != nil)
        precondition(traeContents(frames) == "你好")
        precondition(traeDelta(frames, key: "reasoning_content") as? String == "hmm")
        let calls = traeDelta(frames, key: "tool_calls") as? [[String: Any]]
        let function = calls?.first?["function"] as? [String: Any]
        precondition(calls?.first?["function_call"] == nil)
        precondition(function?["name"] as? String == "exec")
        precondition(function?["namespace"] == nil)
        precondition(frames.contains { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "tool_calls" })
        let usage = frames.compactMap { $0["usage"] as? [String: Any] }.first
        let promptDetails = usage?["prompt_tokens_details"] as? [String: Any]
        let completionDetails = usage?["completion_tokens_details"] as? [String: Any]
        precondition(promptDetails?["cached_tokens"] as? Int == 2)
        precondition(promptDetails?["cache_write_tokens"] as? Int == 1)
        precondition(completionDetails?["reasoning_tokens"] as? Int == 3)
        precondition(usage?["cache_read_input_tokens"] as? Int == 2)
        precondition(frames.last?["done"] as? Bool == true)
        precondition(frames.filter { $0["done"] as? Bool == true }.count == 1)
        // 再收尾一次不能重复产出 finish frame 或 [DONE]。
        precondition(translator.finish() == nil)

        // 工具流：id 只发一次、index 稳定、arguments 为增量片段，且 done 的 stop 被规范为 tool_calls。
        var callStream = TraeStreamTranslator(model: "glm-5.2")
        var callOutput = Data()
        for line in ["event:output", "data:{\"tool_calls\":[{\"index\":0,\"id\":\"\",\"type\":\"function\","
                     + "\"function_call\":{\"name\":\"echo_probe\",\"arguments\":\"{\"}}]}",
                     "event:output", "data:{\"tool_calls\":[{\"index\":0,\"function_call\":{\"name\":\"\","
                     + "\"arguments\":\"\\\"text\\\"\"}}]}",
                     "event:output", "data:{\"tool_calls\":[{\"index\":0,\"function_call\":{\"arguments\":\":\\\"OK\\\"}\"}}]}",
                     "event:done", "data:{\"finish_reason\":\"stop\"}"] {
            if let chunk = callStream.consume(line) { callOutput.append(chunk) }
        }
        if let tail = callStream.finish() { callOutput.append(tail) }
        let callFrames = traeTestFrames(callOutput)
        let aggregated = traeAggregateToolCalls(callFrames)
        precondition(aggregated.count == 1)
        precondition(aggregated[0]["name"] as? String == "echo_probe")
        precondition(aggregated[0]["arguments"] as? String == "{\"text\":\"OK\"}")
        precondition(JSONSerialization.isValidJSONObject(["text": "OK"]))
        let decodedArguments = (aggregated[0]["arguments"] as? String)
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        precondition(decodedArguments?["text"] as? String == "OK")
        let callFrameIDs = callFrames.compactMap { frame -> String? in
            guard let calls = (frame["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
                  let list = calls["tool_calls"] as? [[String: Any]] else { return nil }
            return list.first?["id"] as? String
        }
        precondition(callFrameIDs.count == 1)
        precondition(callFrameIDs.first?.hasPrefix("call_") == true)
        precondition(callFrames.contains { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "tool_calls" })
        // 上游明确给出失败原因时不改写。
        var lengthStream = TraeStreamTranslator(model: "glm-5.2")
        var lengthOutput = Data()
        for line in ["event:output", "data:{\"tool_calls\":[{\"index\":0,\"type\":\"function\","
                     + "\"function_call\":{\"name\":\"echo_probe\",\"arguments\":\"{}\"}}]}",
                     "event:done", "data:{\"finish_reason\":\"length\"}"] {
            if let chunk = lengthStream.consume(line) { lengthOutput.append(chunk) }
        }
        if let tail = lengthStream.finish() { lengthOutput.append(tail) }
        let lengthFrames = traeTestFrames(lengthOutput)
        precondition(lengthFrames.contains { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "length" })
        precondition(!lengthFrames.contains { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "tool_calls" })

        // 上游流内错误：只能出现在 error 对象里，绝不混进 content；且只收尾一次。
        var errorStream = TraeStreamTranslator(model: "glm-5.2")
        var errorOutput = Data()
        for line in ["event:output", "data:{\"response\":\"先前的正文\"}",
                     "event:error", "data:{\"code\":2001,\"message\":\"LLMUtilsChat failed: required field Name is not set\"}"] {
            if let chunk = errorStream.consume(line) { errorOutput.append(chunk) }
        }
        if let tail = errorStream.finish() { errorOutput.append(tail) }
        let errorFrames = traeTestFrames(errorOutput)
        precondition(traeContents(errorFrames) == "先前的正文")
        let errorObject = errorFrames.compactMap { $0["error"] as? [String: Any] }.first
        precondition(errorObject?["code"] as? Int == 2001)
        precondition(errorObject?["type"] as? String == "upstream_error")
        precondition((errorObject?["message"] as? String)?.contains("required field Name is not set") == true)
        precondition(errorFrames.filter { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "stop" }.count == 1)
        precondition(errorFrames.filter { $0["done"] as? Bool == true }.count == 1)
        precondition(errorStream.finish() == nil)

        // 多 data 行按 SSE 规则拼接（在 token 边界拆分才可能重组为合法 JSON）；
        // 异常 data 行不产出内容；最后一条未收口的事件由 finish() 补上。
        var fallback = TraeStreamTranslator(model: "glm-5.2")
        var fallbackOutput = Data()
        for line in ["event:output", "data:{\"response\":\"A\"}",
                     "event:bogus", "data:not json",
                     "event:output", "data:{\"response\":", "data:\"x\"}",
                     "event:output", "data:{\"response\":\"B\"}"] {
            if let chunk = fallback.consume(line) { fallbackOutput.append(chunk) }
        }
        if let tail = fallback.finish() { fallbackOutput.append(tail) }
        let fallbackFrames = traeTestFrames(fallbackOutput)
        precondition(traeContents(fallbackFrames) == "AxB")
        precondition(fallbackFrames.contains { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "stop" })
        precondition(fallbackFrames.filter { $0["done"] as? Bool == true }.count == 1)
    }
}

// 模拟下游客户端：按 index 聚合 tool_calls 增量，还原 name 与 arguments。
func traeAggregateToolCalls(_ frames: [[String: Any]]) -> [[String: Any]] {
    var order: [Int] = []
    var merged: [Int: [String: Any]] = [:]
    for frame in frames {
        guard let delta = (frame["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
              let calls = delta["tool_calls"] as? [[String: Any]] else { continue }
        for call in calls {
            let index = (call["index"] as? NSNumber)?.intValue ?? 0
            if merged[index] == nil {
                merged[index] = ["id": "", "name": "", "arguments": ""]
                order.append(index)
            }
            if let id = call["id"] as? String, !id.isEmpty { merged[index]?["id"] = id }
            guard let function = call["function"] as? [String: Any] else { continue }
            if let name = function["name"] as? String, merged[index]?["name"] as? String == "" {
                merged[index]?["name"] = name
            }
            if let arguments = function["arguments"] as? String {
                let previous = merged[index]?["arguments"] as? String ?? ""
                merged[index]?["arguments"] = previous + arguments
            }
        }
    }
    return order.compactMap { merged[$0] }
}

// 汇总所有 content 增量，用于断言「正文能否拼出来」。
private func traeContents(_ frames: [[String: Any]]) -> String {
    frames.compactMap { ($0["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] }
        .compactMap { $0["content"] as? String }
        .joined()
}

private func traeDelta(_ frames: [[String: Any]], key: String) -> Any? {
    for frame in frames {
        guard let delta = (frame["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
              let value = delta[key] else { continue }
        return value
    }
    return nil
}

private func traeTestFrames(_ data: Data) -> [[String: Any]] {
    var frames: [[String: Any]] = []
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        guard line.hasPrefix("data: ") else { continue }
        let payload = line.dropFirst(6)
        if payload == "[DONE]" { frames.append(["done": true]); continue }
        if let value = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
            frames.append(value)
        }
    }
    return frames
}

func traeUpstreamMessage(_ data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let message = root["message"] ?? root["msg"] ?? (root["error"] as? [String: Any])?["message"]
    guard let message = message as? String, !message.isEmpty else { return nil }
    // 上游错误体可能回显请求头，裁掉以免把凭证带进日志/响应。
    return String(message.prefix(500))
}
