import Foundation

// Trae 账号池与 WorkBuddy 池使用不同的本地 plist，切号互不影响。

struct TraeAccountSummary {
    let id: String
    let name: String
    let preferred: Bool
}

struct TraeAccountContext {
    let id: String
    let name: String
    let uid: String
    let accessToken: String
    let refreshToken: String?
}

struct TraeAccountRecord: Codable {
    let id: String
    var name: String
    var addedAt: Date
    var lastUsedAt: Date?
    fileprivate var secret: TraeAccountSecret? = nil
}

private struct TraeAccountConfiguration: Codable {
    var version = 1
    var preferredAccountID: String?
    var accounts: [TraeAccountRecord] = []
}

fileprivate struct TraeAccountSecret: Codable {
    var accessToken: String
    var refreshToken: String?
}

// 幂等导入：同 userId 只覆盖展示名，返回是否新增账号。
@discardableResult
func traeAccountUpsert(_ records: inout [TraeAccountRecord], id: String, name: String,
                       now: Date = Date()) -> Bool {
    if let index = records.firstIndex(where: { $0.id == id }) {
        records[index].name = name
        return false
    }
    records.append(TraeAccountRecord(id: id, name: name, addedAt: now, lastUsedAt: nil))
    return true
}

// 取用顺序：首选账号最前，其余按 lastUsedAt 从旧到新（未用过的最靠前）。
func traeAccountOrder(_ records: [TraeAccountRecord], preferred: String?) -> [TraeAccountRecord] {
    records.sorted {
        if ($0.id == preferred) != ($1.id == preferred) { return $0.id == preferred }
        return ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast)
    }
}

final class TraeAccountPool {
    private let queue = DispatchQueue(label: "local.codex-helper.trae.accounts")
    private let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Helper", isDirectory: true)
    private lazy var configurationURL = directoryURL.appendingPathComponent("trae-accounts.plist")
    private var configuration: TraeAccountConfiguration

    init() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Helper/trae-accounts.plist")
        configuration = (try? PropertyListDecoder().decode(TraeAccountConfiguration.self,
                                                           from: Data(contentsOf: url))) ?? .init()
    }

    var summaries: [TraeAccountSummary] {
        queue.sync {
            configuration.accounts.map {
                TraeAccountSummary(id: $0.id, name: $0.name,
                                   preferred: $0.id == configuration.preferredAccountID)
            }
        }
    }

    @discardableResult
    func importCurrentAccount() throws -> TraeAccountSummary {
        let auth = try traeLocalAuth()
        guard !auth.uid.isEmpty else { throw TraeError.message("Trae 登录态缺少 userId，请重新登录 Trae") }
        try queue.sync {
            traeAccountUpsert(&configuration.accounts, id: auth.uid, name: auth.displayName)
            configuration.accounts[configuration.accounts.firstIndex(where: { $0.id == auth.uid })!].secret =
                TraeAccountSecret(accessToken: auth.token, refreshToken: auth.refreshToken)
            configuration.preferredAccountID = auth.uid
            try saveConfiguration()
        }
        return TraeAccountSummary(id: auth.uid, name: auth.displayName, preferred: true)
    }

    // 池为空时先导入当前本机登录，避免首次使用还要手动点一次。
    func contexts() throws -> [TraeAccountContext] {
        if summaries.isEmpty { _ = try importCurrentAccount() }
        return try queue.sync {
            let ordered = traeAccountOrder(configuration.accounts,
                                           preferred: configuration.preferredAccountID)
            let local = try? traeLocalAuth()
            var contexts: [TraeAccountContext] = []
            var importedLocal = false
            for record in ordered {
                let secret = record.secret ?? local.flatMap {
                    $0.uid == record.id ? TraeAccountSecret(accessToken: $0.token, refreshToken: $0.refreshToken) : nil
                }
                guard let secret else { continue }
                if record.secret == nil,
                   let index = configuration.accounts.firstIndex(where: { $0.id == record.id }) {
                    configuration.accounts[index].secret = secret
                    importedLocal = true
                }
                contexts.append(TraeAccountContext(id: record.id, name: record.name, uid: record.id,
                                                   accessToken: secret.accessToken,
                                                   refreshToken: secret.refreshToken))
            }
            if importedLocal { try saveConfiguration() }
            guard !contexts.isEmpty else { throw TraeError.message("Trae 账号本地凭据不可用，请重新保存当前账号") }
            return contexts
        }
    }

    func prefer(_ id: String) throws {
        try queue.sync {
            guard configuration.accounts.contains(where: { $0.id == id }) else { return }
            configuration.preferredAccountID = id
            try saveConfiguration()
        }
    }

    func markUsed(accountID: String) {
        try? queue.sync {
            guard let index = configuration.accounts.firstIndex(where: { $0.id == accountID }) else { return }
            configuration.accounts[index].lastUsedAt = Date()
            configuration.preferredAccountID = accountID
            try saveConfiguration()
        }
    }

    private func saveConfiguration() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try PropertyListEncoder().encode(configuration)
        try data.write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
    }

    // 纯逻辑自检：不读写 plist，也不触碰 58100。
    static func selfTest() {
        var records: [TraeAccountRecord] = []
        precondition(traeAccountUpsert(&records, id: "u1", name: "用户A"))
        precondition(!traeAccountUpsert(&records, id: "u1", name: "用户A 改名"))
        precondition(records.count == 1 && records[0].name == "用户A 改名")
        precondition(traeAccountUpsert(&records, id: "u2", name: "用户B"))
        precondition(records.count == 2)

        records[0].lastUsedAt = Date(timeIntervalSince1970: 200)
        records[1].lastUsedAt = Date(timeIntervalSince1970: 100)
        // 无首选时按 lastUsedAt 从旧到新。
        precondition(traeAccountOrder(records, preferred: nil).map(\.id) == ["u2", "u1"])
        // 首选账号永远排最前，即使更晚用过。
        precondition(traeAccountOrder(records, preferred: "u1").map(\.id) == ["u1", "u2"])
        // 未用过的账号（lastUsedAt 为 nil）排在已用过的之前。
        var fresh: [TraeAccountRecord] = []
        traeAccountUpsert(&fresh, id: "u3", name: "用户C")
        precondition(fresh[0].lastUsedAt == nil)
        precondition(traeAccountOrder(records + fresh, preferred: nil).map(\.id) == ["u3", "u2", "u1"])
        records[0].secret = TraeAccountSecret(accessToken: "token", refreshToken: "refresh")
        let decoded = try! PropertyListDecoder().decode([TraeAccountRecord].self,
                                                        from: PropertyListEncoder().encode(records + fresh))
        precondition(decoded[0].secret?.accessToken == "token" && decoded[2].secret == nil)
    }
}
