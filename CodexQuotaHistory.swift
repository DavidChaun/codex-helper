import Foundation

struct CodexWeeklyQuotaObservation {
    let reset: Date
    let usedPercent: Double
    let observedAt: Date
    var interval: DateInterval { DateInterval(start: reset.addingTimeInterval(-604800), end: reset) }
    var valid: Bool {
        reset.timeIntervalSince1970.isFinite && observedAt.timeIntervalSince1970.isFinite
            && usedPercent.isFinite && (0...100).contains(usedPercent)
            && interval.start <= observedAt && observedAt < reset
    }
}

struct CodexQuotaCycle: Codable, Equatable {
    var start: Date
    var end: Date
    var reset: Date
    var usedPercent: Double
    var observedAt: Date
    var reconstructed: Bool
    var interval: DateInterval { DateInterval(start: start, end: end) }
    var changedEarly: Bool { reset.timeIntervalSince(end) > 60 }
    var valid: Bool {
        [start, end, reset, observedAt].allSatisfy { $0.timeIntervalSince1970.isFinite }
            && start < end && end <= reset && end.timeIntervalSince(start) <= 604860
            && start <= observedAt && observedAt <= end
            && usedPercent.isFinite && (0...100).contains(usedPercent)
    }
}

struct CodexQuotaHistory: Codable, Equatable {
    static let defaultsKey = "quotaWeekHistoryV1"
    private var version = 1
    private(set) var current: CodexQuotaCycle?
    private(set) var previous: CodexQuotaCycle?

    static func decode(_ data: Data?) throws -> Self {
        guard let data else { return Self() }
        guard data.count <= 16384 else { throw CocoaError(.fileReadTooLarge) }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1, result.current?.valid ?? true, result.previous?.valid ?? true,
              result.previous == nil || result.current != nil,
              result.previous.map({ $0.end <= result.current!.start }) ?? true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }

    mutating func recover(_ observations: [CodexWeeklyQuotaObservation]) {
        guard current == nil else { return }
        for observation in observations.sorted(by: { $0.observedAt < $1.observedAt }) {
            observe(observation, reconstructed: true)
        }
    }

    mutating func observe(_ observation: CodexWeeklyQuotaObservation, reconstructed: Bool = false) {
        guard observation.valid else { return }
        let range = observation.interval
        if var old = current {
            guard observation.observedAt >= old.observedAt else { return }
            // 官方重置时间会有秒级浮动，不因此生成新一轮额度。
            if abs(observation.reset.timeIntervalSince(old.reset)) <= 60 {
                if abs(range.start.timeIntervalSince(old.start)) <= 60 {
                    if var previous, previous.changedEarly,
                       abs(previous.end.timeIntervalSince(old.start)) <= 60 {
                        previous.end = min(previous.reset, range.start)
                        self.previous = previous
                    }
                    old.start = max(range.start, previous?.end ?? range.start)
                }
                old.end = observation.reset
                old.reset = observation.reset
                old.usedPercent = observation.usedPercent
                old.observedAt = observation.observedAt
                current = old
                return
            }
            // 新的名义起点不在两次观测之间时，只能以首次观测到变化的时刻分界。
            let boundary = range.start > old.observedAt ? range.start : observation.observedAt
            if range.start <= old.observedAt { old.reconstructed = true }
            old.end = min(old.reset, boundary)
            if old.valid { previous = old }
        }
        current = CodexQuotaCycle(start: max(range.start, previous?.end ?? range.start), end: range.end,
            reset: observation.reset, usedPercent: observation.usedPercent,
            observedAt: observation.observedAt, reconstructed: reconstructed)
    }

    static func selfTest() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func observation(_ offset: Double, reset: Double, used: Double) -> CodexWeeklyQuotaObservation {
            CodexWeeklyQuotaObservation(reset: start.addingTimeInterval(reset), usedPercent: used,
                                        observedAt: start.addingTimeInterval(offset))
        }
        var history = Self()
        history.recover([observation(100, reset: 604800, used: 20),
                         observation(200, reset: 604800, used: 100)])
        history.observe(observation(1000, reset: 605790, used: 0))
        precondition(history.previous?.start == start && history.previous?.end == start.addingTimeInterval(990))
        precondition(history.previous?.usedPercent == 100 && history.previous?.changedEarly == true)
        precondition(history.previous?.reconstructed == true)
        history.observe(observation(1010, reset: 605800, used: 0))
        precondition(history.previous?.end == start.addingTimeInterval(1000), "Do not archive a second cycle for reset jitter")
        let saved = try JSONEncoder().encode(history)
        let restored = try Self.decode(saved)
        precondition(restored == history)
        let prior = history
        history.observe(observation(50, reset: 604800, used: 10))
        precondition(history == prior, "Ignore stale quota responses")
        history.observe(observation(605810, reset: 1210600, used: 1))
        precondition(history.previous?.end == start.addingTimeInterval(605800))
        precondition(history.previous?.changedEarly == false && history.previous?.reconstructed == false)
        let valid = history
        history.observe(observation(605820, reset: 1210600, used: .nan))
        precondition(history == valid)
        var uncertain = Self()
        uncertain.observe(observation(100000, reset: 604800, used: 50))
        uncertain.observe(observation(100100, reset: 500000, used: 0))
        precondition(uncertain.previous?.end == start.addingTimeInterval(100100))
        precondition(uncertain.current?.start == uncertain.previous?.end && uncertain.previous?.reconstructed == true)
        _ = try Self.decode(JSONEncoder().encode(uncertain))
        do { _ = try Self.decode(Data("{}".utf8)); preconditionFailure("Reject a damaged history archive") }
        catch is DecodingError {}
        var malformed = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        malformed["version"] = 99
        do { _ = try Self.decode(JSONSerialization.data(withJSONObject: malformed)); preconditionFailure("Reject an unknown history version") }
        catch is CocoaError {}
    }
}
