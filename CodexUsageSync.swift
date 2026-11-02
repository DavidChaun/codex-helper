import Foundation
import CryptoKit

struct CodexUsageRecord: Codable, Equatable {
    let id: String
    let timestamp: String
    let occurredAt: Double
    let model: String
    let serviceTier: String?
    let cumulative: CodexTokenAmounts?
    let amounts: CodexTokenAmounts
    var responseSeconds: Double?
    var requestKey: String?
    var aliases: [String]?
    let source: String?

    private struct Identity: Encodable {
        let timestamp: String
        let cumulative: CodexTokenAmounts?
        let amounts: CodexTokenAmounts
    }
    init(timestamp: String, occurredAt: Double, model: String, serviceTier: String?,
         cumulative: CodexTokenAmounts?, amounts: CodexTokenAmounts, id: String? = nil, responseSeconds: Double? = nil,
         requestKey: String? = nil, aliases: [String]? = nil, source: String? = nil) {
        self.timestamp = timestamp
        self.occurredAt = occurredAt
        self.model = model
        self.serviceTier = serviceTier
        self.cumulative = cumulative
        self.amounts = amounts
        self.responseSeconds = responseSeconds
        self.requestKey = requestKey
        self.aliases = aliases
        self.source = source
        self.id = id ?? Self.fingerprint(timestamp: timestamp, cumulative: cumulative, amounts: amounts)
    }
    static func fingerprint(timestamp: String, cumulative: CodexTokenAmounts?, amounts: CodexTokenAmounts) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return digest(try! encoder.encode(Identity(timestamp: timestamp, cumulative: cumulative, amounts: amounts)))
    }
    static func digest(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: SHA256.hash(data: data).flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }
    var valid: Bool {
        occurredAt.isFinite && amounts.valid && amounts.total > 0
            && !model.isEmpty && model.utf8.count <= 200 && timestamp.utf8.count <= 64
            && (serviceTier?.utf8.count ?? 0) <= 64
            && (responseSeconds.map { $0.isFinite && $0 > 0 } ?? true)
            && (requestKey.map { Self.isHash($0) } ?? true)
            && (aliases.map { requestKey != nil && $0.count <= 64 && $0.allSatisfy(Self.isHash) } ?? true)
            && (source.map { $0.range(of: #"^[A-Za-z0-9_.:/-]{1,128}$"#, options: .regularExpression) != nil } ?? true)
    }
    private static func isHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func merged(_ records: [CodexUsageRecord], warnings: inout Set<String>) -> [CodexUsageRecord] {
        let valid = records.filter { $0.valid && $0.model != "codex-auto-review" }
        var keys: [String: Set<String>] = [:]
        for record in valid {
            if let key = record.requestKey {
                for alias in [record.id] + (record.aliases ?? []) { keys[alias, default: []].insert(key) }
            }
        }
        if keys.values.contains(where: { $0.count > 1 }) { warnings.insert("部分重复记录的请求标识冲突，已优先采用明确标识的请求") }
        let groups = Dictionary(grouping: valid.filter { $0.requestKey != nil || (keys[$0.id]?.count ?? 0) <= 1 }) { record in
            if let key = record.requestKey ?? keys[record.id]?.first { return "request:" + key }
            return "event:" + record.id
        }
        return groups.values.map { copies in
            let native = copies.first { $0.source == "native" }
            let preferNative = native.map { original in copies.contains { $0.amounts != original.amounts } } ?? false
            let first = copies.min {
                let left = ($0.source == "native") == preferNative ? 0 : 1
                let right = ($1.source == "native") == preferNative ? 0 : 1
                return left == right ? ($0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp) : left < right
            }!
            if copies.count == 1 { return first }
            let models = Set(copies.map(\.model).filter { $0 != "未记录模型" && $0 != "未确认模型" })
            let tiers = Set(copies.map { CodexTokenTier($0.serviceTier) }.filter { $0 != .unknown })
            let conflict = models.count > 1 || copies.contains { $0.model == "未确认模型" }
            let model = conflict ? "未确认模型" : models.first ?? "未记录模型"
            let tierConflict = tiers.count > 1 || copies.contains { $0.serviceTier == "conflict" }
            let tier: String? = conflict || tierConflict ? "conflict" : tiers.count == 1 ? (tiers.first == .fast ? "fast" : "default") : nil
            if conflict || tierConflict { warnings.insert("重复记录的模型或档位冲突，无法确认的费用按 $0") }
            let key = copies.compactMap(\.requestKey).first
            let aliases = Set(copies.flatMap { [$0.id] + ($0.aliases ?? []) }).subtracting([first.id]).sorted()
            if aliases.count > 64 { warnings.insert("单次请求的重复标识超过缓存上限，部分旧格式副本可能需要重新核对") }
            return CodexUsageRecord(timestamp: first.timestamp, occurredAt: first.occurredAt, model: model,
                serviceTier: tier, cumulative: first.cumulative, amounts: first.amounts, id: first.id,
                responseSeconds: copies.compactMap(\.responseSeconds).max(), requestKey: key,
                aliases: key == nil || aliases.isEmpty ? nil : Array(aliases.prefix(64)), source: first.source)
        }.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }
}

extension CodexUsageSync {
    static func selfTest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = root.appendingPathComponent("Drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let cloud = drive.appendingPathComponent("Codex Helper/Usage/v1")
        let aID = UUID().uuidString.lowercased(), bID = UUID().uuidString.lowercased()
        let aCache = root.appendingPathComponent("cache-a"), bCache = root.appendingPathComponent("cache-b")
        let a = CodexUsageSync(cloud: cloud, cache: aCache, deviceID: aID, deviceName: "Mac A")
        let b = CodexUsageSync(cloud: cloud, cache: bCache, deviceID: bID, deviceName: "Mac B")
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-11-01T08:00:00Z")!
        func record(_ time: String, tier: String? = "default", model: String = "gpt-6.1-sol") -> CodexUsageRecord {
            CodexUsageRecord(timestamp: time, occurredAt: iso.date(from: time)!.timeIntervalSince1970,
                model: model, serviceTier: tier, cumulative: nil,
                amounts: CodexTokenAmounts(input: 200_000, cached: 100_000, cacheWrite: 20_000, output: 10_000, reasoning: 3_000))
        }
        let first = record("2026-11-01T02:00:00Z"), second = record("2026-11-01T03:00:00Z", tier: "priority")
        let third = record("2026-11-01T04:00:00Z")
        let free = record("2026-11-01T05:00:00Z", model: "codex-auto-review")
        precondition(a.exchange(local: [first, free], now: now).records.count == 1)
        let both = b.exchange(local: [first, second], now: now.addingTimeInterval(1))
        precondition(both.records.count == 2 && both.devices.count == 2, "First peer exchange: \(both.records.count) records, \(both.devices.count) devices; \(both.message)")
        let received = a.exchange(local: [first], now: now.addingTimeInterval(61))
        precondition(received.records.count == 2, "Peer import: \(received.records.count) records; \(received.message)")
        let stale = CodexUsageSync(cloud: cloud, cache: aCache, deviceID: aID, deviceName: "Mac A")
        _ = stale.exchange(local: [first], now: now.addingTimeInterval(64))
        precondition(a.exchange(local: [first], selectedDevice: aID, now: now.addingTimeInterval(62)).records.count == 1)
        precondition(a.exchange(local: [first], selectedDevice: bID, now: now.addingTimeInterval(63)).records.count == 2)
        let hiddenDrive = root.appendingPathComponent("OfflineDrive")
        try FileManager.default.moveItem(at: drive, to: hiddenDrive)
        let offline = a.exchange(local: [first, third], now: now.addingTimeInterval(122))
        precondition(offline.records.count == 3 && offline.message.contains("暂不可用"))
        let fourth = record("2026-11-01T05:30:00Z")
        precondition(stale.exchange(local: [first, fourth], now: now.addingTimeInterval(125)).records.count == 4,
                     "A stale same-device writer must retain the newer offline cache")
        let restarted = CodexUsageSync(cloud: cloud, cache: aCache, deviceID: aID, deviceName: "Mac A")
        precondition(restarted.exchange(local: [], now: now.addingTimeInterval(183)).records.count == 4)
        try FileManager.default.moveItem(at: hiddenDrive, to: drive)
        _ = restarted.exchange(local: [], now: now.addingTimeInterval(244))
        precondition(b.exchange(local: [], now: now.addingTimeInterval(245)).records.count == 4)
        let reader = CodexTokenUsageReader(root: root.appendingPathComponent("empty-codex"))
        let snapshot = try reader.read(now: now.addingTimeInterval(246), timeZone: TimeZone(secondsFromGMT: 0)!, sync: b)
        let tokenTotal = try snapshot.periods[0].total.total
        precondition(tokenTotal == 840_000 && snapshot.periods[0].estimatedUSD == Decimal(160) / 100)
        let bFile = cloud.appendingPathComponent(bID + "/2026-11-01.json")
        let goodData = try Data(contentsOf: bFile)
        try Data("broken".utf8).write(to: bFile)
        let damaged = restarted.exchange(local: [], now: now.addingTimeInterval(305))
        precondition(damaged.records.count == 4 && damaged.message.contains("保留上次缓存"))
        try goodData.write(to: bFile)
        var object = try JSONSerialization.jsonObject(with: goodData) as! [String: Any]
        object["deviceID"] = "../../outside"
        let invalid = try JSONSerialization.data(withJSONObject: object)
        do { _ = try a.decode(invalid); preconditionFailure("Reject path traversal in peer files") }
        catch is CocoaError {}
        var timedFirst = first
        timedFirst.responseSeconds = 4
        precondition(timedFirst.id == first.id)
        let legacyRecord = try JSONEncoder().encode(first)
        let decodedLegacy = try JSONDecoder().decode(CodexUsageRecord.self, from: legacyRecord)
        precondition(decodedLegacy.responseSeconds == nil)
        let enriched = b.exchange(local: [timedFirst], now: now.addingTimeInterval(366))
        precondition(enriched.records.first { $0.id == first.id }?.responseSeconds == 4)
        let peerTiming = restarted.exchange(local: [first], now: now.addingTimeInterval(367))
        precondition(peerTiming.records.first { $0.id == first.id }?.responseSeconds == 4,
                     "An older client copy must not erase timing or double-count the event")
        let timedSnapshot = try reader.read(now: now.addingTimeInterval(368), timeZone: TimeZone(secondsFromGMT: 0)!, sync: restarted)
        let timedStats = timedSnapshot.periods[0].performance[CodexTokenUsageGroup(model: "gpt-6.1-sol", tier: .standard)]!
        precondition(timedStats.samples == 1 && timedStats.requests == 3 && timedStats.average == 2500)
        let aliasCloud = drive.appendingPathComponent("Alias Helper/Usage/v1")
        let left = CodexUsageSync(cloud: aliasCloud, cache: root.appendingPathComponent("alias-left"), deviceID: UUID().uuidString, deviceName: "Left")
        let right = CodexUsageSync(cloud: aliasCloud, cache: root.appendingPathComponent("alias-right"), deviceID: UUID().uuidString, deviceName: "Right")
        let requestKey = CodexUsageRecord.digest(Data("response:PRIVATE_RESPONSE_ID".utf8))
        let native = CodexUsageRecord(timestamp: first.timestamp.replacingOccurrences(of: "Z", with: ".000Z"),
            occurredAt: first.occurredAt, model: first.model, serviceTier: first.serviceTier,
            cumulative: first.cumulative, amounts: first.amounts, requestKey: requestKey, source: "native")
        var linked = first
        linked.requestKey = requestKey
        precondition(left.exchange(local: [native], now: now).records.count == 1)
        let joined = right.exchange(local: [linked], now: now.addingTimeInterval(1))
        precondition(joined.records.count == 1 && joined.records[0].aliases?.contains(native.id) == true)
        precondition(left.exchange(local: [native], now: now.addingTimeInterval(61)).records.count == 1)
        func oldCopy(_ record: CodexUsageRecord) throws -> CodexUsageRecord {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
            for key in ["requestKey", "aliases", "source"] { object.removeValue(forKey: key) }
            return try JSONDecoder().decode(CodexUsageRecord.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let oldNative = try oldCopy(native)
        precondition(oldNative.id == CodexUsageRecord.fingerprint(timestamp: oldNative.timestamp, cumulative: oldNative.cumulative, amounts: oldNative.amounts), "Preserve the old wire fingerprint")
        let migrated = CodexUsageSync(cloud: aliasCloud, cache: root.appendingPathComponent("alias-migrated"), deviceID: UUID().uuidString, deviceName: "Migrated")
        let oldCopies = try [oldCopy(native), oldCopy(linked)]
        precondition(migrated.exchange(local: oldCopies, now: now.addingTimeInterval(122)).records.count == 1,
                     "New request aliases must also deduplicate cached copies from an older client")
        var invalidTiming = first
        invalidTiming.responseSeconds = -.infinity
        precondition(!invalidTiming.valid)
        object = try JSONSerialization.jsonObject(with: goodData) as! [String: Any]
        var records = object["records"] as! [[String: Any]]
        var amounts = records[0]["amounts"] as! [String: Any]
        amounts["input_tokens"] = -1
        records[0]["amounts"] = amounts
        object["records"] = records
        do { _ = try a.decode(JSONSerialization.data(withJSONObject: object)); preconditionFailure("Reject negative usage") }
        catch is CocoaError {}
        let c = CodexUsageSync(cloud: cloud, cache: root.appendingPathComponent("cache-c"),
                              deviceID: UUID().uuidString.lowercased(), deviceName: "Mac C")
        let conflicting = record(first.timestamp, tier: "fast")
        precondition(first.id == conflicting.id)
        let conflict = c.exchange(local: [conflicting, first], now: now.addingTimeInterval(366))
        let unresolved = conflict.records.first { $0.id == first.id }!
        precondition(unresolved.serviceTier == "conflict" && conflict.message.contains("冲突"))
        precondition(CodexTokenPricing.estimate(model: unresolved.model, amounts: unresolved.amounts, serviceTier: unresolved.serviceTier) == 0)
        let again = c.exchange(local: [first], now: now.addingTimeInterval(427))
        precondition(again.records.first { $0.id == first.id }?.serviceTier == "conflict")
        let source = root.appendingPathComponent("history-codex/sessions")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let oldTime = "2026-09-01T03:00:00Z"
        let lines: [[String: Any]] = [
            ["timestamp": oldTime, "type": "turn_context", "payload": ["model": "gpt-6.1-sol"]],
            ["timestamp": oldTime, "type": "event_msg", "payload": ["type": "thread_settings_applied", "thread_settings": ["service_tier": "default"]]],
            ["timestamp": oldTime, "type": "response_item", "payload": ["type": "message", "text": "PRIVATE_DO_NOT_SYNC"]],
            ["timestamp": oldTime, "type": "event_msg", "payload": ["type": "token_count", "info": [
                "last_token_usage": ["input_tokens": 100, "cached_input_tokens": 10, "cache_write_input_tokens": 0, "output_tokens": 5]]]]
        ]
        var data = Data()
        for line in lines { data.append(try JSONSerialization.data(withJSONObject: line)); data.append(10) }
        try data.write(to: source.appendingPathComponent("history.jsonl"))
        let historyReader = CodexTokenUsageReader(root: source.deletingLastPathComponent())
        let historySync = CodexUsageSync(cloud: cloud, cache: root.appendingPathComponent("cache-history"),
                                       deviceID: UUID().uuidString.lowercased(), deviceName: "History Mac")
        let day = iso.date(from: oldTime)!
        let range = try CodexTokenUsageReader.dateRange(from: day, through: day, timeZone: TimeZone(secondsFromGMT: 0)!)
        let history = try historyReader.read(now: now.addingTimeInterval(488), timeZone: TimeZone(secondsFromGMT: 0)!, range: range, sync: historySync)
        let historicalTokens = try history.periods[1].total.total
        precondition(historicalTokens == 105)
        let allowed: Set<String> = ["id", "timestamp", "occurredAt", "model", "serviceTier", "cumulative", "amounts", "responseSeconds", "requestKey", "aliases", "source"]
        for case let url as URL in FileManager.default.enumerator(at: cloud, includingPropertiesForKeys: nil)! where url.pathExtension == "json" {
            let exported = try Data(contentsOf: url)
            let text = String(decoding: exported, as: UTF8.self)
            precondition(!text.contains("PRIVATE_DO_NOT_SYNC") && !text.contains("codex-auto-review"))
            let file = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
            for record in file["records"] as! [[String: Any]] { precondition(Set(record.keys).isSubset(of: allowed)) }
        }
    }
}

struct CodexUsageDevice {
    let id: String
    let name: String
    let updated: Date?
}

struct CodexUsageSyncResult {
    let records: [CodexUsageRecord]
    let devices: [CodexUsageDevice]
    let message: String
}

final class CodexUsageSync {
    // shortcut: 每设备每天一个文件，上限 64MB；单日超限时应升级为日期分片。
    private static let maxBatchBytes = 64 * 1024 * 1024
    static let cloudDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Codex Helper/Usage/v1", isDirectory: true)
    private struct Batch: Codable {
        let version: Int
        let deviceID: String
        let deviceName: String
        let day: String
        let updated: Date
        let records: [CodexUsageRecord]
    }
    let deviceID: String
    private let deviceName: String
    private let cloud: URL
    private let cache: URL
    private var batches: [String: Batch] = [:]
    private var loaded = false
    private var lastExchange: Date?
    private var warnings = Set<String>()
    private var cloudVersions: [URL: String] = [:]
    private var cloudCopies: [URL: Batch] = [:]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    private let decoder = JSONDecoder()
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(cloud: URL = CodexUsageSync.cloudDirectory,
         cache: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Helper/UsageCache/v1", isDirectory: true),
         deviceID: String? = nil, deviceName: String = Host.current().localizedName ?? "Mac",
         defaults: UserDefaults = .standard) {
        self.cloud = cloud
        self.cache = cache
        self.deviceName = String(deviceName.prefix(80))
        if let deviceID { self.deviceID = deviceID }
        else if let saved = defaults.string(forKey: "usageDeviceID"), UUID(uuidString: saved) != nil {
            self.deviceID = saved
        } else {
            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: "usageDeviceID")
            self.deviceID = generated
        }
    }

    private func decode(_ data: Data) throws -> Batch {
        guard data.count <= Self.maxBatchBytes else { throw CocoaError(.fileReadTooLarge) }
        let batch = try decoder.decode(Batch.self, from: data)
        let iso = ISO8601DateFormatter()
        iso.formatOptions.insert(.withFractionalSeconds)
        let plainISO = ISO8601DateFormatter()
        guard batch.version == 1, UUID(uuidString: batch.deviceID) != nil,
              !batch.deviceName.isEmpty, batch.deviceName.count <= 80,
              batch.updated.timeIntervalSince1970.isFinite,
              batch.records.allSatisfy({ record in
                  guard record.valid, record.id == CodexUsageRecord.fingerprint(timestamp: record.timestamp, cumulative: record.cumulative, amounts: record.amounts), record.model != "codex-auto-review",
                        let date = iso.date(from: record.timestamp) ?? plainISO.date(from: record.timestamp) else { return false }
                  return abs(date.timeIntervalSince1970 - record.occurredAt) < 0.001
                      && dayFormatter.string(from: date) == batch.day
              }), batch.day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return batch
    }

    private func path(for batch: Batch) -> String { batch.deviceID + "/" + batch.day + ".json" }

    private func joined(_ batch: Batch, with previous: Batch?) -> Batch {
        Batch(version: 1, deviceID: batch.deviceID, deviceName: batch.deviceName, day: batch.day,
              updated: max(previous?.updated ?? .distantPast, batch.updated),
              records: merge((previous?.records ?? []) + batch.records))
    }

    private func cacheBatch(_ batch: Batch) throws {
        let url = cache.appendingPathComponent(path(for: batch))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // CLI 查询和菜单栏进程可能同时写入；在独占访问中合并磁盘上的最新数据。
        try Self.coordinated(url, writing: true) { url in
            let previous = try? self.decode(self.readData(url))
            let combined = self.joined(batch, with: previous.flatMap { self.path(for: $0) == self.path(for: batch) ? $0 : nil })
            let data = try self.encoder.encode(combined)
            guard data.count <= Self.maxBatchBytes else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            self.batches[self.path(for: batch)] = combined
        }
    }

    static func coordinated(_ url: URL, writing: Bool, action: @escaping (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator()
        let timeout = DispatchWorkItem { coordinator.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        var coordinationError: NSError?
        var operationError: Error?
        let accessor: (URL) -> Void = { url in
            do { try action(url) } catch { operationError = error }
        }
        if writing { coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError, byAccessor: accessor) }
        else { coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError, byAccessor: accessor) }
        if let error = operationError ?? coordinationError { throw error }
    }

    private func merge(_ records: [CodexUsageRecord]) -> [CodexUsageRecord] {
        CodexUsageRecord.merged(records, warnings: &warnings)
    }

    private func readData(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxBatchBytes + 1) ?? Data()
        guard data.count <= Self.maxBatchBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    func exchange(local: [CodexUsageRecord], selectedDevice: String? = nil, now: Date = Date()) -> CodexUsageSyncResult {
        let manager = FileManager.default
        if !loaded {
            loaded = true
            if let files = manager.enumerator(at: cache, includingPropertiesForKeys: nil) {
                for case let url as URL in files where url.pathExtension == "json" {
                    if let data = try? readData(url), let batch = try? decode(data) { batches[path(for: batch)] = batch }
                }
            }
        }
        if lastExchange == nil || now < lastExchange! || now.timeIntervalSince(lastExchange!) >= 60 {
            lastExchange = now
            warnings = []
            var cloudBatches: [String: Batch] = [:]
            var cloudAvailable = false
            do {
                // CloudDocs 的存在由系统管理；不创建缺失的 iCloud Drive 根目录。
                let drive = cloud.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                guard manager.fileExists(atPath: drive.path) else { throw CocoaError(.fileNoSuchFile) }
                try manager.createDirectory(at: cloud, withIntermediateDirectories: true)
                cloudAvailable = true
                if let files = manager.enumerator(at: cloud, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey],
                                                  options: [.skipsPackageDescendants]) {
                    for case let url as URL in files {
                        if url.pathExtension == "icloud" {
                            let name = String(url.lastPathComponent.dropFirst().dropLast(7))
                            try? manager.startDownloadingUbiquitousItem(at: url.deletingLastPathComponent().appendingPathComponent(name))
                            warnings.insert("部分 iCloud 文件等待下载，暂用缓存")
                            continue
                        }
                        guard url.pathExtension == "json" else { continue }
                        do {
                            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .contentModificationDateKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemIsUploadedKey])
                            if values.ubiquitousItemUploadingError != nil || values.ubiquitousItemDownloadingError != nil {
                                warnings.insert("部分 iCloud 文件传输失败，暂用本机缓存")
                            } else if values.isUbiquitousItem == true && values.ubiquitousItemIsUploaded == false {
                                warnings.insert("部分用量等待 iCloud 上传，其他设备可能尚未收到")
                            }
                            if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                                try manager.startDownloadingUbiquitousItem(at: url)
                                warnings.insert("部分 iCloud 文件等待下载，暂用缓存")
                                continue
                            }
                            if values.ubiquitousItemDownloadingStatus == .downloaded { try? manager.startDownloadingUbiquitousItem(at: url) }
                            let version = "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? -1)"
                            if cloudVersions[url] == version, let copy = cloudCopies[url] {
                                cloudBatches[path(for: copy)] = copy
                                continue
                            }
                            try Self.coordinated(url, writing: false) { coordinatedURL in
                                let data = try self.readData(coordinatedURL)
                                let batch = try self.decode(data)
                                cloudBatches[self.path(for: batch)] = batch
                                self.cloudVersions[url] = version
                                self.cloudCopies[url] = batch
                                let previous = self.batches[self.path(for: batch)]
                                try self.cacheBatch(self.joined(batch, with: previous))
                            }
                        } catch { warnings.insert("部分 iCloud 文件未能读取，保留上次缓存") }
                    }
                }
            } catch { warnings.insert("iCloud 暂不可用，保留本机及已缓存的其他设备用量") }
            let own = merge(batches.values.filter { $0.deviceID == deviceID }.flatMap(\.records) + local)
            for (day, records) in Dictionary(grouping: own, by: { dayFormatter.string(from: Date(timeIntervalSince1970: $0.occurredAt)) }) {
                let key = deviceID + "/" + day + ".json"
                do {
                    let old = batches[key]
                    let changed = old?.records != records || old?.deviceName != deviceName
                    let batch = Batch(version: 1, deviceID: deviceID, deviceName: deviceName, day: day,
                                      updated: changed ? now : old!.updated, records: records)
                    if changed { try cacheBatch(batch) }
                    guard cloudAvailable else { continue }
                    var outgoing = batches[key] ?? batch
                    if let remote = cloudBatches[key], remote.records == outgoing.records, remote.deviceName == deviceName { continue }
                    let url = cloud.appendingPathComponent(key)
                    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.coordinated(url, writing: true) { url in
                        let previous = try? self.decode(self.readData(url))
                        outgoing = self.joined(outgoing, with: previous.flatMap { self.path(for: $0) == key ? $0 : nil })
                        let data = try self.encoder.encode(outgoing)
                        guard data.count <= Self.maxBatchBytes else { throw CocoaError(.fileWriteUnknown) }
                        try data.write(to: url, options: .atomic)
                    }
                    try cacheBatch(outgoing)
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    cloudVersions[url] = "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? -1)"
                    cloudCopies[url] = outgoing
                } catch { warnings.insert("部分用量尚未写入 iCloud，下次自动重试") }
            }
        }
        var records = batches.values.filter { selectedDevice == nil || $0.deviceID == selectedDevice }.flatMap(\.records)
        if selectedDevice == nil || selectedDevice == deviceID { records += local }
        let result = merge(records)
        var devices = Dictionary(grouping: Array(batches.values), by: \.deviceID).map { id, values in
            let latest = values.max { $0.updated < $1.updated }!
            return CodexUsageDevice(id: id, name: latest.deviceName, updated: latest.updated)
        }
        if !devices.contains(where: { $0.id == deviceID }) { devices.append(CodexUsageDevice(id: deviceID, name: deviceName, updated: nil)) }
        let message = Array(Set(warnings)).sorted().joined(separator: "；")
        return CodexUsageSyncResult(records: result, devices: devices.sorted { $0.name < $1.name },
                                   message: message.isEmpty ? "iCloud · 已读取 \(devices.count) 台设备的数据" : "⚠ " + message)
    }
}
