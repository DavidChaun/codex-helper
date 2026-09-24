import Foundation

let workBuddyCLIPath = "/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy"
let workBuddyLiveSessionURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info")
let workBuddyProductURL = URL(fileURLWithPath: workBuddyCLIPath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("product.json")
var workBuddyCLIInstalled: Bool { FileManager.default.isExecutableFile(atPath: workBuddyCLIPath) }

struct WorkBuddyAccountSummary {
    let id: String
    let name: String
    let preferred: Bool
    let enabled: Bool
    let remaining: Double?
    let limitedModelCount: Int
    let nearestCooldownEnd: Date?
}

struct WorkBuddyAccountContext {
    let id: String
    let name: String
    let userID: String
    let domain: String?
    let enterpriseID: String?
    let accessToken: String
    let refreshToken: String?
}

private struct WorkBuddyAccountRecord: Codable {
    let id: String
    var name: String
    let userID: String
    let domain: String?
    let enterpriseID: String?
    var enabled: Bool
    var addedAt: Date
    var lastUsedAt: Date?
    var cooldowns: [String: Date]
    var rotationLastBalance: Double?
    var rotationCredits: Double?
    var lastModel: String?
    var secret: WorkBuddyAccountSecret?
}

private struct WorkBuddyAccountConfiguration: Codable {
    var version = 1
    var preferredAccountID: String?
    var accounts: [WorkBuddyAccountRecord] = []
}

private struct WorkBuddyAccountSecret: Codable {
    var accessToken: String
    var refreshToken: String?
}

private func upsertWorkBuddyAccount(_ account: WorkBuddyAccountRecord,
                                    in accounts: inout [WorkBuddyAccountRecord]) {
    accounts.removeAll { $0.id == account.id || $0.name == account.name }
    accounts.append(account)
}

final class WorkBuddyAccountPool {
    private let queue = DispatchQueue(label: "local.codex-helper.workbuddy.accounts")
    private let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Helper", isDirectory: true)
    private lazy var configurationURL = directoryURL.appendingPathComponent("wb-accounts.plist")
    private var configuration: WorkBuddyAccountConfiguration

    init() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Helper/wb-accounts.plist")
        configuration = (try? PropertyListDecoder().decode(WorkBuddyAccountConfiguration.self,
                                                            from: Data(contentsOf: url))) ?? .init()
    }

    var summaries: [WorkBuddyAccountSummary] {
        queue.sync {
            let now = Date()
            return configuration.accounts.map {
                let activeCooldowns = $0.cooldowns.values.filter { $0 > now }
                return WorkBuddyAccountSummary(id: $0.id, name: $0.name,
                                               preferred: $0.id == configuration.preferredAccountID,
                                               enabled: $0.enabled, remaining: $0.rotationLastBalance,
                                               limitedModelCount: activeCooldowns.count,
                                               nearestCooldownEnd: activeCooldowns.min())
            }
        }
    }

    @discardableResult
    func importCurrentAccount() throws -> WorkBuddyAccountSummary {
        guard let session = try JSONSerialization.jsonObject(with: Data(contentsOf: workBuddyLiveSessionURL)) as? [String: Any],
              let auth = session["auth"] as? [String: Any],
              let account = session["account"] as? [String: Any],
              let accessToken = scalarText(auth["accessToken"]),
              let userID = scalarText(account["uid"] ?? account["uin"] ?? account["oneidAccountId"]) else {
            throw WorkBuddyError.message("未检测到有效的 WorkBuddy 登录会话")
        }
        let domain = scalarText(auth["domain"])
        let id = (domain ?? "default") + ":" + userID
        let suffix = String(userID.suffix(4))
        let name = scalarText(account["nickname"]) ?? "WorkBuddy ···\(suffix)"
        let enterpriseID = scalarText(account["enterpriseId"] ?? account["enterprise_id"])
        let secret = WorkBuddyAccountSecret(accessToken: accessToken, refreshToken: scalarText(auth["refreshToken"]))
        try queue.sync {
            upsertWorkBuddyAccount(.init(id: id, name: name, userID: userID, domain: domain,
                                         enterpriseID: enterpriseID, enabled: true, addedAt: Date(),
                                         lastUsedAt: nil, cooldowns: [:], rotationLastBalance: nil,
                                         rotationCredits: 0, lastModel: nil, secret: secret),
                                   in: &configuration.accounts)
            configuration.preferredAccountID = id
            try saveConfiguration()
        }
        return .init(id: id, name: name, preferred: true, enabled: true, remaining: nil,
                     limitedModelCount: 0, nearestCooldownEnd: nil)
    }

    func contexts(for model: String?) throws -> [WorkBuddyAccountContext] {
        if summaries.isEmpty || !queue.sync(execute: { configuration.accounts.contains { $0.secret != nil } }) {
            _ = try importCurrentAccount()
        }
        return try queue.sync {
            let now = Date()
            let available = configuration.accounts.filter { account in
                account.enabled && (model.flatMap { account.cooldowns[$0] }.map { $0 <= now } ?? true)
            }.sorted {
                if $0.id == configuration.preferredAccountID { return true }
                if $1.id == configuration.preferredAccountID { return false }
                return ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast)
            }
            if available.isEmpty {
                throw WorkBuddyError.message(model == nil ? "没有可用的 WorkBuddy 账号" : "所有 WorkBuddy 账号均在该模型的冷却期")
            }
            var contexts: [WorkBuddyAccountContext] = []
            for record in available {
                guard let secret = record.secret else { continue }
                contexts.append(WorkBuddyAccountContext(id: record.id, name: record.name, userID: record.userID,
                                                        domain: record.domain, enterpriseID: record.enterpriseID,
                                                        accessToken: secret.accessToken, refreshToken: secret.refreshToken))
            }
            guard !contexts.isEmpty else { throw WorkBuddyError.message("WorkBuddy 账号本地凭据不可用，请重新保存当前账号") }
            return contexts
        }
    }

    func prefer(_ id: String) throws {
        try queue.sync {
            guard let index = configuration.accounts.firstIndex(where: { $0.id == id }) else { return }
            configuration.preferredAccountID = id
            configuration.accounts[index].rotationLastBalance = nil
            configuration.accounts[index].rotationCredits = 0
            try saveConfiguration()
        }
    }

    func markSuccess(accountID: String, model: String) {
        try? queue.sync {
            guard let index = configuration.accounts.firstIndex(where: { $0.id == accountID }) else { return }
            configuration.accounts[index].lastUsedAt = Date()
            configuration.accounts[index].lastModel = model
            configuration.preferredAccountID = accountID
            try saveConfiguration()
        }
    }

    @discardableResult
    func recordBalances(_ balances: [String: Double]) -> String? {
        queue.sync {
            guard let currentID = configuration.preferredAccountID,
                  let currentIndex = configuration.accounts.firstIndex(where: { $0.id == currentID }),
                  let currentBalance = balances[currentID] else { return nil }
            let previous = configuration.accounts[currentIndex].rotationLastBalance
            configuration.accounts[currentIndex].rotationCredits = workBuddyRotationCredits(
                previousBalance: previous, currentBalance: currentBalance,
                accumulated: configuration.accounts[currentIndex].rotationCredits ?? 0)
            for index in configuration.accounts.indices {
                if let balance = balances[configuration.accounts[index].id] {
                    configuration.accounts[index].rotationLastBalance = balance
                }
            }
            guard configuration.accounts[currentIndex].rotationCredits ?? 0 >= 100,
                  let model = configuration.accounts[currentIndex].lastModel else {
                try? saveConfiguration()
                return nil
            }
            let now = Date()
            let nextIndex = (1..<configuration.accounts.count).lazy
                .map { (currentIndex + $0) % self.configuration.accounts.count }
                .first { index in
                    let account = self.configuration.accounts[index]
                    return account.enabled && (account.cooldowns[model].map { $0 <= now } ?? true) &&
                        account.secret != nil
                }
            guard let nextIndex else {
                try? saveConfiguration()
                return nil
            }
            configuration.accounts[currentIndex].rotationCredits = 0
            configuration.accounts[nextIndex].rotationCredits = 0
            configuration.preferredAccountID = configuration.accounts[nextIndex].id
            try? saveConfiguration()
            return configuration.accounts[nextIndex].id
        }
    }

    func markRateLimited(accountID: String, model: String, until: Date) {
        try? queue.sync {
            guard let index = configuration.accounts.firstIndex(where: { $0.id == accountID }) else { return }
            configuration.accounts[index].cooldowns[model] = until
            if configuration.preferredAccountID == accountID { configuration.preferredAccountID = nil }
            try saveConfiguration()
        }
    }

    func updateTokens(accountID: String, accessToken: String, refreshToken: String?) throws -> WorkBuddyAccountContext {
        try queue.sync {
            guard let index = configuration.accounts.firstIndex(where: { $0.id == accountID }) else {
                throw WorkBuddyError.message("刷新后的 WorkBuddy 账号不可用")
            }
            let secret = WorkBuddyAccountSecret(accessToken: accessToken, refreshToken: refreshToken)
            configuration.accounts[index].secret = secret
            try saveConfiguration()
            let record = configuration.accounts[index]
            return WorkBuddyAccountContext(id: record.id, name: record.name, userID: record.userID,
                                           domain: record.domain, enterpriseID: record.enterpriseID,
                                           accessToken: secret.accessToken, refreshToken: secret.refreshToken)
        }
    }

    private func saveConfiguration() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try PropertyListEncoder().encode(configuration)
        try data.write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
    }

    static func selfTest() {
        let records = [WorkBuddyAccountRecord(id: "a", name: "A", userID: "u", domain: nil,
                                               enterpriseID: nil, enabled: true, addedAt: .distantPast,
                                               lastUsedAt: nil, cooldowns: [:], rotationLastBalance: nil,
                                               rotationCredits: nil, lastModel: nil,
                                               secret: .init(accessToken: "token", refreshToken: "refresh")),
                       WorkBuddyAccountRecord(id: "b", name: "B", userID: "u2", domain: nil,
                                               enterpriseID: nil, enabled: true, addedAt: .distantPast,
                                               lastUsedAt: nil, cooldowns: [:], rotationLastBalance: nil,
                                               rotationCredits: nil, lastModel: nil, secret: nil)]
        let decoded = try! PropertyListDecoder().decode([WorkBuddyAccountRecord].self,
                                                        from: PropertyListEncoder().encode(records))
        precondition(decoded[0].secret?.accessToken == "token" && decoded[1].secret == nil)

        var duplicates = records
        upsertWorkBuddyAccount(.init(id: "c", name: "B", userID: "u3", domain: nil,
                                     enterpriseID: nil, enabled: true, addedAt: .distantPast,
                                     lastUsedAt: nil, cooldowns: [:], rotationLastBalance: nil,
                                     rotationCredits: nil, lastModel: nil,
                                     secret: .init(accessToken: "new", refreshToken: nil)),
                               in: &duplicates)
        precondition(duplicates.map(\.id) == ["a", "c"] && duplicates.last?.secret?.accessToken == "new")
    }

}

func workBuddyRotationCredits(previousBalance: Double?, currentBalance: Double,
                              accumulated: Double) -> Double {
    accumulated + max(0, (previousBalance ?? currentBalance) - currentBalance)
}

private func scalarText(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    let result = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
}
