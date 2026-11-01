import Foundation

struct CodexTokenAmounts: Decodable, Equatable, Hashable {
    var input: Int64 = 0
    var cached: Int64? = 0
    var cacheWrite: Int64? = 0
    var output: Int64 = 0
    var reasoning: Int64? = 0

    enum CodingKeys: String, CodingKey {
        case input = "input_tokens", cached = "cached_input_tokens"
        case cacheWrite = "cache_write_input_tokens", output = "output_tokens"
        case reasoning = "reasoning_output_tokens"
    }

    var valid: Bool {
        input >= 0 && output >= 0 && input <= Int64.max - output
            && (cached.map { $0 >= 0 && $0 <= input } ?? true)
            && (cacheWrite.map { $0 >= 0 && $0 <= input - (cached ?? 0) } ?? true)
            && (reasoning.map { $0 >= 0 && $0 <= output } ?? true)
    }
    var total: Int64 { input + output }
    var uncached: Int64? {
        guard let cached, let cacheWrite else { return nil }
        return input - cached - cacheWrite
    }
    private func sum(_ a: Int64?, _ b: Int64?) throws -> Int64? {
        guard let a, let b else { return nil }
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw CodexTokenUsageError.overflow }
        return value
    }
    func adding(_ other: Self) throws -> Self {
        let value = try Self(input: sum(input, other.input)!, cached: sum(cached, other.cached),
                             cacheWrite: sum(cacheWrite, other.cacheWrite), output: sum(output, other.output)!,
                             reasoning: sum(reasoning, other.reasoning))
        guard value.valid else { throw CodexTokenUsageError.overflow }
        return value
    }
    var rows: [String] {
        func number(_ value: Int64?) -> String { value.map { $0.formatted(.number) } ?? "未记录" }
        return ["输入合计：\(number(input))", "未缓存输入：\(number(uncached))",
                "缓存命中：\(number(cached))", "缓存写入：\(number(cacheWrite))",
                "输出：\(number(output))", "其中推理：\(number(reasoning))"]
    }
}

struct CodexTokenCosts {
    var uncached: Decimal = 0
    var cached: Decimal = 0
    var cacheWrite: Decimal = 0
    var output: Decimal = 0
    var reasoning: Decimal = 0
    var serviceTiers: Set<String> = []
    var input: Decimal { uncached + cached + cacheWrite }
    var total: Decimal { input + output }

    func adding(_ other: Self) -> Self {
        Self(uncached: uncached + other.uncached, cached: cached + other.cached,
             cacheWrite: cacheWrite + other.cacheWrite, output: output + other.output,
             reasoning: reasoning + other.reasoning, serviceTiers: serviceTiers.union(other.serviceTiers))
    }

    func rows(amounts: CodexTokenAmounts) -> [String] {
        let prices = [input, uncached, cached, cacheWrite, output, reasoning]
        return ["总计：\(amounts.total.formatted(.number)) · \(CodexTokenPricing.dollars(total))"]
            + zip(amounts.rows, prices).map { "\($0.0) · \(CodexTokenPricing.dollars($0.1))" }
            + ["档位：\(serviceTiers.isEmpty ? "未知" : serviceTiers.sorted().joined(separator: " / "))"]
    }
}

enum CodexTokenPricing {
    // USD / 1M tokens，2026-11-01 核对：https://developers.openai.com/api/docs/pricing
    private static let rates: [String: (input: Decimal, cached: Decimal, output: Decimal)] = [
        "gpt-6-astra": (10, 1, 50),
        "gpt-6.1-sol": (2, Decimal(1) / 10, 10),
        "gpt-6.1-terra": (1, Decimal(5) / 100, 5),
        "gpt-6-sol": (2, Decimal(2) / 10, 10),
        "gpt-6-luna": (Decimal(1) / 10, Decimal(1) / 100, Decimal(5) / 10),
        "gpt-5.6-sol": (4, Decimal(4) / 10, 20),
        "gpt-5.6-terra": (2, Decimal(2) / 10, 12),
        "gpt-5.6-luna": (Decimal(2) / 10, Decimal(2) / 100, Decimal(12) / 10)
    ]

    static func estimate(model: String, amounts: CodexTokenAmounts, serviceTier: String? = "default") -> Decimal {
        breakdown(model: model, amounts: amounts, serviceTier: serviceTier).total
    }

    static func breakdown(model: String, amounts: CodexTokenAmounts, serviceTier: String? = "default") -> CodexTokenCosts {
        let multiplier: Decimal
        let label: String
        switch serviceTier {
        case "default", "standard": multiplier = 1; label = "标准"
        case "fast", "priority": multiplier = 2; label = "Fast"
        default: return CodexTokenCosts(serviceTiers: ["未知"])
        }
        guard let rate = rates[model], amounts.valid,
              let uncached = amounts.uncached, let cached = amounts.cached,
              let write = amounts.cacheWrite else { return CodexTokenCosts(serviceTiers: [label]) }
        // shortcut: 用日志中的请求档位和默认 30 分钟缓存估价；实际回退和其他缓存寿命需响应元数据。
        let inputMultiplier: Decimal = (amounts.input > 272_000 ? 2 : 1) * multiplier
        let outputMultiplier: Decimal = (amounts.input > 272_000 ? Decimal(3) / 2 : 1) * multiplier
        return CodexTokenCosts(
            uncached: Decimal(uncached) * rate.input * inputMultiplier / 1_000_000,
            cached: Decimal(cached) * rate.cached * inputMultiplier / 1_000_000,
            cacheWrite: Decimal(write) * rate.input * 5 / 4 * inputMultiplier / 1_000_000,
            output: Decimal(amounts.output) * rate.output * outputMultiplier / 1_000_000,
            reasoning: Decimal(amounts.reasoning ?? 0) * rate.output * outputMultiplier / 1_000_000,
            serviceTiers: [label])
    }

    static func dollars(_ amount: Decimal) -> String {
        var value = amount, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }
}

struct CodexTokenUsagePeriod {
    let name: String
    var models: [String: CodexTokenAmounts] = [:]
    var costs: [String: CodexTokenCosts] = [:]
    var estimatedUSD: Decimal { costs.values.reduce(0) { $0 + $1.total } }
    var total: CodexTokenAmounts {
        get throws { try models.values.reduce(CodexTokenAmounts()) { try $0.adding($1) } }
    }
}

struct CodexTokenUsageSnapshot {
    let periods: [CodexTokenUsagePeriod]
    let updated: Date
    let timeZone: String
    let unreadableFiles: Int
    let skippedEvents: Int
}

enum CodexTokenUsageError: LocalizedError {
    case missingSessions, overflow, invalidRange
    var errorDescription: String? {
        switch self {
        case .missingSessions: return "未找到本地 Codex 会话记录"
        case .overflow: return "Token 记录数值异常，无法汇总"
        case .invalidRange: return "开始日期不能晚于结束日期"
        }
    }
}

final class CodexTokenUsageReader {
    static func dateRange(from start: Date, through end: Date, timeZone: TimeZone = .current) throws -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startDay = calendar.startOfDay(for: start), endDay = calendar.startOfDay(for: end)
        guard startDay <= endDay else { throw CodexTokenUsageError.invalidRange }
        return DateInterval(start: startDay, end: calendar.date(byAdding: .day, value: 1, to: endDay)!)
    }

    private struct Record: Decodable {
        let timestamp: String
        let type: String
        let payload: Payload
        struct Payload: Decodable {
            let type: String?
            let model: String?
            let info: Info?
            let thread_settings: ThreadSettings?
        }
        struct ThreadSettings: Decodable {
            let service_tier: String?
        }
        struct Info: Decodable {
            let total_token_usage: CodexTokenAmounts?
            let last_token_usage: CodexTokenAmounts?
        }
    }
    private struct Identity: Hashable {
        let timestamp: String
        let cumulative: CodexTokenAmounts?
        let amounts: CodexTokenAmounts
    }
    private struct Event {
        let identity: Identity
        let date: Date
        let model: String
        let costs: CodexTokenCosts
    }
    private struct FileState {
        var offset: UInt64 = 0
        var modified: Date?
        var pending = Data()
        var model = "未记录模型"
        var serviceTier: String?
        var previous: CodexTokenAmounts?
        var events: [Event] = []
        var skipped = 0
    }

    private let root: URL
    private var files: [String: FileState] = [:]
    private var retainedSince: Date?
    private let decoder = JSONDecoder()
    private let iso = ISO8601DateFormatter()
    private let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter
    }()
    private let usageMarker = Data("\"token_count\"".utf8)
    private let contextMarker = Data("\"turn_context\"".utf8)
    private let settingsMarker = Data("\"thread_settings_applied\"".utf8)

    init(root: URL = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.root = root
    }

    private func consume(_ line: Data, state: inout FileState, since: Date) {
        guard line.range(of: usageMarker) != nil || line.range(of: contextMarker) != nil
                || line.range(of: settingsMarker) != nil else { return }
        guard let record = try? decoder.decode(Record.self, from: line) else {
            state.skipped += 1
            return
        }
        if record.type == "turn_context" {
            if let model = record.payload.model, !model.isEmpty { state.model = model }
            return
        }
        if record.type == "event_msg", record.payload.type == "thread_settings_applied" {
            state.serviceTier = record.payload.thread_settings?.service_tier
            return
        }
        guard record.type == "event_msg", record.payload.type == "token_count",
              let info = record.payload.info else { return }
        let previous = state.previous
        state.previous = info.total_token_usage
        if let total = info.total_token_usage, let previous,
           total.input == previous.input, total.output == previous.output { return }
        // 累计值可能继承自更早的聊天；只记本次请求，不能把首条累计值计入当天。
        guard let amounts = info.last_token_usage, amounts.valid,
              let date = fractionalISO.date(from: record.timestamp) ?? iso.date(from: record.timestamp) else {
            state.skipped += 1
            return
        }
        guard date >= since, amounts.total > 0 else { return }
        state.events.append(Event(identity: Identity(timestamp: record.timestamp,
                                                     cumulative: info.total_token_usage, amounts: amounts),
                                  date: date, model: state.model,
                                  costs: CodexTokenPricing.breakdown(model: state.model, amounts: amounts,
                                                                    serviceTier: state.serviceTier)))
    }

    func read(now: Date = Date(), timeZone: TimeZone = .current,
              range: DateInterval? = nil) throws -> CodexTokenUsageSnapshot {
        if let range, range.duration == 0 { throw CodexTokenUsageError.invalidRange }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        var starts = [calendar.startOfDay(for: now),
                      calendar.dateInterval(of: .weekOfYear, for: now)!.start,
                      calendar.dateInterval(of: .month, for: now)!.start]
        var names = ["今日", "本周", "本月"]
        if let range {
            starts.append(range.start)
            let lastDay = range.end.addingTimeInterval(-1)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = calendar.isDate(range.start, equalTo: now, toGranularity: .year)
                && calendar.isDate(lastDay, equalTo: now, toGranularity: .year) ? "M/d" : "yy/M/d"
            names.append(formatter.string(from: range.start) + "–" + formatter.string(from: lastDay))
        }
        let since = starts.min()!
        if let retainedSince {
            if since < retainedSince { files.removeAll() }
            else if since > retainedSince {
                files = files.mapValues {
                    var state = $0
                    state.events.removeAll { $0.date < since }
                    return state
                }
            }
        }
        retainedSince = since
        let manager = FileManager.default
        var liveFiles = Set<String>()
        var unreadable = 0
        var foundDirectory = false
        for name in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(name)
            guard manager.fileExists(atPath: directory.path) else { continue }
            foundDirectory = true
            guard let enumerator = manager.enumerator(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles],
                errorHandler: { _, _ in unreadable += 1; return true }) else {
                unreadable += 1
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                liveFiles.insert(url.path)
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = UInt64(values.fileSize ?? 0)
                    var state = files[url.path] ?? FileState()
                    // shortcut: 按追加日志增量读取；若未来原地重写并增长文件，需校验已读前缀。
                    if state.offset == size, state.modified == values.contentModificationDate { continue }
                    if size < state.offset || (size == state.offset && state.modified != values.contentModificationDate) {
                        state = FileState()
                    }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: state.offset)
                    while state.offset < size,
                          let chunk = try handle.read(upToCount: Int(min(1024 * 1024, size - state.offset))), !chunk.isEmpty {
                        state.offset += UInt64(chunk.count)
                        state.pending.append(chunk)
                        autoreleasepool {
                            while let newline = state.pending.firstIndex(of: 10) {
                                let line = Data(state.pending[..<newline])
                                state.pending.removeSubrange(...newline)
                                consume(line, state: &state, since: since)
                            }
                        }
                    }
                    // 缓存只留尚未写完的一行，释放扫描大文件时扩大的缓冲区。
                    state.pending = state.pending.subdata(in: state.pending.startIndex..<state.pending.endIndex)
                    state.modified = values.contentModificationDate
                    state.events.removeAll { $0.date < since }
                    files[url.path] = state
                } catch { unreadable += 1 }
            }
        }
        guard foundDirectory else { throw CodexTokenUsageError.missingSessions }
        files = files.filter { liveFiles.contains($0.key) }
        var periods = names.map { CodexTokenUsagePeriod(name: $0) }
        var seen = Set<Identity>()
        for state in files.values {
            for event in state.events where event.date >= since && event.date <= now {
                // 分叉历史或重复副本保留事件时间和累计值，跨文件只统计一次。
                guard seen.insert(event.identity).inserted else { continue }
                for index in periods.indices where event.date >= starts[index] {
                    if index == 3, let range, event.date >= range.end { continue }
                    periods[index].models[event.model] = try (periods[index].models[event.model] ?? CodexTokenAmounts())
                        .adding(event.identity.amounts)
                    periods[index].costs[event.model] = (periods[index].costs[event.model] ?? CodexTokenCosts())
                        .adding(event.costs)
                }
            }
        }
        for period in periods { _ = try period.total }
        return CodexTokenUsageSnapshot(periods: periods, updated: now, timeZone: timeZone.identifier,
                                       unreadableFiles: unreadable, skippedEvents: files.values.reduce(0) { $0 + $1.skipped })
    }
}

extension CodexTokenUsageReader {
    static func selfTest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func line(_ type: String, _ payload: [String: Any], at: String = "2026-11-01T01:00:00Z") throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": at, "payload": payload])
            data.append(10)
            return data
        }
        func event(_ at: String, input: Int, output: Int, cumulative: Int, cumulativeOutput: Int = 100,
                   cached: Int? = nil, write: Int? = nil) throws -> Data {
            let usage = ["input_tokens": input, "cached_input_tokens": cached ?? input / 2,
                         "cache_write_input_tokens": write ?? input / 10,
                         "output_tokens": output, "reasoning_output_tokens": output / 2]
            return try line("event_msg", ["type": "token_count", "info": [
                "last_token_usage": usage,
                "total_token_usage": ["input_tokens": cumulative, "output_tokens": cumulativeOutput]
            ]], at: at)
        }
        var data = try line("turn_context", ["model": "gpt-a"])
        data += try event("2026-10-25T15:59:59Z", input: 900, output: 90, cumulative: 1_000_000)
        data += try event("2026-10-25T16:00:00Z", input: 100, output: 20, cumulative: 1_000_100)
        data += try event("2026-10-31T15:59:59Z", input: 200, output: 30, cumulative: 1_000_300)
        data += try event("2026-10-31T16:00:00.001Z", input: 300, output: 40, cumulative: 1_000_600)
        data += try event("2026-10-31T16:01:00Z", input: 300, output: 40, cumulative: 1_000_600)
        data += try line("turn_context", ["model": "gpt-b"])
        data += try event("2026-11-01T00:00:00Z", input: 400, output: 50, cumulative: 1_001_000)
        data += try line("turn_context", ["model": "gpt-a"])
        data += try event("2026-11-01T01:00:00Z", input: 0, output: 10, cumulative: 1_001_000, cumulativeOutput: 110)
        let file = sessions.appendingPathComponent("original.jsonl")
        try data.write(to: file)
        let now = ISO8601DateFormatter().date(from: "2026-11-01T08:00:00Z")!
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let reader = CodexTokenUsageReader(root: root)
        let first = try reader.read(now: now, timeZone: zone)
        let totals = try first.periods.map { try $0.total.total }
        precondition(totals == [800, 1150, 800])
        precondition(first.periods[0].models["gpt-a"]?.uncached == 120)
        precondition(first.periods[0].models["gpt-a"]?.cached == 150)
        precondition(first.periods[0].models["gpt-a"]?.cacheWrite == 30)
        precondition(first.periods[0].models["gpt-a"]?.output == 50)
        precondition(first.skippedEvents == 0)
        try data.write(to: sessions.appendingPathComponent("fork-copy.jsonl"))
        try FileManager.default.moveItem(at: file, to: archived.appendingPathComponent("original.jsonl"))
        let copied = try reader.read(now: now, timeZone: zone)
        let copiedTotal = try copied.periods[0].total.total
        precondition(copiedTotal == 800)
        let partial = sessions.appendingPathComponent("partial.jsonl")
        let extra = try event("2026-11-01T02:00:00Z", input: 50, output: 10, cumulative: 50)
        try extra.dropLast(2).write(to: partial)
        let partialTotal = try reader.read(now: now, timeZone: zone).periods[0].total.total
        precondition(partialTotal == 800)
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd()
        try handle.write(contentsOf: extra.suffix(2))
        try handle.close()
        let appended = try reader.read(now: now, timeZone: zone)
        let appendedTotal = try appended.periods[0].total.total
        precondition(appendedTotal == 860)
        precondition(appended.periods[0].models["未记录模型"]?.total == 60)
        try Data().write(to: partial)
        let truncatedTotal = try reader.read(now: now, timeZone: zone).periods[0].total.total
        precondition(truncatedTotal == 800)
        let iso = ISO8601DateFormatter()
        let oldDay = iso.date(from: "2026-10-25T08:00:00Z")!
        let oldRange = try dateRange(from: oldDay, through: oldDay, timeZone: zone)
        let historical = try reader.read(now: now, timeZone: zone, range: oldRange)
        let historicalTotal = try historical.periods[3].total.total
        let unchanged = try historical.periods.prefix(3).map { try $0.total.total }
        precondition(historicalTotal == 990 && unchanged == [800, 1150, 800])
        let october31 = iso.date(from: "2026-10-31T08:00:00Z")!
        let monthEndRange = try dateRange(from: october31, through: october31, timeZone: zone)
        let monthEnd = try reader.read(now: now, timeZone: zone, range: monthEndRange)
        let monthEndTotal = try monthEnd.periods[3].total.total
        precondition(monthEndTotal == 230 && monthEnd.periods[3].name == "10/31–10/31")
        let twoDays = try dateRange(from: october31, through: now, timeZone: zone)
        let spanning = try reader.read(now: now, timeZone: zone, range: twoDays)
        let spanningTotal = try spanning.periods[3].total.total
        precondition(spanningTotal == 1030 && spanning.periods[3].name == "10/31–11/1")
        do {
            _ = try dateRange(from: now, through: oldDay, timeZone: zone)
            preconditionFailure("Reversed dates must be rejected")
        } catch CodexTokenUsageError.invalidRange {}
        let emptyDay = iso.date(from: "2026-09-01T08:00:00Z")!
        let emptyRange = try dateRange(from: emptyDay, through: emptyDay, timeZone: zone)
        let emptyHistory = try reader.read(now: now, timeZone: zone, range: emptyRange)
        precondition(emptyHistory.periods[3].models.isEmpty && emptyHistory.periods[3].estimatedUSD == 0)
        let missing = try JSONDecoder().decode(CodexTokenAmounts.self,
            from: Data(#"{"input_tokens":100,"output_tokens":10}"#.utf8))
        precondition(missing.cached == nil && missing.uncached == nil && missing.rows.contains("缓存命中：未记录"))
        let priced = CodexTokenAmounts(input: 200_000, cached: 100_000, cacheWrite: 20_000, output: 10_000, reasoning: 3_000)
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: priced) == Decimal(32) / 100)
        let parts = CodexTokenPricing.breakdown(model: "gpt-6.1-sol", amounts: priced)
        precondition(parts.uncached == Decimal(16) / 100 && parts.cached == Decimal(1) / 100)
        precondition(parts.cacheWrite == Decimal(5) / 100 && parts.input == Decimal(22) / 100)
        precondition(parts.output == Decimal(10) / 100 && parts.reasoning == Decimal(3) / 100)
        precondition(parts.total == parts.input + parts.output)
        precondition(parts.rows(amounts: priced)[2].hasSuffix(" · $0.16"))
        precondition(parts.rows(amounts: priced)[6].hasSuffix(" · $0.03"))
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-terra", amounts: priced) == Decimal(16) / 100)
        var long = priced
        long.input = 300_000
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: long) == Decimal(99) / 100)
        let longParts = CodexTokenPricing.breakdown(model: "gpt-6.1-sol", amounts: long)
        precondition(longParts.uncached == Decimal(72) / 100 && longParts.cached == Decimal(2) / 100)
        precondition(longParts.cacheWrite == Decimal(10) / 100 && longParts.output == Decimal(15) / 100)
        precondition(longParts.reasoning == Decimal(45) / 1000)
        long.input = 272_000
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: long) == Decimal(464) / 1000)
        precondition(CodexTokenPricing.estimate(model: "codex-auto-review", amounts: priced) == 0)
        precondition(CodexTokenPricing.estimate(model: "workbuddy/glm-5.3", amounts: priced) == 0)
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: missing) == 0)
        let fast = CodexTokenPricing.breakdown(model: "gpt-6.1-sol", amounts: priced, serviceTier: "fast")
        precondition(fast.total == Decimal(64) / 100 && fast.input == parts.input * 2)
        precondition(fast.cached == parts.cached * 2 && fast.cacheWrite == parts.cacheWrite * 2)
        precondition(fast.output == parts.output * 2 && fast.reasoning == parts.reasoning * 2)
        precondition(fast.rows(amounts: priced).last == "档位：Fast")
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: priced, serviceTier: "priority") == fast.total)
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: priced, serviceTier: nil) == 0)
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: priced, serviceTier: "auto") == 0)
        precondition(CodexTokenPricing.estimate(model: "codex-auto-review", amounts: priced, serviceTier: "fast") == 0)
        long.input = 300_000
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: long, serviceTier: "fast") == Decimal(198) / 100)
        precondition(CodexTokenPricing.dollars(0) == "$0.00")
        precondition(CodexTokenPricing.dollars(Decimal(1005) / 1000) == "$1.01")
        var priceData = try line("turn_context", ["model": "gpt-6.1-sol"])
        priceData += try line("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": "default"]])
        priceData += try event("2026-11-01T03:00:00Z", input: 150_000, output: 1000, cumulative: 150_000)
        priceData += try event("2026-11-01T04:00:00Z", input: 150_000, output: 1000, cumulative: 300_000)
        try priceData.write(to: sessions.appendingPathComponent("priced.jsonl"))
        let todayRange = try dateRange(from: now, through: now, timeZone: zone)
        let withPrices = try reader.read(now: now, timeZone: zone, range: todayRange)
        precondition(withPrices.periods[0].estimatedUSD == Decimal(35) / 100)
        precondition(withPrices.periods[3].estimatedUSD == Decimal(35) / 100)
        precondition(withPrices.periods[0].costs["gpt-a"]?.total == 0)
        let summed = withPrices.periods[0].costs["gpt-6.1-sol"]!
        precondition(summed.uncached == Decimal(24) / 100 && summed.cached == Decimal(15) / 1000)
        precondition(summed.cacheWrite == Decimal(75) / 1000 && summed.output == Decimal(2) / 100)
        precondition(summed.reasoning == Decimal(1) / 100 && summed.total == Decimal(35) / 100)
        let mixedFile = sessions.appendingPathComponent("mixed-speeds.jsonl")
        var mixedData = try line("turn_context", ["model": "gpt-6.1-sol"])
        mixedData += try event("2026-11-01T05:00:00Z", input: 150_000, output: 1000, cumulative: 150_000)
        mixedData += try line("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": "priority"]])
        mixedData += try event("2026-11-01T05:01:00Z", input: 150_000, output: 1000, cumulative: 300_000)
        mixedData += try line("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": "default"]])
        mixedData += try event("2026-11-01T05:02:00Z", input: 150_000, output: 1000, cumulative: 450_000)
        mixedData += try line("event_msg", ["type": "thread_settings_applied", "thread_settings": [:]])
        mixedData += try event("2026-11-01T05:03:00Z", input: 150_000, output: 1000, cumulative: 600_000)
        try mixedData.write(to: mixedFile)
        let mixed = try reader.read(now: now, timeZone: zone, range: todayRange)
        let mixedCost = mixed.periods[0].costs["gpt-6.1-sol"]!
        precondition(mixed.periods[0].models["gpt-6.1-sol"]?.total == 906_000)
        precondition(mixedCost.total == Decimal(875) / 1000)
        precondition(mixedCost.serviceTiers == ["标准", "Fast", "未知"])
        precondition(mixed.periods[3].estimatedUSD == mixed.periods[0].estimatedUSD)
        let fork = archived.appendingPathComponent("mixed-copy.jsonl")
        try mixedData.write(to: fork)
        let deduplicated = try reader.read(now: now, timeZone: zone)
        precondition(deduplicated.periods[0].estimatedUSD == mixed.periods[0].estimatedUSD)
        try FileManager.default.removeItem(at: fork)
        try FileManager.default.removeItem(at: mixedFile)
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("priced.jsonl"))
        let unknownSum = try missing.adding(CodexTokenAmounts(input: 10, cached: 5))
        precondition(unknownSum.cached == nil && unknownSum.total == 120)
        let absent = try line("event_msg", ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": 1_000_000, "output_tokens": 1_000]
        ]])
        try absent.write(to: sessions.appendingPathComponent("missing-last.jsonl"))
        let incomplete = try reader.read(now: now, timeZone: zone)
        let incompleteTotal = try incomplete.periods[0].total.total
        precondition(incomplete.skippedEvents == 1 && incompleteTotal == 800)
        precondition(!CodexTokenAmounts(input: 10, cached: 11).valid)
        do {
            _ = try CodexTokenAmounts(input: Int64.max).adding(CodexTokenAmounts(input: 1))
            preconditionFailure("Overflow must not crash or wrap the token count")
        } catch CodexTokenUsageError.overflow {}
    }
}
