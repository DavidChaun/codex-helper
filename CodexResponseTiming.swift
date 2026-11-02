import Foundation
import SQLite3

struct CodexResponseSpan {
    let threadID: String
    let turnID: String
    let firstOutput: Date
    let lastOutput: Date
    let previousUsage: Date?
}

final class CodexResponseTimingReader {
    private let root: URL
    private var database: URL?
    private var lastID: Int64 = 0
    private var starts: [String: [Double]] = [:]
    private let turnPattern = try! NSRegularExpression(pattern: #"turn_id=([0-9a-fA-F-]{36})"#)

    init(root: URL) { self.root = root }

    func refresh() {
        guard let url = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.range(of: #"^logs_\d+\.sqlite$"#, options: .regularExpression) != nil })
            .max(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) else { return }
        if url != database { database = url; lastID = 0; starts = [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT id,ts,ts_nanos,thread_id,feedback_log_body FROM logs WHERE id>? AND target='feedback_tags' AND feedback_log_body LIKE '%tags_json=%' ORDER BY id"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, lastID)
        while sqlite3_step(statement) == SQLITE_ROW {
            lastID = sqlite3_column_int64(statement, 0)
            guard let thread = sqlite3_column_text(statement, 3), let body = sqlite3_column_text(statement, 4) else { continue }
            let text = String(cString: body)
            guard let match = turnPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let key = String(cString: thread) + "/" + text[range]
            let time = sqlite3_column_double(statement, 1) + sqlite3_column_double(statement, 2) / 1_000_000_000
            guard time.isFinite else { continue }
            starts[key, default: []].append(time)
        }
        for key in starts.keys { starts[key]!.sort() }
    }

    func seconds(for span: CodexResponseSpan) -> Double? {
        guard let values = starts[span.threadID + "/" + span.turnID] else { return nil }
        let first = span.firstOutput.timeIntervalSince1970
        var low = 0, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] <= first { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let start = values[low - 1]
        let seconds = span.lastOutput.timeIntervalSince1970 - start
        guard span.previousUsage.map({ start > $0.timeIntervalSince1970 }) ?? true,
              first <= span.lastOutput.timeIntervalSince1970, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}

extension CodexResponseTimingReader {
    static func selfTest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        let thread = UUID().uuidString.lowercased(), turn = UUID().uuidString.lowercased()
        var data = Data()
        func line(_ type: String, _ payload: [String: Any], _ time: String) throws {
            data.append(try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": time, "payload": payload]))
            data.append(10)
        }
        try line("turn_context", ["model": "gpt-6.1-sol"], "2026-11-01T00:00:00Z")
        var cumulative = 0
        func response(_ hour: String, output: Int, seconds: Int, fast: Bool = false, toolWait: Bool = false, mismatch: Bool = false) throws {
            let start = "2026-11-01T\(hour):00:00Z"
            let end = "2026-11-01T\(hour):00:\(String(format: "%02d", seconds))Z"
            let reported = toolWait ? "2026-11-01T\(hour):10:04Z" : end
            try line("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": fast ? "fast" : "default"]], start)
            try line("response_item", ["type": toolWait ? "function_call" : "message", "role": "assistant"], end)
            if toolWait { try line("response_item", ["type": "function_call_output", "output": "DO_NOT_EXPORT"], reported) }
            let usage = CodexTokenAmounts(input: 100, cached: 0, cacheWrite: 0, output: Int64(output), reasoning: 10)
            let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)) as! [String: Any]
            try line("token_usage_record", ["thread_id": thread, "turn_id": turn, "usage": obj], reported)
            var last = obj
            if mismatch { last["output_tokens"] = output + 1 }
            cumulative += output
            try line("event_msg", ["type": "token_count", "info": ["last_token_usage": last,
                "total_token_usage": ["input_tokens": cumulative, "output_tokens": cumulative]]], reported)
        }
        try response("01", output: 100, seconds: 4, toolWait: true)
        try response("02", output: 900, seconds: 6)
        try response("03", output: 400, seconds: 2, fast: true)
        try response("04", output: 300, seconds: 1)
        try response("05", output: 200, seconds: 1, mismatch: true)
        let file = sessions.appendingPathComponent("timed.jsonl")
        try data.write(to: file)
        let reader = CodexTokenUsageReader(root: root)
        let now = iso.date(from: "2026-11-01T08:00:00Z")!
        let standard = CodexTokenUsageGroup(model: "gpt-6.1-sol", tier: .standard)
        let fast = CodexTokenUsageGroup(model: "gpt-6.1-sol", tier: .fast)
        let zone = TimeZone(secondsFromGMT: 0)!
        let missing = try reader.read(now: now, timeZone: zone)
        precondition(missing.periods[0].performance[standard]?.average == nil)
        precondition(missing.periods[0].performance[standard]?.label == "tok/s avg: —")
        var db: OpaquePointer?
        precondition(sqlite3_open(root.appendingPathComponent("logs_2.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, thread_id TEXT, target TEXT, feedback_log_body TEXT)", nil, nil, nil) == SQLITE_OK)
        // 不写第 4 条的起始时间；第 5 条用量不匹配，不得误配出测速样本。
        for hour in ["01", "02", "03", "05"] {
            let time = Int(iso.date(from: "2026-11-01T\(hour):00:00Z")!.timeIntervalSince1970)
            let sql = "INSERT INTO logs(ts,ts_nanos,thread_id,target,feedback_log_body) VALUES(\(time),0,'\(thread)','feedback_tags','turn_id=\(turn) tags_json={}')"
            precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        let snapshot = try reader.read(now: now, timeZone: zone)
        let stats = snapshot.periods[0].performance[standard]!
        precondition(stats.samples == 2 && stats.requests == 4 && stats.output == 1000 && stats.seconds == 10)
        precondition(stats.average == 100, "Use weighted throughput and exclude the ten-minute tool wait")
        precondition(snapshot.periods[0].performance[fast]?.average == 200)
        var legacy = Data()
        for bytes in data.split(separator: 10) {
            let row = try JSONSerialization.jsonObject(with: Data(bytes)) as! [String: Any]
            if row["type"] as? String != "token_usage_record", row["type"] as? String != "response_item" {
                legacy.append(contentsOf: bytes); legacy.append(10)
            }
        }
        try legacy.write(to: sessions.appendingPathComponent("copied.jsonl"))
        let copied = try reader.read(now: now, timeZone: zone)
        precondition(copied.periods[0].performance[standard]?.samples == 2)
        precondition(copied.periods[0].performance[standard]?.average == 100)
        var zero = CodexOutputPerformance()
        zero.include(CodexUsageRecord(timestamp: "2026-11-01T01:00:00Z", occurredAt: now.timeIntervalSince1970,
            model: standard.model, serviceTier: "default", cumulative: nil, amounts: CodexTokenAmounts(input: 100), responseSeconds: 1))
        precondition(zero.average == nil && zero.samples == 0 && zero.requests == 1)
    }
}
