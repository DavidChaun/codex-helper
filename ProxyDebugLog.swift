import Foundation

final class ProxyDebugLog {
    static let failureNotification = Notification.Name("ProxyDebugLogFailure")
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "local.codex-helper.debug-log", qos: .utility)
    private static var active = false
    static var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return active }
        set { lock.lock(); active = newValue; lock.unlock() }
    }
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/CodexHelper-Debug")
    }

    let id: String
    private let file: URL
    private let started = ProcessInfo.processInfo.systemUptime
    private var firstChunk: Double?
    private var bytes = 0
    private var pending = ""
    private var failed = false

    private init(file: URL, id: String = UUID().uuidString.lowercased()) { self.file = file; self.id = id }

    static func begin(provider: String, body: [String: Any], callerID: String?) -> ProxyDebugLog? {
        guard enabled else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let id = UUID().uuidString.lowercased()
        let name = formatter.string(from: Date()) + "_" + id + ".txt"
        let file = directory.appendingPathComponent(component(provider))
            .appendingPathComponent(component(body["model"] as? String ?? "unknown")).appendingPathComponent(name)
        let log = ProxyDebugLog(file: file, id: id)
        log.record("request", ["local_request_id": log.id, "caller_request_id": callerID ?? "not supplied",
                               "timestamp": ISO8601DateFormatter().string(from: Date()),
                               "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                               "provider": provider, "body": body,
                               "note": "Helper 接收的请求；不是 OpenCodex 转换前的 Claude 原始请求。鉴权头不记录，二进制内容省略。"])
        return log
    }

    private static func component(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        let safe = String(String.UnicodeScalarView(value.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return safe.isEmpty ? "unknown" : String(safe.prefix(100))
    }

    private static func sanitized(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, value) in object {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if ["authorization", "cookie", "setcookie", "apikey", "xapikey", "accesstoken", "refreshtoken", "idtoken", "token", "password", "secret"].contains(normalized) {
                    output[key] = "[REDACTED]"
                } else if ["filedata", "b64json"].contains(normalized) ||
                            (key == "data" && (object["type"] as? String == "base64" || object["format"] != nil || object["media_type"] != nil)) {
                    output[key] = "[binary omitted; encoded length: \((value as? String)?.utf8.count ?? 0)]"
                } else { output[key] = sanitized(value) }
            }
            return output
        }
        if let array = value as? [Any] { return array.map(sanitized) }
        if let text = value as? String {
            return text.replacingOccurrences(of: #"(?i)data:[^\s;,]+;base64,[a-z0-9+/=\r\n]+"#,
                                             with: "[binary data URL omitted]", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)Bearer\s+[a-z0-9._~+/=-]+"#,
                                      with: "Bearer [REDACTED]", options: .regularExpression)
        }
        return value
    }

    func record(_ section: String, _ value: Any) {
        Self.queue.async { self.write(section, value) }
    }

    func upstream(status: Int, errorBody: Data? = nil) {
        var value: [String: Any] = ["status": status]
        if let errorBody {
            if let json = try? JSONSerialization.jsonObject(with: errorBody, options: [.fragmentsAllowed]) {
                value["error_body"] = json
            } else {
                value["error_body"] = String(decoding: errorBody.prefix(65_536), as: UTF8.self)
                value["truncated"] = errorBody.count > 65_536
            }
        }
        record("upstream response", value)
    }

    func observe(_ data: Data) {
        let receivedAt = elapsed
        Self.queue.async {
            guard Self.enabled else { return }
            if self.firstChunk == nil { self.firstChunk = receivedAt }
            self.bytes += data.count
            self.pending += String(decoding: data, as: UTF8.self)
            while let end = self.pending.firstIndex(of: "\n") {
                let line = String(self.pending[..<end])
                self.pending.removeSubrange(...end)
                guard line.hasPrefix("data:"),
                      let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { continue }
                if let error = json["error"] { self.write("stream error", error) }
            }
            // shortcut: 只解析 64 KiB 以内的 SSE 行；需要诊断超大事件时再增加解析能力。
            if self.pending.utf8.count > 65_536 { self.pending = "" }
        }
    }

    private var elapsed: Double { (ProcessInfo.processInfo.systemUptime - started) * 1000 }

    func finish(_ error: Error?) {
        let duration = elapsed
        Self.queue.async {
            self.write("completion", ["duration_ms": duration, "first_chunk_ms": self.firstChunk as Any? ?? NSNull(),
                                      "response_bytes": self.bytes, "error": error?.localizedDescription as Any? ?? NSNull(),
                                      "note": "流式输出仅保存错误和统计，不保存完整回答；无传输错误不代表上游业务成功。"])
        }
    }

    private func write(_ section: String, _ value: Any) {
        guard Self.enabled, !failed else { return }
        do {
            let manager = FileManager.default
            var directories: [URL] = []
            var parent = file.deletingLastPathComponent()
            while !manager.fileExists(atPath: parent.path) {
                directories.insert(parent, at: 0)
                parent.deleteLastPathComponent()
            }
            for directory in directories {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            if !manager.fileExists(atPath: file.path) {
                guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let json = try JSONSerialization.data(withJSONObject: Self.sanitized(value), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(("\n=== " + section + " ===\n").utf8) + json + Data("\n".utf8))
        } catch {
            failed = true
            Self.enabled = false
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.failureNotification, object: nil,
                                                userInfo: ["error": "Debug 日志写入失败，已停止记录：\(error.localizedDescription)"])
            }
        }
    }

    static func selfTest() throws {
        precondition(!enabled && begin(provider: "test", body: [:], callerID: nil) == nil)
        precondition(component("../../test/model") == "_.._test_model")
        let redacted = sanitized(["access_token": "secret", "body": "hello", "image_url": "data:image/png;base64,YWJj"]) as! [String: String]
        precondition(redacted["access_token"] == "[REDACTED]" && redacted["body"] == "hello")
        precondition(redacted["image_url"] == "[binary data URL omitted]")
        let media = sanitized(["type": "base64", "data": "YWJj"]) as! [String: String]
        precondition(media["data"]?.contains("omitted") == true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("test.txt")
        defer { enabled = false; try? FileManager.default.removeItem(at: root) }
        enabled = true
        let log = ProxyDebugLog(file: file)
        log.record("received", ["messages": [["role": "user", "content": "测试 prompt"]], "Authorization": "secret"])
        log.upstream(status: 500, errorBody: Data("{\"error\":{\"message\":\"test failure\"}}".utf8))
        log.observe(Data("data: {\"error\":{\"message\":\"stream failure\"}}\n".utf8))
        log.finish(nil)
        queue.sync {}
        let text = try String(contentsOf: file, encoding: .utf8)
        precondition(text.contains("测试 prompt") && text.contains("test failure") && text.contains("stream failure") && !text.contains("secret"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        precondition(directoryPermissions?.intValue == 0o700)
        enabled = false
        log.record("disabled", ["content": "not recorded"])
        queue.sync {}
        let afterDisable = try String(contentsOf: file, encoding: .utf8)
        precondition(afterDisable == text)
        enabled = true
        let blocked = ProxyDebugLog(file: file.appendingPathComponent("cannot-write.txt"))
        blocked.record("failure test", [:])
        queue.sync {}
        precondition(!enabled)
    }
}
