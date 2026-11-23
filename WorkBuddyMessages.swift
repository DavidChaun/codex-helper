import Foundation

enum WorkBuddyMessages {
    // Desktop 3P recognizes the Claude family ID in this namespaced local route.
    static let desktopModelFamily = "claude-sonnet-4-6"
    static let desktopDeepSeekAlias = "workbuddy/\(desktopModelFamily)"

    static func chatBody(_ source: [String: Any]) throws -> [String: Any] {
        guard let model = source["model"] as? String, !model.isEmpty,
              let turns = source["messages"] as? [[String: Any]], !turns.isEmpty,
              let maxTokens = source["max_tokens"] as? Int, maxTokens >= 0 else {
            throw WorkBuddyError.message("Expected model, messages and max_tokens")
        }
        var messages: [[String: Any]] = []
        let systemParts = (source["system"] as? [[String: Any]] ?? []).compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }
        let system = (source["system"] as? String ?? systemParts.joined(separator: "\n\n"))
            .replacingOccurrences(of: #"^x-anthropic-billing-header:[^\r\n]*[\r\n]*"#, with: "", options: .regularExpression)
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for turn in turns {
            guard let role = turn["role"] as? String, role == "user" || role == "assistant" else {
                throw WorkBuddyError.message("Expected user or assistant message")
            }
            if let text = turn["content"] as? String {
                messages.append(["role": role, "content": text])
                continue
            }
            guard let blocks = turn["content"] as? [[String: Any]] else {
                throw WorkBuddyError.message("Expected message content")
            }
            var parts: [[String: Any]] = []
            var calls: [[String: Any]] = []
            var thinking: [String] = []
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use" where role == "assistant":
                    guard let id = block["id"] as? String, let name = block["name"] as? String,
                          let input = block["input"] as? [String: Any] else {
                        throw WorkBuddyError.message("Invalid tool_use block")
                    }
                    let arguments = String(decoding: try workBuddyJSONData(input), as: UTF8.self)
                    calls.append(["id": id, "type": "function", "function": ["name": name, "arguments": arguments]])
                case "tool_result" where role == "user":
                    guard let id = block["tool_use_id"] as? String else {
                        throw WorkBuddyError.message("Missing tool_use_id")
                    }
                    var result = block["content"] as? String ?? ""
                    if let blocks = block["content"] as? [[String: Any]] {
                        let resultParts = try blocks.map(chatContentPart)
                        result = resultParts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        parts += resultParts.filter { $0["type"] as? String == "image_url" }
                    }
                    if block["is_error"] as? Bool == true { result = "Tool error: " + result }
                    messages.append(["role": "tool", "tool_call_id": id, "content": result])
                case "thinking" where role == "assistant":
                    if let text = block["thinking"] as? String { thinking.append(text) }
                case "redacted_thinking" where role == "assistant":
                    continue // Opaque Anthropic thinking cannot be replayed on the Chat wire.
                default:
                    parts.append(try chatContentPart(block))
                }
            }
            let text = parts.compactMap { $0["text"] as? String }.joined()
            let content: Any = parts.contains { $0["type"] as? String == "image_url" } ? parts : text
            var message: [String: Any] = ["role": role, "content": content]
            if !calls.isEmpty { message["tool_calls"] = calls }
            if !thinking.isEmpty { message["reasoning_content"] = thinking.joined(separator: "\n") }
            if !parts.isEmpty || !calls.isEmpty || !thinking.isEmpty { messages.append(message) }
        }
        let upstreamModel = model == desktopDeepSeekAlias ? "deepseek-v4.1-flash" : model
        var body: [String: Any] = ["model": upstreamModel, "messages": messages, "max_tokens": maxTokens,
                                   "stream": source["stream"] as? Bool == true, "stream_options": ["include_usage": true]]
        for key in ["temperature", "top_p", "top_k"] { body[key] = source[key] }
        if let stop = source["stop_sequences"] as? [String], !stop.isEmpty { body["stop"] = stop }
        var functions = try (source["tools"] as? [[String: Any]] ?? []).map { tool -> [String: Any] in
            let type = tool["type"] as? String ?? "custom"
            guard type == "custom", let name = tool["name"] as? String,
                  let schema = tool["input_schema"] as? [String: Any] else {
                throw WorkBuddyError.message("Unsupported Messages tool: \(type). Use a client tool with input_schema.")
            }
            var function: [String: Any] = ["name": name, "parameters": schema]
            function["description"] = tool["description"]
            function["strict"] = tool["strict"]
            return function
        }
        if let choice = source["tool_choice"] as? [String: Any] {
            switch choice["type"] as? String {
            case "auto": body["tool_choice"] = "auto"
            case "none": body["tool_choice"] = "none"
            case "any": body["tool_choice"] = "required"
            case "tool":
                guard let name = choice["name"] as? String,
                      let function = functions.first(where: { $0["name"] as? String == name }) else {
                    throw WorkBuddyError.message("tool_choice must name a declared tool")
                }
                // WorkBuddy accepts string choices only. A single required tool preserves the selection.
                functions = [function]
                body["tool_choice"] = "required"
            default: throw WorkBuddyError.message("Unsupported tool_choice")
            }
            if choice["disable_parallel_tool_use"] as? Bool == true { body["parallel_tool_calls"] = false }
        }
        if !functions.isEmpty { body["tools"] = functions.map { ["type": "function", "function": $0] } }
        let thinking = source["thinking"] as? [String: Any]
        let output = source["output_config"] as? [String: Any]
        if thinking?["type"] as? String == "disabled" {
            body["reasoning_effort"] = "none"
        } else if let effort = output?["effort"] as? String,
                  ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(effort) {
            body["reasoning_effort"] = effort == "ultra" ? "max" : effort
        } else if thinking?["type"] as? String == "enabled", let budget = thinking?["budget_tokens"] as? Int {
            body["reasoning_effort"] = budget <= 4096 ? "low" : (budget <= 16384 ? "medium" : "high")
        }
        return body
    }

    private static func chatContentPart(_ block: [String: Any]) throws -> [String: Any] {
        switch block["type"] as? String {
        case "text":
            if let text = block["text"] as? String { return ["type": "text", "text": text] }
        case "image":
            if let source = block["source"] as? [String: Any] {
                if source["type"] as? String == "base64", let data = source["data"] as? String,
                   let mediaType = source["media_type"] as? String {
                    return ["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(data)"]]
                }
                if source["type"] as? String == "url", let url = source["url"] as? String {
                    return ["type": "image_url", "image_url": ["url": url]]
                }
            }
        default: break
        }
        throw WorkBuddyError.message("Unsupported or invalid Messages content: \(block["type"] as? String ?? "unknown")")
    }

    static func error(_ message: String, type: String = "api_error") -> [String: Any] {
        ["type": "error", "error": ["type": type, "message": message]]
    }

    static func event(_ type: String, _ fields: [String: Any] = [:]) -> Data {
        var value = fields
        value["type"] = type
        let json = String(decoding: (try? workBuddyJSONData(value)) ?? Data("{}".utf8), as: UTF8.self)
        return Data("event: \(type)\ndata: \(json)\n\n".utf8)
    }
}

// Both Anthropic outputs use the same Chat-to-Messages block conversion. Text and thinking
// stream immediately. Parallel Chat tool arguments are folded by index before emitting blocks.
final class WorkBuddyMessagesResponse {
    private struct ToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private let model: String
    private let emit: ((Data) -> Void)?
    private let id = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var pending = Data()
    private var content: [[String: Any]] = []
    private var blockType: String?
    private var index = 0
    private var calls: [Int: ToolCall] = [:]
    private var usage = ["input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]
    private var started = false
    private var sawChoice = false
    private var sawDone = false
    private var finishReason: String?
    private var stopSequence: String?
    private var error: WorkBuddyError?

    init(model: String, emit: ((Data) -> Void)? = nil) {
        self.model = model
        self.emit = emit
    }

    func consume(_ data: Data) {
        guard error == nil, !sawDone else { return }
        pending.append(data)
        while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            guard line.hasPrefix("data:") else { continue }
            consumePayload(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
            if error != nil || sawDone { return }
        }
    }

    private func consumePayload(_ payload: String) {
        guard !payload.isEmpty else { return }
        if payload == "[DONE]" { sawDone = true; return }
        guard let frame = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            error = .message("Invalid WorkBuddy stream")
            return
        }
        if let failure = frame["error"] as? [String: Any] {
            error = .message(failure["message"] as? String ?? "WorkBuddy stream failed")
            return
        }
        if let tokens = frame["usage"] as? [String: Any] {
            let details = tokens["prompt_tokens_details"] as? [String: Any]
            let cached = max(0, details?["cached_tokens"] as? Int ?? 0)
            let written = max(0, details?["cache_write_tokens"] as? Int ?? 0)
            let input = max(0, tokens["prompt_tokens"] as? Int ?? 0)
            usage = ["input_tokens": max(0, max(0, input - cached) - written), "output_tokens": tokens["completion_tokens"] as? Int ?? 0,
                     "cache_read_input_tokens": cached, "cache_creation_input_tokens": written]
        }
        guard let choice = (frame["choices"] as? [[String: Any]])?.first else { return }
        sawChoice = true
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty { finishReason = reason }
        if let sequence = choice["stop_sequence"] as? String { stopSequence = sequence }
        if finishReason == "error" {
            error = .message((choice["error"] as? [String: Any])?["message"] as? String ?? "WorkBuddy stream failed")
            return
        }
        guard let delta = choice["delta"] as? [String: Any] else { return }
        if let text = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !text.isEmpty {
            append(text, block: "thinking", field: "thinking")
        }
        if let text = (delta["content"] as? String) ?? (delta["refusal"] as? String), !text.isEmpty {
            append(text, block: "text", field: "text")
        }
        for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let position = call["index"] as? Int ?? 0
            var tool = calls[position] ?? ToolCall()
            let function = call["function"] as? [String: Any]
            if let id = call["id"] as? String, !id.isEmpty { tool.id = id }
            if let name = function?["name"] as? String, !name.isEmpty { tool.name = name }
            tool.arguments += function?["arguments"] as? String ?? ""
            calls[position] = tool
        }
    }

    private func send(_ type: String, _ fields: [String: Any] = [:]) {
        if let emit { emit(WorkBuddyMessages.event(type, fields)) }
    }

    private func message(stop: Any) -> [String: Any] {
        ["id": id, "type": "message", "role": "assistant", "model": model, "content": content,
         "stop_reason": stop, "stop_sequence": stopSequence as Any? ?? NSNull(), "usage": usage]
    }

    private func start() {
        guard !started else { return }
        started = true
        if emit != nil {
            var initial = message(stop: NSNull())
            var initialUsage = usage
            initialUsage["output_tokens"] = 0
            initial["stop_sequence"] = NSNull()
            initial["usage"] = initialUsage
            send("message_start", ["message": initial])
        }
    }

    private func append(_ text: String, block: String, field: String) {
        if blockType != block {
            closeBlock()
            start()
            var initial = ["type": block, field: ""]
            if block == "thinking" { initial["signature"] = "" }
            if emit == nil { content.append(initial) }
            send("content_block_start", ["index": index, "content_block": initial])
            blockType = block
        }
        if emit == nil { content[index][field] = (content[index][field] as? String ?? "") + text }
        send("content_block_delta", ["index": index, "delta": ["type": field + "_delta", field: text]])
    }

    private func closeBlock() {
        guard blockType != nil else { return }
        send("content_block_stop", ["index": index])
        blockType = nil
        index += 1
    }

    func finish() throws -> [String: Any] {
        if !pending.isEmpty { consume(Data([10])) }
        if let error { throw error }
        guard sawChoice, sawDone || finishReason != nil else { throw WorkBuddyError.message("Incomplete WorkBuddy stream") }
        start()
        closeBlock()
        for position in calls.keys.sorted() {
            guard let tool = calls[position], !tool.id.isEmpty, !tool.name.isEmpty else {
                throw WorkBuddyError.message("Incomplete WorkBuddy tool call")
            }
            let arguments = tool.arguments.isEmpty ? "{}" : tool.arguments
            guard let input = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else {
                throw WorkBuddyError.message("Invalid WorkBuddy tool arguments")
            }
            var block: [String: Any] = ["type": "tool_use", "id": tool.id, "name": tool.name, "input": [:]]
            send("content_block_start", ["index": index, "content_block": block])
            send("content_block_delta", ["index": index, "delta": ["type": "input_json_delta", "partial_json": arguments]])
            send("content_block_stop", ["index": index])
            index += 1
            if emit == nil { block["input"] = input; content.append(block) }
        }
        let stop: String
        switch finishReason {
        case "length": stop = "max_tokens"
        case "content_filter": stop = "refusal"
        case "tool_calls": stop = "tool_use"
        case "stop_sequence": stop = "stop_sequence"
        default: stop = !calls.isEmpty ? "tool_use" : (stopSequence == nil ? "end_turn" : "stop_sequence")
        }
        send("message_delta", ["delta": ["stop_reason": stop, "stop_sequence": stopSequence as Any? ?? NSNull()], "usage": usage])
        send("message_stop")
        return message(stop: stop)
    }
}

extension WorkBuddyMessages {
    static func selfTest() {
        let sample = #"""
        {"model":"test","max_tokens":256,"system":[{"type":"text","text":"x-anthropic-billing-header: cc_version=test;"},
            {"type":"text","text":"system prompt"}],
         "output_config":{"effort":"max"},"tools":[{"name":"other","input_schema":{"type":"object"}},
            {"name":"echo","input_schema":{"type":"object"}}],
         "tool_choice":{"type":"tool","name":"echo","disable_parallel_tool_use":true},"messages":[
            {"role":"user","content":"run echo"},
            {"role":"assistant","content":[{"type":"thinking","thinking":"plan","signature":""},
             {"type":"tool_use","id":"call_1","name":"echo","input":{"text":"hi"}}]},
            {"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"hi"},
             {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]}
        ]}
        """#
        let input = try! JSONSerialization.jsonObject(with: Data(sample.utf8)) as! [String: Any]
        let body = try! chatBody(input)
        precondition(body["model"] as? String == "test")
        var desktopInput = input
        desktopInput["model"] = desktopDeepSeekAlias
        precondition((try! chatBody(desktopInput))["model"] as? String == "deepseek-v4.1-flash")
        let turns = body["messages"] as! [[String: Any]]
        precondition(turns.compactMap { $0["role"] as? String } == ["system", "user", "assistant", "tool", "user"])
        precondition(turns[0]["content"] as? String == "system prompt")
        precondition(turns[2]["reasoning_content"] as? String == "plan" && turns[3]["tool_call_id"] as? String == "call_1")
        precondition(body["reasoning_effort"] as? String == "max" && body["parallel_tool_calls"] as? Bool == false)
        let tools = body["tools"] as! [[String: Any]]
        precondition(tools.count == 1 && (tools[0]["function"] as? [String: Any])?["name"] as? String == "echo")
        precondition(body["tool_choice"] as? String == "required")

        let frames = [
            #"data: {"choices":[{"delta":{"reasoning_content":"plan"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"你好","tool_calls":[{"index":0,"id":"call_1","function":{"name":"echo","arguments":"{"}},{"index":1,"id":"call_2","function":{"name":"echo","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"text\":\"hi\"}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":2}}}"#,
            "data: [DONE]",
        ]
        let collector = WorkBuddyMessagesResponse(model: "test")
        var events: [String] = []
        let stream = WorkBuddyMessagesResponse(model: "test") { events.append(String(decoding: $0, as: UTF8.self)) }
        for (index, line) in frames.enumerated() {
            let bytes = Data((line + "\r\n\r\n").utf8)
            for byte in bytes {
                collector.consume(Data([byte]))
                stream.consume(Data([byte]))
            }
            if index == 1 { precondition(events.contains { $0.contains("你好") }) }
        }
        let message = try! collector.finish()
        _ = try! stream.finish()
        let blocks = message["content"] as! [[String: Any]]
        precondition(blocks.compactMap { $0["type"] as? String } == ["thinking", "text", "tool_use", "tool_use"])
        precondition((blocks[2]["input"] as? [String: String])?["text"] == "hi" && blocks[3]["id"] as? String == "call_2")
        precondition(message["stop_reason"] as? String == "tool_use" && (message["usage"] as? [String: Int])?["input_tokens"] == 5)
        precondition(events.first?.hasPrefix("event: message_start\n") == true && events.last?.hasPrefix("event: message_stop\n") == true)
        precondition(events.filter { $0.contains("input_json_delta") }.count == 2)
        let truncated = WorkBuddyMessagesResponse(model: "test")
        truncated.consume(Data((frames[0] + "\n").utf8))
        precondition((try? truncated.finish()) == nil)
    }
}
