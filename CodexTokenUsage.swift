import Foundation

struct CodexTokenAmounts: Codable, Equatable, Hashable {
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

enum CodexTokenTier: String {
    case standard = "标准", fast = "Fast", unknown = "未知"

    init(_ recorded: String?) {
        switch recorded {
        case "default", "standard": self = .standard
        case "fast", "priority": self = .fast
        default: self = .unknown
        }
    }
}

struct CodexTokenUsageGroup: Hashable {
    let model: String
    let tier: CodexTokenTier
    var title: String { "\(model) · \(tier.rawValue)" }
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
        let tier = CodexTokenTier(serviceTier)
        let label = tier.rawValue
        switch tier {
        case .standard: multiplier = 1
        case .fast: multiplier = 2
        case .unknown: return CodexTokenCosts(serviceTiers: [label])
        }
        guard let rate = rates[model], amounts.valid,
              let uncached = amounts.uncached, let cached = amounts.cached,
              let write = amounts.cacheWrite else { return CodexTokenCosts(serviceTiers: [label]) }
        // shortcut: 用日志中的请求档位和默认 30 分钟缓存估价；实际回退和其他缓存寿命需响应元数据。
        // 订阅用量折算不加收长上下文费，只按请求档位调整单价。
        return CodexTokenCosts(
            uncached: Decimal(uncached) * rate.input * multiplier / 1_000_000,
            cached: Decimal(cached) * rate.cached * multiplier / 1_000_000,
            cacheWrite: Decimal(write) * rate.input * 5 / 4 * multiplier / 1_000_000,
            output: Decimal(amounts.output) * rate.output * multiplier / 1_000_000,
            reasoning: Decimal(amounts.reasoning ?? 0) * rate.output * multiplier / 1_000_000,
            serviceTiers: [label])
    }

    static func dollars(_ amount: Decimal) -> String {
        var value = amount, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        if amount > 0 && rounded == 0 { return "<$0.01" }
        return rounded.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }
}

struct CodexTokenUsagePeriod {
    let name: String
    let interval: DateInterval
    var isDateQuery = false
    var models: [CodexTokenUsageGroup: CodexTokenAmounts] = [:]
    var costs: [CodexTokenUsageGroup: CodexTokenCosts] = [:]
    var performance: [CodexTokenUsageGroup: CodexOutputPerformance] = [:]
    var estimatedUSD: Decimal { costs.values.reduce(0) { $0 + $1.total } }
    var total: CodexTokenAmounts {
        get throws { try models.values.reduce(CodexTokenAmounts()) { try $0.adding($1) } }
    }
}

struct CodexOutputPerformance {
    var output: Double = 0
    var seconds: Double = 0
    var samples: Int = 0
    var requests: Int = 0
    var average: Double? {
        guard samples > 0, seconds > 0 else { return nil }
        let value = output / seconds
        return value.isFinite ? value : nil
    }
    var label: String {
        "tok/s avg: " + (average.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—")
    }
    var sampleLabel: String { "测速样本：\(samples) / \(requests) 次请求" }

    mutating func include(_ record: CodexUsageRecord) {
        requests += 1
        guard record.amounts.output > 0, let duration = record.responseSeconds, duration.isFinite, duration > 0 else { return }
        guard (seconds + duration).isFinite else { return }
        output += Double(record.amounts.output)
        seconds += duration
        samples += 1
    }
}

struct CodexTokenUsageSnapshot {
    var periods: [CodexTokenUsagePeriod]
    let updated: Date
    let timeZone: String
    let unreadableFiles: Int
    let skippedEvents: Int
    var devices: [CodexUsageDevice] = []
    var syncMessage: String?
    var usageWarnings: [String] = []
    var previousQuotaCycle: CodexQuotaCycle?
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
            let thread_id: String?
            let turn_id: String?
            let usage: CodexTokenAmounts?
            let response_id: String?
            let thread_token_usage: CodexTokenAmounts?
            let service_tier: String?
            let role: String?
        }
        struct ThreadSettings: Decodable {
            let service_tier: String?
        }
        struct HistoricalRateLimits: Decodable {
            let limit_id: String?
            let primary: HistoricalWindow?
            let secondary: HistoricalWindow?
        }
        struct HistoricalWindow: Decodable {
            let used_percent: Double
            let window_minutes: Int?
            let resets_at: Double?
        }
        struct Info: Decodable {
            let total_token_usage: CodexTokenAmounts?
            let last_token_usage: CodexTokenAmounts?
        }
    }
    private struct HistoricalQuota: Decodable {
        let payload: Payload
        struct Payload: Decodable { let rate_limits: Record.HistoricalRateLimits }
    }
    private struct Event {
        var record: CodexUsageRecord
        var responseSpan: CodexResponseSpan? = nil
        var date: Date { Date(timeIntervalSince1970: record.occurredAt) }
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
        var firstOutput: Date?
        var lastOutput: Date?
        var previousUsage: Date?
        var pendingUsage: (record: CodexUsageRecord, date: Date, span: CodexResponseSpan?)?
        var quotaObservations: [Double: CodexWeeklyQuotaObservation] = [:]
    }

    private let root: URL
    private let responseTiming: CodexResponseTimingReader
    private let backgroundUsage: CodexBackgroundUsageReader?
    private let openCodexUsage: OpenCodexUsageReader?
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
    private let nativeUsageMarker = Data("\"token_usage_record\"".utf8)
    private let quotaMarker = Data("\"rate_limits\"".utf8)
    private let outputMarker = Data("\"response_item\"".utf8)

    init(root: URL? = nil, backgroundLogs: URL? = nil, openCodexLog: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let usageLog = openCodexLog ?? (root == nil ? OpenCodexUsageReader.defaultLog : nil)
        openCodexUsage = usageLog.map(OpenCodexUsageReader.init)
        responseTiming = CodexResponseTimingReader(root: self.root)
        let logs = backgroundLogs ?? (root == nil ? CodexBackgroundUsageReader.defaultDirectory : nil)
        backgroundUsage = logs.map { CodexBackgroundUsageReader(logRoot: $0, cache: root == nil ? CodexBackgroundUsageReader.defaultCache : nil) }
    }

    private func consume(_ line: Data, state: inout FileState, since: Date) {
        guard line.range(of: usageMarker) != nil || line.range(of: contextMarker) != nil
                || line.range(of: settingsMarker) != nil || line.range(of: nativeUsageMarker) != nil
                || line.range(of: outputMarker) != nil else { return }
        guard let record = try? decoder.decode(Record.self, from: line) else {
            state.skipped += 1
            return
        }
        if record.type == "turn_context" {
            if let model = record.payload.model, !model.isEmpty { state.model = model }
            state.firstOutput = nil
            state.lastOutput = nil
            state.pendingUsage = nil
            return
        }
        if record.type == "response_item" {
            let type = record.payload.type ?? ""
            guard ["reasoning", "function_call", "custom_tool_call"].contains(type)
                    || (type == "message" && record.payload.role == "assistant"),
                  let date = fractionalISO.date(from: record.timestamp) ?? iso.date(from: record.timestamp) else { return }
            state.firstOutput = min(state.firstOutput ?? date, date)
            state.lastOutput = max(state.lastOutput ?? date, date)
            return
        }
        if record.type == "token_usage_record" {
            defer { state.firstOutput = nil; state.lastOutput = nil }
            guard let amounts = record.payload.usage, amounts.valid,
                  let date = fractionalISO.date(from: record.timestamp) ?? iso.date(from: record.timestamp) else {
                state.pendingUsage = nil
                return
            }
            var span: CodexResponseSpan?
            if let thread = record.payload.thread_id, let turn = record.payload.turn_id,
               let first = state.firstOutput, let last = state.lastOutput, last <= date {
                span = CodexResponseSpan(threadID: thread, turnID: turn, firstOutput: first,
                                        lastOutput: last, previousUsage: state.previousUsage)
            }
            let native = CodexUsageRecord(timestamp: record.timestamp, occurredAt: date.timeIntervalSince1970,
                model: record.payload.model ?? state.model, serviceTier: record.payload.service_tier,
                cumulative: record.payload.thread_token_usage, amounts: amounts, source: "native")
            var measured = native
            let responseID = record.payload.response_id.flatMap { $0.isEmpty || $0.utf8.count > 256 ? nil : $0 }
            measured.requestKey = CodexUsageRecord.digest(Data((responseID.map { "response:" + $0 } ?? "native:" + native.id).utf8))
            state.pendingUsage = (measured, date, span)
            if measured.model != "codex-auto-review", amounts.total > 0, date >= since {
                state.events.append(Event(record: measured, responseSpan: span))
            }
            state.previousUsage = date
            return
        }
        if record.type == "event_msg", record.payload.type == "thread_settings_applied" {
            state.serviceTier = record.payload.thread_settings?.service_tier
            return
        }
        if record.type == "event_msg", record.payload.type == "token_count",
           line.range(of: quotaMarker) != nil,
           let rate = (try? decoder.decode(HistoricalQuota.self, from: line))?.payload.rate_limits,
           rate.limit_id == nil || rate.limit_id == "codex",
           let date = fractionalISO.date(from: record.timestamp) ?? iso.date(from: record.timestamp) {
            for window in [rate.primary, rate.secondary].compactMap({ $0 }) where window.window_minutes == 10080 {
                guard let reset = window.resets_at else { continue }
                let observation = CodexWeeklyQuotaObservation(reset: Date(timeIntervalSince1970: reset),
                    usedPercent: window.used_percent, observedAt: date)
                if observation.valid { state.quotaObservations[reset] = observation }
            }
        }
        guard record.type == "event_msg", record.payload.type == "token_count",
              let info = record.payload.info else { return }
        defer { state.pendingUsage = nil; state.firstOutput = nil; state.lastOutput = nil }
        let previous = state.previous
        state.previous = info.total_token_usage
        guard state.model != "codex-auto-review" else { return }
        if let total = info.total_token_usage, let previous,
           total.input == previous.input, total.output == previous.output { return }
        // 累计值可能继承自更早的聊天；只记本次请求，不能把首条累计值计入当天。
        guard let amounts = info.last_token_usage, amounts.valid,
              let date = fractionalISO.date(from: record.timestamp) ?? iso.date(from: record.timestamp) else {
            state.skipped += 1
            return
        }
        guard date >= since, amounts.total > 0 else { return }
        let pending = state.pendingUsage.flatMap { pending in
            let sameTotal = pending.record.cumulative.flatMap { native in
                info.total_token_usage.map { native.input == $0.input && native.output == $0.output }
            }
            // 压缩请求会使原生累计值领先旧计数器；本次分项相同也可确认是同一次响应。
            return date >= pending.date && (pending.record.amounts == amounts || sameTotal == true) ? pending : nil
        }
        let span = pending.flatMap { $0.record.amounts == amounts ? $0.span : nil }
        state.events.append(Event(record: CodexUsageRecord(timestamp: record.timestamp, occurredAt: date.timeIntervalSince1970,
            model: state.model, serviceTier: state.serviceTier, cumulative: info.total_token_usage, amounts: amounts,
            requestKey: pending?.record.requestKey), responseSpan: span))
    }

    func historicalQuotaObservations() -> [CodexWeeklyQuotaObservation] {
        files.values.flatMap { $0.quotaObservations.values }
    }

    func read(now: Date = Date(), timeZone: TimeZone = .current,
              weeklyRange: DateInterval? = nil, previousWeeklyRange: DateInterval? = nil, range: DateInterval? = nil,
              sync: CodexUsageSync? = nil, device: String? = nil) throws -> CodexTokenUsageSnapshot {
        if let range, range.duration == 0 { throw CodexTokenUsageError.invalidRange }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var periods = [CodexTokenUsagePeriod(name: "今日", interval: calendar.dateInterval(of: .day, for: now)!)]
        if let weeklyRange, weeklyRange.start <= now, now < weeklyRange.end {
            periods.append(CodexTokenUsagePeriod(name: "当前周额度", interval: weeklyRange))
        }
        if let previousWeeklyRange, previousWeeklyRange.duration > 0, previousWeeklyRange.end <= now {
            periods.append(CodexTokenUsagePeriod(name: "上一轮额度", interval: previousWeeklyRange))
        }
        if let range {
            let lastDay = range.end.addingTimeInterval(-1)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = calendar.isDate(range.start, equalTo: now, toGranularity: .year)
                && calendar.isDate(lastDay, equalTo: now, toGranularity: .year) ? "M/d" : "yy/M/d"
            periods.append(CodexTokenUsagePeriod(
                name: formatter.string(from: range.start) + "–" + formatter.string(from: lastDay), interval: range, isDateQuery: true))
        }
        let querySince = periods.map { $0.interval.start }.min()!
        responseTiming.refresh()
        let since = sync == nil ? querySince : Date.distantPast
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
        files = files.filter { liveFiles.contains($0.key) }
        let background = backgroundUsage?.read()
        let proxy = openCodexUsage?.read()
        guard foundDirectory || sync != nil || !(background?.records.isEmpty ?? true)
                || !(proxy?.records.isEmpty ?? true) else { throw CodexTokenUsageError.missingSessions }
        let local = files.values.flatMap(\.events).map { event in
            var event = event
            if let span = event.responseSpan { event.record.responseSeconds = responseTiming.seconds(for: span) }
            return event
        }
        let raw = local.map(\.record) + (background?.records ?? []) + (proxy?.records ?? [])
        var warnings = Set(background?.warnings ?? [])
        if proxy?.failed == true { warnings.insert("OpenCodex 用量日志暂时无法读取") }
        let shared = sync?.exchange(local: raw, selectedDevice: device, now: now)
        let records = shared?.records ?? CodexUsageRecord.merged(raw, warnings: &warnings)
        for record in records where record.occurredAt >= querySince.timeIntervalSince1970 && record.occurredAt <= now.timeIntervalSince1970 {
            let date = Date(timeIntervalSince1970: record.occurredAt)
            let group = CodexTokenUsageGroup(model: record.model, tier: CodexTokenTier(record.serviceTier))
            let costs = CodexTokenPricing.breakdown(model: record.model, amounts: record.amounts, serviceTier: record.serviceTier)
            for index in periods.indices where date >= periods[index].interval.start && date < periods[index].interval.end {
                periods[index].models[group] = try (periods[index].models[group] ?? CodexTokenAmounts()).adding(record.amounts)
                periods[index].costs[group] = (periods[index].costs[group] ?? CodexTokenCosts()).adding(costs)
                periods[index].performance[group, default: CodexOutputPerformance()].include(record)
            }
        }
        for period in periods { _ = try period.total }
        var snapshot = CodexTokenUsageSnapshot(periods: periods, updated: now, timeZone: timeZone.identifier,
                                       unreadableFiles: unreadable + (background?.unreadable ?? 0),
                                       skippedEvents: files.values.reduce(0) { $0 + $1.skipped } + (background?.skipped ?? 0))
        snapshot.devices = shared?.devices ?? []
        snapshot.syncMessage = shared?.message
        snapshot.usageWarnings = warnings.sorted()
        return snapshot
    }
}

private final class OpenCodexUsageReader {
    static let defaultLog: URL = {
        let path = ProcessInfo.processInfo.environment["OPENCODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencodex")
        return directory.appendingPathComponent("usage.jsonl")
    }()

    private struct Entry: Decodable {
        let requestId: String
        let timestamp: Int64
        let durationMs: Int64?
        let lastOutputMs: Int64?
        let model: String
        let resolvedModel: String?
        let servedModel: String?
        let usageStatus: String
        let responseServiceTier: String?
        let requestedServiceTier: String?
        let configuredServiceTier: String?
        let usage: Usage?

        struct Usage: Decodable {
            let inputTokens: Int64
            let outputTokens: Int64
            let cachedInputTokens: Int64?
            let cacheReadInputTokens: Int64?
            let cacheCreationInputTokens: Int64?
            let reasoningOutputTokens: Int64?
        }
    }

    private let log: URL
    private let decoder = JSONDecoder()
    private let iso = ISO8601DateFormatter()
    private let since = ISO8601DateFormatter().date(from: "2026-11-09T00:00:00+08:00")!
    private var records: [String: CodexUsageRecord] = [:]
    private var inode: NSNumber?
    private var offset = 0

    init(log: URL) {
        self.log = log
        iso.formatOptions.insert(.withFractionalSeconds)
    }

    func read() -> (records: [CodexUsageRecord], failed: Bool) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
            let fileID = attributes[.systemFileNumber] as? NSNumber
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if inode != fileID || offset > size { offset = 0 }
            inode = fileID
            if size > offset {
                let file = try FileHandle(forReadingFrom: log)
                defer { try? file.close() }
                try file.seek(toOffset: UInt64(offset))
                let appended = try file.read(upToCount: size - offset) ?? Data()
                if let last = appended.lastIndex(of: 10) {
                    for line in appended[..<last].split(separator: 10) {
                        guard line.range(of: Data("gpt-".utf8)) != nil,
                              let entry = try? decoder.decode(Entry.self, from: line),
                              entry.usageStatus == "reported", let usage = entry.usage,
                              !entry.requestId.isEmpty, entry.requestId.utf8.count <= 256 else { continue }
                        let model = entry.servedModel ?? entry.resolvedModel ?? entry.model
                        guard model.hasPrefix("gpt-") else { continue }
                        let start = Date(timeIntervalSince1970: Double(entry.timestamp) / 1000)
                        guard start >= since, start <= Date() else { continue }
                        let duration = max(0, min(entry.durationMs ?? 0, 86_400_000))
                        let date = start.addingTimeInterval(Double(duration) / 1000)
                        let responseSeconds = entry.lastOutputMs.flatMap {
                            $0 > 0 && $0 <= duration ? Double($0) / 1000 : nil
                        }
                        let amounts = CodexTokenAmounts(input: usage.inputTokens,
                            cached: usage.cacheReadInputTokens ?? usage.cachedInputTokens,
                            cacheWrite: usage.cacheCreationInputTokens,
                            output: usage.outputTokens, reasoning: usage.reasoningOutputTokens)
                        guard amounts.valid, amounts.total > 0 else { continue }
                        let tier = entry.responseServiceTier ?? entry.requestedServiceTier ?? entry.configuredServiceTier
                        let response = "opencodex-backfill:" + CodexUsageRecord.digest(Data(entry.requestId.utf8))
                        let key = CodexUsageRecord.digest(Data(("response:" + response).utf8))
                        let record = CodexUsageRecord(timestamp: iso.string(from: date), occurredAt: date.timeIntervalSince1970,
                            model: model, serviceTier: tier, cumulative: nil, amounts: amounts,
                            responseSeconds: responseSeconds, requestKey: key, source: "opencodex")
                        if record.valid { records[key] = record }
                    }
                    offset += last + 1
                }
            }
            return (Array(records.values), false)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return (Array(records.values), false)
        } catch {
            return (Array(records.values), true)
        }
    }
}

extension CodexTokenUsageReader {
    private static func testOpenCodexUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let iso = ISO8601DateFormatter()
        let date = iso.date(from: "2026-11-09T01:00:00Z")!
        let now = date.addingTimeInterval(60)
        let log = root.appendingPathComponent("usage.jsonl")
        let usage = ["inputTokens": 100, "cachedInputTokens": 20, "cacheCreationInputTokens": 0,
                     "outputTokens": 5, "reasoningOutputTokens": 1]
        func row(_ id: String, _ model: String, _ seconds: Double) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "requestId": id, "timestamp": Int((date.timeIntervalSince1970 + seconds) * 1000),
                "durationMs": 1000, "lastOutputMs": id == "later" ? 1100 : 500,
                "model": model, "usageStatus": "reported",
                "responseServiceTier": "default", "usage": usage
            ])
        }
        let reader = CodexTokenUsageReader(root: root, openCodexLog: log)
        try (row("old", "gpt-6.1-sol", -40_000) + Data([10])
            + row("other", "deepseek-v4.1-flash", 0) + Data([10])
            + row("proxy", "gpt-6.1-sol", 0) + Data([10])
            + row("later", "gpt-6.1-sol", 30)).write(to: log)
        let first = try reader.read(now: now)
        precondition(try! first.periods[0].total.total == 105)
        let append = try FileHandle(forWritingTo: log)
        try append.seekToEnd()
        try append.write(contentsOf: Data([10]))
        try append.close()
        let second = try reader.read(now: now)
        precondition(try! second.periods[0].total.total == 210)
        let performance = second.periods[0].performance.values.first!
        precondition(performance.requests == 2 && performance.samples == 1 && performance.average == 10)

        let proxy = OpenCodexUsageReader(log: log).read().records.first { $0.occurredAt < date.timeIntervalSince1970 + 10 }!
        var amounts = proxy.amounts
        amounts.cacheWrite = nil
        let original = CodexUsageRecord(timestamp: iso.string(from: date.addingTimeInterval(2)),
            occurredAt: date.timeIntervalSince1970 + 2, model: proxy.model,
            serviceTier: nil, cumulative: nil, amounts: amounts, source: "desktop:thread_title")
        var warnings = Set<String>()
        let merged = CodexUsageRecord.merged([original, proxy], warnings: &warnings)
        precondition(merged.count == 1 && merged[0].amounts == proxy.amounts && merged[0].serviceTier == "default")
        precondition(merged[0].responseSeconds == 0.5)
        precondition(merged[0].aliases?.contains(original.id) == true && warnings.isEmpty)
        var timedOriginal = original
        timedOriginal.responseSeconds = 0.75
        precondition(CodexUsageRecord.merged([timedOriginal, proxy], warnings: &warnings).first?.responseSeconds == 0.75)
        let roundTrip = CodexUsageRecord.merged(merged + [original, proxy], warnings: &warnings)
        precondition(roundTrip.count == 1 && roundTrip[0].amounts == proxy.amounts && warnings.isEmpty)
    }

    static func selfTest() throws {
        try testOpenCodexUsage()
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
        let unknownA = CodexTokenUsageGroup(model: "gpt-a", tier: .unknown)
        let unrecorded = CodexTokenUsageGroup(model: "未记录模型", tier: .unknown)
        let standardSol = CodexTokenUsageGroup(model: "gpt-6.1-sol", tier: .standard)
        let fastSol = CodexTokenUsageGroup(model: "gpt-6.1-sol", tier: .fast)
        let unknownSol = CodexTokenUsageGroup(model: "gpt-6.1-sol", tier: .unknown)
        let cycleStart = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!
        let cycle = DateInterval(start: cycleStart, duration: 7 * 24 * 60 * 60)
        let historicalQuota = try line("event_msg", ["type": "token_count", "rate_limits": [
            "limit_id": "codex", "primary": ["used_percent": 87, "window_minutes": 10080,
                                              "resets_at": cycle.end.timeIntervalSince1970]]])
        try historicalQuota.write(to: sessions.appendingPathComponent("quota-history.jsonl"))
        let first = try reader.read(now: now, timeZone: zone, weeklyRange: cycle)
        precondition(reader.historicalQuotaObservations().count == 1
                     && reader.historicalQuotaObservations()[0].usedPercent == 87)
        let totals = try first.periods.map { try $0.total.total }
        precondition(totals == [800, 1030])
        precondition(first.periods.map { $0.name } == ["今日", "当前周额度"])
        precondition(first.periods[1].interval == cycle)
        precondition(first.periods[0].models[unknownA]?.uncached == 120)
        precondition(first.periods[0].models[unknownA]?.cached == 150)
        precondition(first.periods[0].models[unknownA]?.cacheWrite == 30)
        precondition(first.periods[0].models[unknownA]?.output == 50)
        precondition(first.skippedEvents == 0)
        try data.write(to: sessions.appendingPathComponent("fork-copy.jsonl"))
        try FileManager.default.moveItem(at: file, to: archived.appendingPathComponent("original.jsonl"))
        let copied = try reader.read(now: now, timeZone: zone, weeklyRange: cycle)
        let copiedTotal = try copied.periods[0].total.total
        precondition(copiedTotal == 800)
        let partial = sessions.appendingPathComponent("partial.jsonl")
        let extra = try event("2026-11-01T02:00:00Z", input: 50, output: 10, cumulative: 50)
        try extra.dropLast(2).write(to: partial)
        let partialTotal = try reader.read(now: now, timeZone: zone, weeklyRange: cycle).periods[0].total.total
        precondition(partialTotal == 800)
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd()
        try handle.write(contentsOf: extra.suffix(2))
        try handle.close()
        let appended = try reader.read(now: now, timeZone: zone, weeklyRange: cycle)
        let appendedTotal = try appended.periods[0].total.total
        precondition(appendedTotal == 860)
        precondition(appended.periods[0].models[unrecorded]?.total == 60)
        try Data().write(to: partial)
        let truncatedTotal = try reader.read(now: now, timeZone: zone, weeklyRange: cycle).periods[0].total.total
        precondition(truncatedTotal == 800)
        let iso = ISO8601DateFormatter()
        let oldDay = iso.date(from: "2026-10-25T08:00:00Z")!
        let oldRange = try dateRange(from: oldDay, through: oldDay, timeZone: zone)
        let historical = try reader.read(now: now, timeZone: zone, weeklyRange: cycle, range: oldRange)
        let historicalTotal = try historical.periods[2].total.total
        let unchanged = try historical.periods.prefix(2).map { try $0.total.total }
        precondition(historicalTotal == 990 && unchanged == [800, 1030])
        let october31 = iso.date(from: "2026-10-31T08:00:00Z")!
        let monthEndRange = try dateRange(from: october31, through: october31, timeZone: zone)
        let monthEnd = try reader.read(now: now, timeZone: zone, weeklyRange: cycle, range: monthEndRange)
        let monthEndTotal = try monthEnd.periods[2].total.total
        precondition(monthEndTotal == 230 && monthEnd.periods[2].name == "10/31–10/31")
        let twoDays = try dateRange(from: october31, through: now, timeZone: zone)
        let spanning = try reader.read(now: now, timeZone: zone, weeklyRange: cycle, range: twoDays)
        let spanningTotal = try spanning.periods[2].total.total
        precondition(spanningTotal == 1030 && spanning.periods[2].name == "10/31–11/1")
        do {
            _ = try dateRange(from: now, through: oldDay, timeZone: zone)
            preconditionFailure("Reversed dates must be rejected")
        } catch CodexTokenUsageError.invalidRange {}
        let emptyDay = iso.date(from: "2026-09-01T08:00:00Z")!
        let emptyRange = try dateRange(from: emptyDay, through: emptyDay, timeZone: zone)
        let emptyHistory = try reader.read(now: now, timeZone: zone, weeklyRange: cycle, range: emptyRange)
        precondition(emptyHistory.periods[2].models.isEmpty && emptyHistory.periods[2].estimatedUSD == 0)
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
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: long) == Decimal(52) / 100)
        let longParts = CodexTokenPricing.breakdown(model: "gpt-6.1-sol", amounts: long)
        precondition(longParts.uncached == Decimal(36) / 100 && longParts.cached == parts.cached)
        precondition(longParts.cacheWrite == parts.cacheWrite && longParts.output == parts.output)
        precondition(longParts.reasoning == parts.reasoning)
        long.input = 272_000
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: long) == Decimal(464) / 1000)
        long.input = 272_001
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: long) == Decimal(464002) / 1_000_000)
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
        precondition(CodexTokenPricing.estimate(model: "gpt-6.1-sol", amounts: long, serviceTier: "fast") == longParts.total * 2)
        precondition(CodexTokenPricing.dollars(0) == "$0.00")
        precondition(CodexTokenPricing.dollars(Decimal(1485) / 1_000_000) == "<$0.01")
        precondition(CodexTokenPricing.dollars(Decimal(1005) / 1000) == "$1.01")
        var priceData = try line("turn_context", ["model": "gpt-6.1-sol"])
        priceData += try line("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": "default"]])
        priceData += try event("2026-11-01T03:00:00Z", input: 150_000, output: 1000, cumulative: 150_000)
        priceData += try event("2026-11-01T04:00:00Z", input: 150_000, output: 1000, cumulative: 300_000)
        try priceData.write(to: sessions.appendingPathComponent("priced.jsonl"))
        let todayRange = try dateRange(from: now, through: now, timeZone: zone)
        let withPrices = try reader.read(now: now, timeZone: zone, weeklyRange: cycle, range: todayRange)
        precondition(withPrices.periods[0].estimatedUSD == Decimal(35) / 100)
        precondition(withPrices.periods[2].estimatedUSD == Decimal(35) / 100)
        precondition(withPrices.periods[0].costs[unknownA]?.total == 0)
        let summed = withPrices.periods[0].costs[standardSol]!
        precondition(summed.uncached == Decimal(24) / 100 && summed.cached == Decimal(15) / 1000)
        precondition(summed.cacheWrite == Decimal(75) / 1000 && summed.output == Decimal(2) / 100)
        precondition(summed.reasoning == Decimal(1) / 100 && summed.total == Decimal(35) / 100)
        let mixedFile = sessions.appendingPathComponent("mixed-speeds.jsonl")
        var mixedData = try line("turn_context", ["model": "gpt-6.1-sol"])
        mixedData += try event("2026-11-01T05:00:00Z", input: 150_000, output: 1000, cumulative: 150_000)
        mixedData += try line("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": "priority"]])
        mixedData += try event("2026-11-01T05:01:00Z", input: 150_000, output: 1000, cumulative: 300_000)
        mixedData += try line("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": "fast"]])
        mixedData += try event("2026-11-01T05:01:30Z", input: 150_000, output: 1000, cumulative: 450_000)
        mixedData += try line("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": "default"]])
        mixedData += try event("2026-11-01T05:02:00Z", input: 150_000, output: 1000, cumulative: 600_000)
        mixedData += try line("event_msg", ["type": "thread_settings_applied", "thread_settings": [:]])
        mixedData += try event("2026-11-01T05:03:00Z", input: 150_000, output: 1000, cumulative: 750_000)
        try mixedData.write(to: mixedFile)
        let freeFile = sessions.appendingPathComponent("auto-review.jsonl")
        var freeData = try line("turn_context", ["model": "codex-auto-review"])
        for (index, tier) in ["default", "fast", "priority"].enumerated() {
            freeData += try line("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": tier]])
            freeData += try event("2026-11-01T05:04:0\(index)Z", input: 1_000_000, output: 100_000,
                                  cumulative: (index + 1) * 1_000_000)
        }
        try freeData.write(to: freeFile)
        let mixed = try reader.read(now: now, timeZone: zone, weeklyRange: cycle, range: todayRange)
        let mixedTotals = try mixed.periods.map { try $0.total.total }
        precondition(mixedTotals == [1_057_800, 1_058_030, 1_057_800])
        precondition(mixed.periods.allSatisfy { period in
            !period.models.keys.contains { $0.model == "codex-auto-review" }
                && !period.costs.keys.contains { $0.model == "codex-auto-review" }
        })
        precondition(mixed.periods[0].models[unknownA] != nil)
        let solGroups = mixed.periods[0].models.filter { $0.key.model == "gpt-6.1-sol" }
        precondition(solGroups.count == 3 && solGroups.values.reduce(0, { $0 + $1.total }) == 1_057_000)
        precondition(solGroups[standardSol]?.total == 453_000 && solGroups[fastSol]?.total == 302_000)
        precondition(solGroups[unknownSol]?.total == 302_000)
        precondition(solGroups[fastSol]?.cached == 150_000 && solGroups[fastSol]?.cacheWrite == 30_000)
        precondition(fastSol.title == "gpt-6.1-sol · Fast" && standardSol.title == "gpt-6.1-sol · 标准")
        precondition(mixed.periods[0].costs[standardSol]?.total == Decimal(525) / 1000)
        precondition(mixed.periods[0].costs[fastSol]?.total == Decimal(7) / 10)
        precondition(mixed.periods[0].costs[unknownSol]?.total == 0)
        precondition(mixed.periods[0].costs[fastSol]?.serviceTiers == ["Fast"])
        precondition(mixed.periods[0].estimatedUSD == Decimal(1225) / 1000)
        precondition(mixed.periods[1].models[fastSol] == mixed.periods[0].models[fastSol])
        precondition(mixed.periods[2].models[fastSol] == mixed.periods[0].models[fastSol])
        precondition(mixed.periods[2].estimatedUSD == mixed.periods[0].estimatedUSD)
        let fork = archived.appendingPathComponent("mixed-copy.jsonl")
        try mixedData.write(to: fork)
        let deduplicated = try reader.read(now: now, timeZone: zone, weeklyRange: cycle)
        precondition(deduplicated.periods[0].estimatedUSD == mixed.periods[0].estimatedUSD)
        precondition(deduplicated.periods[0].models[fastSol] == mixed.periods[0].models[fastSol])
        try FileManager.default.removeItem(at: fork)
        try FileManager.default.removeItem(at: mixedFile)
        try FileManager.default.removeItem(at: freeFile)
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("priced.jsonl"))
        let boundaryFile = sessions.appendingPathComponent("cycle-boundaries.jsonl")
        var boundaryData = try line("turn_context", ["model": "gpt-6.1-sol"])
        boundaryData += try line("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": "default"]])
        boundaryData += try event("2026-10-28T11:59:59.999Z", input: 100, output: 10, cumulative: 100)
        boundaryData += try event("2026-10-28T12:00:00Z", input: 200, output: 20, cumulative: 300)
        boundaryData += try event("2026-11-04T11:59:59.999Z", input: 300, output: 30, cumulative: 600)
        boundaryData += try event("2026-11-04T12:00:00Z", input: 400, output: 40, cumulative: 1000)
        boundaryData += try event("2026-11-04T12:00:01Z", input: 500, output: 50, cumulative: 1500)
        try boundaryData.write(to: boundaryFile)
        let currentCycle = try reader.read(now: now, timeZone: zone, weeklyRange: cycle)
        let cycleTokens = try currentCycle.periods[1].total.total
        precondition(cycleTokens == 1250 && currentCycle.periods[1].estimatedUSD == Decimal(42) / 100_000)
        let beforeReset = try reader.read(now: cycle.end.addingTimeInterval(-0.0001), timeZone: zone, weeklyRange: cycle)
        let beforeResetTokens = try beforeReset.periods[1].total.total
        precondition(beforeResetTokens == 1580, "Old cycle must include requests before reset, excluding the reset instant")
        let nextCycle = DateInterval(start: cycle.end, duration: cycle.duration)
        let afterReset = try reader.read(now: cycle.end, timeZone: zone, weeklyRange: nextCycle)
        let afterResetTokens = try afterReset.periods[1].total.total
        precondition(afterResetTokens == 440, "The request at reset belongs to the next cycle; future requests are excluded")
        let withPrevious = try reader.read(now: cycle.end, timeZone: zone, weeklyRange: nextCycle,
                                           previousWeeklyRange: cycle, range: cycle)
        let previousTokens = try withPrevious.periods[2].total.total
        precondition(withPrevious.periods[2].name == "上一轮额度" && previousTokens == 1580)
        precondition(!withPrevious.periods[2].isDateQuery && withPrevious.periods[3].isDateQuery)
        let expired = try reader.read(now: cycle.end, timeZone: zone, weeklyRange: cycle)
        precondition(expired.periods.count == 1)
        try FileManager.default.removeItem(at: boundaryFile)
        let noCycle = try reader.read(now: now, timeZone: zone, range: todayRange)
        let noCycleTokens = try noCycle.periods[1].total.total
        precondition(noCycle.periods.count == 2 && noCycleTokens == 800)
        let unknownSum = try missing.adding(CodexTokenAmounts(input: 10, cached: 5))
        precondition(unknownSum.cached == nil && unknownSum.total == 120)
        let absent = try line("event_msg", ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": 1_000_000, "output_tokens": 1_000]
        ]])
        try absent.write(to: sessions.appendingPathComponent("missing-last.jsonl"))
        let incomplete = try reader.read(now: now, timeZone: zone, weeklyRange: cycle)
        let incompleteTotal = try incomplete.periods[0].total.total
        precondition(incomplete.skippedEvents == 1 && incompleteTotal == 800)
        precondition(!CodexTokenAmounts(input: 10, cached: 11).valid)
        let badQuotaRoot = root.appendingPathComponent("bad-quota")
        let badQuotaSessions = badQuotaRoot.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: badQuotaSessions, withIntermediateDirectories: true)
        var badQuota = try JSONSerialization.jsonObject(with: event("2026-11-01T03:00:00Z", input: 100, output: 10, cumulative: 100)) as! [String: Any]
        var badPayload = badQuota["payload"] as! [String: Any]
        badPayload["rate_limits"] = ["primary": "invalid"]
        badQuota["payload"] = badPayload
        var badData = try JSONSerialization.data(withJSONObject: badQuota)
        badData.append(10)
        try badData.write(to: badQuotaSessions.appendingPathComponent("bad.jsonl"))
        let badQuotaReader = CodexTokenUsageReader(root: badQuotaRoot)
        let goodUsage = try badQuotaReader.read(now: now, timeZone: zone)
        let goodTokens = try goodUsage.periods[0].total.total
        precondition(goodTokens == 110 && goodUsage.skippedEvents == 0 && badQuotaReader.historicalQuotaObservations().isEmpty,
                     "Malformed historical quota must not discard valid token usage")
        do {
            _ = try CodexTokenAmounts(input: Int64.max).adding(CodexTokenAmounts(input: 1))
            preconditionFailure("Overflow must not crash or wrap the token count")
        } catch CodexTokenUsageError.overflow {}
    }
}
