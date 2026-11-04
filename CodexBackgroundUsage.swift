import Foundation

struct CodexBackgroundUsageSnapshot {
    let records: [CodexUsageRecord]
    let unreadable: Int
    let skipped: Int
    let warnings: [String]
}

extension CodexBackgroundUsageReader {
    static func selfTest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache/v1.json")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("desktop.log")
        func line(_ second: Int, feature: String, tier: String = "null", model: String = "gpt-6-luna", extra: String = "") -> String {
            "2026-11-01T01:00:\(String(format: "%02d", second)).000Z info [ephemeral-generation] ephemeral_generation_token_usage event=ephemeral_generation_token_usage feature=\(feature) model=\(model) serviceTier=\(tier) inputTokens=100 cachedInputTokens=50 outputTokens=10 reasoningOutputTokens=3 totalTokens=110 \(extra)\n"
        }
        let original = line(1, feature: "thread_title", extra: "prompt=\"PRIVATE_DO_NOT_SYNC\"")
            + line(2, feature: "thread_description", tier: "default", extra: "cacheWriteInputTokens=0")
            + line(3, feature: "ambient_suggestions") + line(4, feature: "ambient_suggestion_safety")
            + line(5, feature: "memory_extraction") + line(6, feature: "future_unknown_feature", extra: "status=error")
        try Data(original.utf8).write(to: file)
        let reader = CodexBackgroundUsageReader(logRoot: logs, cache: cache)
        let first = reader.read()
        precondition(first.records.count == 6 && first.skipped == 0 && first.unreadable == 0)
        precondition(first.records.first { $0.source == "desktop:thread_title" }?.amounts.cacheWrite == nil)
        precondition(first.records.reduce(0) { $0 + $1.amounts.total } == 660)
        precondition(reader.read().records.count == 6)
        try Data(original.utf8).write(to: logs.appendingPathComponent("copied.log"))
        precondition(reader.read().records.count == 6, "Copied desktop logs must not be charged twice")
        let staleLogs = root.appendingPathComponent("stale-logs")
        try FileManager.default.createDirectory(at: staleLogs, withIntermediateDirectories: true)
        let stale = CodexBackgroundUsageReader(logRoot: staleLogs, cache: cache)
        precondition(stale.read().records.count == 6)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let extra = Data(line(7, feature: "thread_title").utf8)
        try handle.write(contentsOf: extra.dropLast(3))
        precondition(reader.read().records.count == 6)
        try handle.write(contentsOf: extra.suffix(3)); try handle.close()
        precondition(reader.read().records.count == 7)
        try Data(line(8, feature: "thread_title").utf8).write(to: staleLogs.appendingPathComponent("next.log"))
        precondition(stale.read().records.count == 8, "A stale writer must merge newer cached usage")
        try FileManager.default.removeItem(at: logs)
        let retained = CodexBackgroundUsageReader(logRoot: logs, cache: cache).read()
        precondition(retained.records.count == 8, "Log rotation must not delete captured background usage")
        let exported = try String(contentsOf: cache, encoding: .utf8)
        precondition(!exported.contains("PRIVATE_DO_NOT_SYNC"))
        let missingSessions = root.appendingPathComponent("no-sessions")
        let now = ISO8601DateFormatter().date(from: "2026-11-01T08:00:00Z")!
        let snapshot = try CodexTokenUsageReader(root: missingSessions, backgroundLogs: staleLogs).read(now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let total = try snapshot.periods[0].total.total
        precondition(total == 110 && snapshot.periods[0].estimatedUSD == 0)
        let parser = CodexBackgroundUsageReader(logRoot: logs)
        let bad = line(9, feature: "thread_title").replacingOccurrences(of: "inputTokens=100", with: "inputTokens=-1")
        do { _ = try parser.parse(Data(bad.utf8)); preconditionFailure("Reject malformed numeric usage") }
        catch is CocoaError {}
        let free = try parser.parse(Data(line(10, feature: "background", model: "codex-auto-review").utf8))
        precondition(free == nil)
        let spoof = "2026-11-01T01:00:11Z info [renderer] message=" + line(11, feature: "thread_title")
        let ignored = try parser.parse(Data(spoof.utf8))
        precondition(ignored == nil)
        let other = try parser.parse(Data(line(12, feature: "\"unrecognized purpose\"", model: "null").utf8))
        precondition(other?.source == "desktop:other" && other?.model == "未记录模型" && other?.amounts.total == 110)
        let brokenParent = root.appendingPathComponent("blocked")
        try Data().write(to: brokenParent)
        let retry = CodexBackgroundUsageReader(logRoot: staleLogs, cache: brokenParent.appendingPathComponent("v1.json"))
        precondition(!retry.read().warnings.isEmpty)
        try FileManager.default.removeItem(at: brokenParent)
        precondition(retry.read().warnings.isEmpty && FileManager.default.fileExists(atPath: brokenParent.appendingPathComponent("v1.json").path), "Retry a failed cache write without needing new events")
        let chunkLogs = root.appendingPathComponent("chunk-logs")
        try FileManager.default.createDirectory(at: chunkLogs, withIntermediateDirectories: true)
        var chunks = Data(repeating: 65, count: 1_048_560)
        chunks.append(10)
        chunks.append(Data(line(13, feature: "cross_chunk").utf8))
        chunks.append(Data(String(repeating: "debug\n", count: 10000).utf8))
        chunks.append(Data(repeating: 65, count: 5 * 1024 * 1024))
        chunks.append(10)
        chunks.append(Data(line(14, feature: "after_long_line").utf8))
        try chunks.write(to: chunkLogs.appendingPathComponent("chunks.log"))
        let chunked = CodexBackgroundUsageReader(logRoot: chunkLogs).read()
        precondition(chunked.records.count == 2 && chunked.skipped == 0 && chunked.unreadable == 0,
                     "Read chunk-spanning events and resume after overlong unrelated lines")
        let sessions = root.appendingPathComponent("native-codex/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let nativeFile = sessions.appendingPathComponent("native.jsonl")
        var nativeData = Data()
        func append(_ type: String, _ payload: [String: Any], at: String) throws {
            nativeData.append(try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": at, "payload": payload]))
            nativeData.append(10)
        }
        let usage = ["input_tokens": 100, "cached_input_tokens": 0, "cache_write_input_tokens": 0, "output_tokens": 10, "reasoning_output_tokens": 0]
        try append("turn_context", ["model": "gpt-6.1-sol"], at: "2026-11-01T02:00:00Z")
        try append("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": "default"]], at: "2026-11-01T02:00:00Z")
        try append("token_usage_record", ["usage": usage, "response_id": "PRIVATE_RESPONSE_ID"], at: "2026-11-01T02:00:00Z")
        try nativeData.write(to: nativeFile)
        let drive = root.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let sync = CodexUsageSync(cloud: drive.appendingPathComponent("Helper/Usage/v1"), cache: root.appendingPathComponent("native-cache"), deviceID: UUID().uuidString, deviceName: "Native")
        let nativeReader = CodexTokenUsageReader(root: sessions.deletingLastPathComponent())
        let nativeOnly = try nativeReader.read(now: now, timeZone: TimeZone(secondsFromGMT: 0)!, sync: sync)
        let nativeTokens = try nativeOnly.periods[0].total.total
        precondition(nativeTokens == 110 && nativeOnly.periods[0].estimatedUSD == 0, "Count native-only usage without assuming an undocumented tier")
        try append("event_msg", ["type": "token_count", "info": ["last_token_usage": usage,
            "total_token_usage": ["input_tokens": 100, "output_tokens": 10]]], at: "2026-11-01T02:00:00.100Z")
        try nativeData.write(to: nativeFile)
        let reconciled = try nativeReader.read(now: now.addingTimeInterval(61), timeZone: TimeZone(secondsFromGMT: 0)!, sync: sync)
        let reconciledTokens = try reconciled.periods[0].total.total
        precondition(reconciledTokens == 110 && reconciled.periods[0].estimatedUSD > 0,
                     "A late legacy event must enrich the native request, never duplicate cached usage")
        try append("token_usage_record", ["usage": usage, "response_id": ""], at: "2026-11-01T03:00:00Z")
        try append("token_usage_record", ["usage": usage, "response_id": ""], at: "2026-11-01T03:00:01Z")
        try nativeData.write(to: nativeFile)
        let noIDs = try nativeReader.read(now: now.addingTimeInterval(122), timeZone: TimeZone(secondsFromGMT: 0)!)
        let noIDTokens = try noIDs.periods[0].total.total
        precondition(noIDTokens == 330, "Empty response IDs must not collapse separate requests")
    }
}

final class CodexBackgroundUsageReader {
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/com.openai.codex")
    static let defaultCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Helper/BackgroundUsage/v1.json")
    // shortcut: 元数据缓存最多 64MB；达到上限时改为按日期分片。
    private static let maxBytes = 64 * 1024 * 1024
    private struct State {
        var offset: UInt64 = 0
        var modified: Date?
        var pending = Data()
        var skipped = 0
        var discarding = false
    }
    private struct Cache: Codable {
        let version: Int
        let records: [CodexUsageRecord]
    }
    private let logRoot: URL
    private let cache: URL?
    private var loaded = false
    private var dirty = false
    private var cacheWarning: String?
    private var records: [String: CodexUsageRecord] = [:]
    private var files: [String: State] = [:]
    private let fields = try! NSRegularExpression(pattern: #"(?:^|\s)([A-Za-z][A-Za-z0-9_]*)=("(?:\\.|[^"\\])*"|[^\s]+)"#)
    private let usageMarker = Data(" [ephemeral-generation] ephemeral_generation_token_usage ".utf8)
    private let iso = ISO8601DateFormatter()
    private let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions.insert(.withFractionalSeconds); return value
    }()

    init(logRoot: URL = CodexBackgroundUsageReader.defaultDirectory, cache: URL? = nil) {
        self.logRoot = logRoot
        self.cache = cache
    }

    private func parse(_ data: Data) throws -> CodexUsageRecord? {
        guard data.range(of: usageMarker) != nil else { return nil }
        let line = String(decoding: data, as: UTF8.self)
        guard let prefix = line.range(of: " [ephemeral-generation] ephemeral_generation_token_usage "),
              let space = line.firstIndex(of: " "), space < prefix.lowerBound,
              let date = fractional.date(from: String(line[..<space])) ?? iso.date(from: String(line[..<space])) else { return nil }
        guard ["info", "debug", "trace", "warn", "error"].contains(String(line[line.index(after: space)..<prefix.lowerBound])) else { return nil }
        let body = String(line[prefix.upperBound...])
        var values: [String: String] = [:]
        for match in fields.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            let key = String(body[Range(match.range(at: 1), in: body)!])
            guard ["event", "feature", "model", "serviceTier", "responseId", "inputTokens", "cachedInputTokens",
                   "cacheWriteInputTokens", "outputTokens", "reasoningOutputTokens", "totalTokens"].contains(key) else { continue }
            let raw = String(body[Range(match.range(at: 2), in: body)!])
            guard values[key] == nil else { throw CocoaError(.fileReadCorruptFile) }
            values[key] = raw.hasPrefix("\"") ? try JSONDecoder().decode(String.self, from: Data(raw.utf8)) : raw
        }
        guard values["event"] == nil || values["event"] == "ephemeral_generation_token_usage",
              let input = values["inputTokens"].flatMap(Int64.init), let output = values["outputTokens"].flatMap(Int64.init) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let feature = values["feature"].flatMap { $0.range(of: #"^[A-Za-z0-9_.:/-]{1,100}$"#, options: .regularExpression) == nil ? nil : $0 } ?? "other"
        let model = values["model"].flatMap { $0 == "null" || $0.isEmpty ? nil : $0 } ?? "未记录模型"
        func optional(_ name: String) throws -> Int64? {
            guard let value = values[name], value != "null" else { return nil }
            guard let number = Int64(value) else { throw CocoaError(.fileReadCorruptFile) }
            return number
        }
        let amounts = try CodexTokenAmounts(input: input, cached: optional("cachedInputTokens"),
            cacheWrite: optional("cacheWriteInputTokens"), output: output, reasoning: optional("reasoningOutputTokens"))
        guard amounts.valid else { throw CocoaError(.fileReadCorruptFile) }
        guard amounts.total > 0, model != "codex-auto-review" else { return nil }
        let tier = values["serviceTier"].flatMap { $0 == "null" ? nil : $0 }
        let key = values["responseId"].flatMap { $0 == "null" || $0.isEmpty || $0.utf8.count > 256 ? nil : CodexUsageRecord.digest(Data(("response:" + $0).utf8)) }
        let record = CodexUsageRecord(timestamp: String(line[..<space]), occurredAt: date.timeIntervalSince1970,
            model: model, serviceTier: tier, cumulative: nil, amounts: amounts, requestKey: key, source: "desktop:" + feature)
        guard record.valid else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }

    private func cached(_ url: URL) throws -> [CodexUsageRecord] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
        guard data.count <= Self.maxBytes else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(Cache.self, from: data)
        guard value.version == 1, value.records.allSatisfy({ record in
            guard record.valid, record.source?.hasPrefix("desktop:") == true,
                  record.id == CodexUsageRecord.fingerprint(timestamp: record.timestamp, cumulative: record.cumulative, amounts: record.amounts),
                  let date = fractional.date(from: record.timestamp) ?? iso.date(from: record.timestamp) else { return false }
            return abs(date.timeIntervalSince1970 - record.occurredAt) < 0.001
        }) else { throw CocoaError(.fileReadCorruptFile) }
        return value.records
    }

    func read() -> CodexBackgroundUsageSnapshot {
        let manager = FileManager.default
        var unreadable = 0, warnings = Set(cacheWarning.map { [$0] } ?? [])
        if !loaded {
            loaded = true
            if let cache, manager.fileExists(atPath: cache.path) {
                do {
                    try CodexUsageSync.coordinated(cache, writing: false) { url in
                        for record in try self.cached(url) { self.records[record.id] = record }
                    }
                } catch {
                    unreadable += 1
                    cacheWarning = "后台用量缓存未能读取，将从仍保留的日志重建"
                    warnings.insert(cacheWarning!)
                }
            }
        }
        var live = Set<String>()
        if manager.fileExists(atPath: logRoot.path), let urls = manager.enumerator(at: logRoot,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles],
            errorHandler: { _, _ in unreadable += 1; return true }) {
            for case let url as URL in urls where url.pathExtension == "log" {
                live.insert(url.path)
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = UInt64(values.fileSize ?? 0)
                    var state = files[url.path] ?? State()
                    if state.offset == size, state.modified == values.contentModificationDate { continue }
                    if size < state.offset || (size == state.offset && state.modified != values.contentModificationDate) { state = State() }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: state.offset)
                    while state.offset < size, let chunk = try handle.read(upToCount: Int(min(1_048_576, size - state.offset))), !chunk.isEmpty {
                        state.offset += UInt64(chunk.count); state.pending.append(chunk)
                        var start = state.pending.startIndex
                        while let newline = state.pending[start...].firstIndex(of: 10) {
                            let line = Data(state.pending[start..<newline])
                            start = state.pending.index(after: newline)
                            if state.discarding { state.discarding = false; continue }
                            do {
                                if let record = try parse(line), records[record.id] != record { records[record.id] = record; dirty = true }
                            } catch { state.skipped += 1 }
                        }
                        // 每块只复制剩余半行，避免每处理一行都搬动整个缓冲区。
                        state.pending = state.pending.subdata(in: start..<state.pending.endIndex)
                        // 普通调试日志可能含很长的消息；超过 4MB 的一行不属于此用量事件格式。
                        if state.pending.count > 4 * 1024 * 1024 {
                            if String(decoding: state.pending.prefix(200), as: UTF8.self).contains(" [ephemeral-generation] ephemeral_generation_token_usage ") { state.skipped += 1 }
                            state.pending = Data(); state.discarding = true
                        }
                    }
                    state.pending = Data(state.pending)
                    state.modified = values.contentModificationDate
                    files[url.path] = state
                } catch { unreadable += 1 }
            }
        }
        files = files.filter { live.contains($0.key) }
        if dirty, let cache {
            do {
                try manager.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try CodexUsageSync.coordinated(cache, writing: true) { url in
                    var combined = Array(self.records.values)
                    if manager.fileExists(atPath: url.path) { combined += (try? self.cached(url)) ?? [] }
                    let merged = CodexUsageRecord.merged(combined, warnings: &warnings)
                    let data = try JSONEncoder().encode(Cache(version: 1, records: merged))
                    guard data.count <= Self.maxBytes else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: url, options: .atomic)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    for record in merged { self.records[record.id] = record }
                }
                dirty = false
                cacheWarning = nil
            } catch { warnings.insert("后台用量缓存尚未保存，请保留原始日志后重试") }
        }
        return CodexBackgroundUsageSnapshot(records: Array(records.values), unreadable: unreadable,
            skipped: files.values.reduce(0) { $0 + $1.skipped }, warnings: warnings.sorted())
    }
}
