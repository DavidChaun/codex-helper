import AppKit
import Darwin
import Sparkle
import UniformTypeIdentifiers

let codexInstallCommand = "brew install --cask codex"
let openCodexInstallCommand = "brew install node && npm install -g @bitkyc08/opencodex && ocx setup"
let workBuddyInstallURL = "https://copilot.tencent.com/cli"

struct Window: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Int { Int(max(0, min(100, 100 - usedPercent)).rounded(.down)) }
    var label: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "额度" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)天" }
        if minutes % 60 == 0 { return "\(minutes / 60)小时" }
        return "\(minutes)分钟"
    }
    var shortLabel: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "余" }
        if minutes % 10080 == 0 { return "\(minutes / 10080)w" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

struct Bucket: Decodable {
    let limitName: String?
    let primary: Window?
    let secondary: Window?
    let planType: String?
    var windows: [Window] { [primary, secondary].compactMap { $0 } }
}

struct Quota: Decodable {
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?
    var buckets: [(String, Bucket)] {
        if let all = rateLimitsByLimitId, !all.isEmpty {
            return all.keys.sorted { ($0 == "codex" ? "" : $0) < ($1 == "codex" ? "" : $1) }
                .map { ($0, all[$0]!) }
        }
        return rateLimits.map { [("codex", $0)] } ?? []
    }
    var title: String {
        guard let first = buckets.first, !first.1.windows.isEmpty else { return "额度暂无" }
        return first.1.windows.map { "\($0.shortLabel): \($0.remaining)%" }.joined(separator: " · ")
    }
}

enum QueryError: String, Error {
    case missingCLI = "未找到 Codex CLI，请安装后重试"
    case launch = "无法启动 Codex CLI"
    case handshake = "Codex 初始化失败，请检查 CLI 登录状态"
    case request = "无法读取额度，请确认 Codex 已使用 ChatGPT 账户登录"
    case response = "Codex 返回了无法识别的额度数据"
    case timeout = "读取超时，请检查网络后重试"
}

func executable(named name: String) -> String? {
    let paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
    return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
}

func codexExecutable() -> String? {
    let native = ["/opt/homebrew/bin/codex.opencodex-real", "/usr/local/bin/codex.opencodex-real"]
    return native.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? executable(named: "codex")
}

func workBuddyOcxConfigurationCommands(firstConfiguration: Bool) -> [[String]] {
    var commands = [
        ["provider", "add", "workbuddy", "--adapter", "openai-chat",
         "--base-url", "http://127.0.0.1:\(WorkBuddyProxy.port)\(workBuddyAPIPrefix)",
         "--api-key", workBuddyAPIKey,
         "--allow-private-network", "--force"],
        ["restart"],
        ["restore", "back"]
    ]
    if firstConfiguration {
        commands += [["sync"], ["models", "provider", "workbuddy", "on"]]
    }
    commands.append(["sync", "--restart-codex"])
    return commands
}

func traeOcxConfigurationCommands(firstConfiguration: Bool) -> [[String]] {
    var commands = [
        ["provider", "add", "trae", "--adapter", "openai-chat",
         "--base-url", "http://127.0.0.1:\(WorkBuddyProxy.port)\(traeAPIPrefix)", "--api-key", TraeClient.apiKey,
         "--allow-private-network", "--force"],
        ["restart"],
        ["restore", "back"]
    ]
    if firstConfiguration {
        commands += [["sync"], ["models", "provider", "trae", "on"]]
    }
    commands.append(["sync", "--restart-codex"])
    return commands
}

func workBuddyCurlExample(model: String) -> String {
    let body = String(data: try! workBuddyJSONData([
        "model": model, "messages": [["role": "user", "content": "Hello"]], "stream": true
    ]), encoding: .utf8)!.replacingOccurrences(of: "'", with: "'\\''")
    return [
        "curl -N http://127.0.0.1:\(WorkBuddyProxy.port)\(workBuddyAPIPrefix)/chat/completions \\",
        "  -H 'Authorization: Bearer \(workBuddyAPIKey)' \\",
        "  -H 'Content-Type: application/json' \\",
        "  -d '\(body)'"
    ].joined(separator: "\n")
}

func traeCurlExample(model: String) -> String {
    let body = String(data: try! workBuddyJSONData([
        "model": model, "messages": [["role": "user", "content": "Hello"]], "stream": true
    ]), encoding: .utf8)!.replacingOccurrences(of: "'", with: "'\\''")
    return [
        "curl -N http://127.0.0.1:\(WorkBuddyProxy.port)\(traeAPIPrefix)/chat/completions \\",
        "  -H 'Authorization: Bearer \(TraeClient.apiKey)' \\",
        "  -H 'Content-Type: application/json' \\",
        "  -d '\(body)'"
    ].joined(separator: "\n")
}

func shouldAutoCheckinWorkBuddy(_ state: WorkBuddyAccountState, lastAttempt: Double?, now: Date = Date()) -> Bool {
    let attemptedToday = lastAttempt.map {
        Calendar.current.isDate(Date(timeIntervalSince1970: $0), inSameDayAs: now)
    } ?? false
    return state.checkinActive && !state.checkedIn && !attemptedToday
}

func shouldAutoCheckinTrae(_ state: TraeCheckinState, lastAttempt: Double?, now: Date = Date()) -> Bool {
    let recentlyAttempted = lastAttempt.map { now.timeIntervalSince1970 - $0 < 600 } ?? false
    return state.checkinActive && !state.checkedIn && !state.didCheckedIn && !recentlyAttempted
}

func runCommand(_ name: String, _ arguments: [String], timeout: TimeInterval? = nil) throws -> String {
    guard let path = executable(named: name) else { throw QueryError.missingCLI }
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
    process.environment = environment
    try process.run()
    var timeoutTask: DispatchWorkItem?
    if let timeout {
        let task = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        timeoutTask = task
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: task)
    }
    defer { timeoutTask?.cancel() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "CodexQuotaBar", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
    }
    return text
}

func readQuota() throws -> Quota {
    guard let executable = codexExecutable()
    else { throw QueryError.missingCLI }
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["app-server", "-c", "analytics.enabled=false"]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
    process.environment = environment
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { throw QueryError.launch }
    let deadline = Date().addingTimeInterval(30)
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    defer {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
    }
    func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_quota_bar", "version": "1.0.0"]]])
    var buffer = Data()
    var bytes = [UInt8](repeating: 0, count: 65536)
    while true {
        // Read each available RPC chunk without waiting for a full 64 KB buffer.
        let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
        if count < 0, errno == EINTR { continue }
        if count <= 0 { break }
        buffer.append(contentsOf: bytes.prefix(count))
        guard buffer.count < 2_000_000 else { throw QueryError.response }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            guard let id = reply["id"] as? Int else { continue }
            if id == 1 {
                guard reply["error"] == nil else { throw QueryError.handshake }
                try send(["method": "initialized", "params": [:]])
                try send(["id": 2, "method": "account/rateLimits/read"])
            } else if id == 2 {
                guard reply["error"] == nil, let result = reply["result"] else { throw QueryError.request }
                return try JSONDecoder().decode(Quota.self, from: JSONSerialization.data(withJSONObject: result))
            }
        }
    }
    throw Date() >= deadline ? QueryError.timeout : QueryError.request
}

func quotaRow(_ window: Window, stale: Bool) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 312, height: 76))
    let title = NSTextField(labelWithString: "\(window.label)额度")
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.frame = NSRect(x: 18, y: 51, width: 145, height: 18)
    let value = NSTextField(labelWithString: "剩余 \(window.remaining)%")
    value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    value.alignment = .right
    value.frame = NSRect(x: 165, y: 51, width: 129, height: 18)
    value.textColor = stale ? .secondaryLabelColor : window.remaining <= 10 ? .systemRed : .labelColor
    let bar = NSProgressIndicator(frame: NSRect(x: 18, y: 32, width: 276, height: 10))
    bar.isIndeterminate = false
    bar.minValue = 0
    bar.maxValue = 100
    bar.doubleValue = Double(window.remaining)
    bar.style = .bar
    bar.setAccessibilityLabel("\(window.label)额度剩余百分比")
    let reset: String
    if let timestamp = window.resetsAt {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        reset = "\(formatter.string(from: Date(timeIntervalSince1970: timestamp))) 重置"
    } else { reset = "重置时间暂不可用" }
    let subtitle = NSTextField(labelWithString: reset)
    subtitle.font = .systemFont(ofSize: 11)
    subtitle.textColor = .secondaryLabelColor
    subtitle.frame = NSRect(x: 18, y: 9, width: 276, height: 17)
    [title, value, bar, subtitle].forEach { view.addSubview($0) }
    return view
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: nil)
    let workBuddyAccounts = WorkBuddyAccountPool()
    lazy var workBuddyClient = WorkBuddyClient(accounts: workBuddyAccounts)
    let traeAccounts = TraeAccountPool()
    lazy var traeClient = TraeClient(accounts: traeAccounts)
    lazy var workBuddyProxy = WorkBuddyProxy(client: workBuddyClient, traeClient: traeClient)
    var status: NSStatusItem!
    var quota: Quota?
    var updated: Date?
    var error: String?
    var refreshing = false
    var timer: Timer?
    var workBuddyTimer: Timer?
    var traeTimer: Timer?
    var settingsWindow: NSWindow?
    var intervalField: NSTextField?
    var workBuddyEnabledButton: NSButton?
    var traeEnabledButton: NSButton?
    var settingsSaveButton: NSButton?
    var ocxStatusText = "OpenCodex Checking…"
    var ocxStatusItem: NSMenuItem?
    var ocxActionItems: [NSMenuItem] = []
    var ocxWorkBuddyConfigItem: NSMenuItem?
    var ocxTraeConfigItem: NSMenuItem?
    var ocxBusy = false
    var ocxChecking = false
    var workBuddyState: WorkBuddyAccountState?
    var workBuddyModels: [WorkBuddyModel] = []
    var workBuddyError: String?
    var workBuddyBusy = false
    var traeModels: [TraeModel] = []
    var traeState: TraeCheckinState?
    var traeCreditsByAccount: [String: TraeCredits] = [:]
    var traeError: String?
    var traeBusy = false
    var workBuddyEnabled: Bool {
        UserDefaults.standard.object(forKey: "workBuddyEnabled") as? Bool ?? true
    }
    var traeEnabled: Bool {
        UserDefaults.standard.object(forKey: "traeEnabled") as? Bool ?? true
    }
    // 两条路由各自判断：开的那个能用就起 listener，两个都不可用才停。
    var workBuddyRouteAvailable: Bool { workBuddyEnabled && workBuddyCLIInstalled }
    // 池里已有账号时，即使本机 storage.json 不在也仍可服务（Token 已保存在账号池）。
    var traeRouteAvailable: Bool {
        traeEnabled && (traeInstalled || traeLoggedIn || !traeAccounts.summaries.isEmpty)
    }
    var autoCheckin: Bool {
        UserDefaults.standard.bool(forKey: "workBuddyAutoCheckin")
    }
    var traeAutoCheckin: Bool {
        UserDefaults.standard.bool(forKey: "traeAutoCheckin")
    }
    var refreshInterval: TimeInterval {
        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        return saved == 0 ? 10 : min(3600, max(5, saved))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.cell?.wraps = true
        status.button?.cell?.usesSingleLineMode = false
        applyProxyRouteState()
        refreshAll()
        refreshOcxStatus()
        resetTimer()
        resetWorkBuddyTimer()
        resetTraeTimer()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workBuddyWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(traeWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        workBuddyTimer?.invalidate()
        traeTimer?.invalidate()
        workBuddyProxy.stop()
    }

    // 路由开关与 listener 生命周期绑定；任一上游可用就保持 listener。
    func applyProxyRouteState() {
        try? workBuddyProxy.setWorkBuddyRunning(workBuddyRouteAvailable)
        try? workBuddyProxy.setTraeRunning(traeRouteAvailable)
    }

    func resetTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: refreshInterval, target: self, selector: #selector(refreshAll), userInfo: nil, repeats: true)
    }

    @objc func refreshAll() {
        refresh()
        if workBuddyEnabled { refreshWorkBuddy(autoClaim: true) }
        if traeEnabled { refreshTrae(autoClaim: true) }
    }

    func resetWorkBuddyTimer() {
        workBuddyTimer?.invalidate()
        workBuddyTimer = nil
        guard workBuddyEnabled, autoCheckin else { return }
        guard let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 5), matchingPolicy: .nextTime) else { return }
        workBuddyTimer = Timer(fireAt: next, interval: 0, target: self, selector: #selector(scheduledWorkBuddyCheckin), userInfo: nil, repeats: false)
        RunLoop.main.add(workBuddyTimer!, forMode: .common)
    }

    @objc func scheduledWorkBuddyCheckin() {
        refreshWorkBuddy(autoClaim: true)
        resetWorkBuddyTimer()
    }

    func resetTraeTimer() {
        traeTimer?.invalidate()
        traeTimer = nil
        guard traeEnabled, traeAutoCheckin,
              let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 5),
                                                   matchingPolicy: .nextTime) else { return }
        traeTimer = Timer(fireAt: next, interval: 0, target: self,
                          selector: #selector(scheduledTraeCheckin), userInfo: nil, repeats: false)
        RunLoop.main.add(traeTimer!, forMode: .common)
    }

    @objc func refreshTraeNow() { refreshTrae() }

    @objc func scheduledTraeCheckin() {
        refreshTrae(autoClaim: true)
        resetTraeTimer()
    }

    func refreshTrae(autoClaim: Bool = false) {
        guard traeEnabled, !traeBusy else { return }
        guard traeRouteAvailable else {
            traeError = "未检测到 Trae 登录态，请先登录 TRAE SOLO CN"
            render()
            return
        }
        traeBusy = true
        render()
        let shouldAutoClaim = autoClaim && traeAutoCheckin
        DispatchQueue.global(qos: .utility).async {
            let models = try? self.traeClient.models()
            let snapshot: (TraeCheckinState?, [String: TraeCredits], Error?) = {
                do {
                    if self.traeAccounts.summaries.isEmpty { _ = try self.traeAccounts.importCurrentAccount() }
                } catch { return (nil, [:], error) }
                var attempts = (UserDefaults.standard.dictionary(forKey: "traeLastAutoCheckins") ?? [:])
                    .compactMapValues { ($0 as? NSNumber)?.doubleValue }
                var states: [String: TraeCheckinState] = [:]
                var credits: [String: TraeCredits] = [:]
                var lastError: Error?
                for account in self.traeAccounts.summaries {
                    do {
                        var state = try self.traeClient.checkinStatus(accountID: account.id)
                        if shouldAutoClaim && shouldAutoCheckinTrae(state, lastAttempt: attempts[account.id]) {
                            attempts[account.id] = Date().timeIntervalSince1970
                            UserDefaults.standard.set(attempts, forKey: "traeLastAutoCheckins")
                            state = try self.traeClient.claimCheckin(accountID: account.id)
                        }
                        states[account.id] = state
                    } catch { lastError = error }
                    if let value = try? self.traeClient.credits(accountID: account.id) {
                        credits[account.id] = value
                    }
                }
                let preferredID = self.traeAccounts.summaries.first(where: { $0.preferred })?.id
                return (preferredID.flatMap { states[$0] } ?? states.values.first, credits, lastError)
            }()
            DispatchQueue.main.async {
                self.traeBusy = false
                if let models { self.traeModels = models }
                self.traeCreditsByAccount = snapshot.1
                if let state = snapshot.0 {
                    self.traeState = state
                    self.traeError = nil
                } else {
                    self.traeError = snapshot.2?.localizedDescription ?? "没有可用的 Trae 账号"
                }
                self.render()
            }
        }
    }

    @objc func workBuddyWake() {
        refreshWorkBuddy(autoClaim: true)
        resetWorkBuddyTimer()
    }

    @objc func traeWake() {
        refreshTrae(autoClaim: true)
        resetTraeTimer()
    }

    @objc func refresh() {
        guard !refreshing else { return }
        refreshing = true
        render()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try readQuota() }
            DispatchQueue.main.async {
                self.refreshing = false
                switch result {
                case .success(let value):
                    self.quota = value
                    self.updated = Date()
                    self.error = nil
                case .failure(let failure):
                    self.error = (failure as? QueryError)?.rawValue ?? QueryError.response.rawValue
                }
                self.render()
            }
        }
    }

    func render() {
        let stale = error != nil || (updated.map { Date().timeIntervalSince($0) > max(30, refreshInterval * 3) } ?? false)
        let title = (stale ? "⚠ " : "") + (quota?.title.replacingOccurrences(of: " · ", with: "\n") ?? (refreshing ? "正在\n读取" : "额度\n不可用"))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 10
        paragraph.maximumLineHeight = 10
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold),
            .baselineOffset: -5,
            .paragraphStyle: paragraph
        ]
        status.length = ceil(title.components(separatedBy: "\n").map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 24) + 4
        status.button?.alignment = .center
        status.button?.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        status.button?.toolTip = "Codex 剩余额度 · 点击查看重置时间" + (stale ? "（上次数据，尚未更新）" : "")
        status.button?.setAccessibilityLabel("Codex 剩余额度 " + (quota?.title ?? "暂不可用"))
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        @discardableResult func info(_ text: String) -> NSMenuItem {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return item
        }
        func installPrompt(_ title: String, copyText: String) {
            let item = NSMenuItem(title: title, action: #selector(copyInstallInstruction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = copyText
            item.toolTip = "点击复制：\(copyText)"
            item.isEnabled = true
            menu.addItem(item)
        }
        let codexInstalled = codexExecutable() != nil
        let ocxInstalled = executable(named: "ocx") != nil
        let workBuddyInstalled = workBuddyCLIInstalled
        if !codexInstalled { installPrompt("⚠ 未检测到 Codex CLI，点击复制安装命令", copyText: codexInstallCommand) }
        if !ocxInstalled { installPrompt("⚠ 未检测到 OpenCodex，点击复制安装命令", copyText: openCodexInstallCommand) }
        if !workBuddyInstalled { installPrompt("⚠ 未检测到 WorkBuddy CLI，点击复制官网地址", copyText: workBuddyInstallURL) }
        if !codexInstalled || !ocxInstalled || !workBuddyInstalled { menu.addItem(.separator()) }
        if let quota = quota, !quota.buckets.isEmpty {
            for (id, bucket) in quota.buckets {
                let name = bucket.limitName ?? (id == "codex" ? "Codex" : id)
                info(name + (bucket.planType.map { " · \($0.capitalized)" } ?? ""))
                if bucket.windows.isEmpty { info("此账户暂无额度窗口数据") }
                for window in bucket.windows {
                    let item = NSMenuItem()
                    item.view = quotaRow(window, stale: stale)
                    menu.addItem(item)
                }
            }
        } else if error == nil {
            info(refreshing ? "正在读取当前登录账户…" : "当前账户暂无额度数据")
        }
        menu.addItem(.separator())
        if let error = error { info("⚠ " + error) }
        if stale, quota != nil { info("显示上次结果，请刷新后确认") }
        if let updated = updated {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            info("更新于 \(formatter.string(from: updated)) · 每\(Int(refreshInterval))秒刷新")
        }
        let refreshItem = NSMenuItem(title: refreshing || workBuddyBusy ? "正在刷新…" : "立即刷新", action: #selector(refreshAll), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !(refreshing && workBuddyBusy)
        menu.addItem(refreshItem)
        menu.addItem(.separator())
    if workBuddyEnabled {
        info("WorkBuddy Proxy " + (workBuddyProxy.isWorkBuddyRunning ? "Running" : "Stop"))
        if let state = workBuddyState, let remaining = state.remaining {
            info("当前账号剩余积分：\(remaining.formatted(.number.precision(.fractionLength(0...2)))) \(state.unit)")
        } else {
            info("当前账号剩余积分：" + (workBuddyError ?? (workBuddyBusy ? "正在读取…" : "暂不可用")))
        }
        let accountSummaries = workBuddyAccounts.summaries
        let accountsItem = NSMenuItem(title: "账号池（\(accountSummaries.count)）", action: nil, keyEquivalent: "")
        let accountsMenu = NSMenu()
        for account in accountSummaries {
            let balance = account.remaining.map {
                $0.formatted(.number.precision(.fractionLength(0...2))) + " 积分"
            } ?? "积分暂不可用"
            let status = account.nearestCooldownEnd.map {
                "限流中（\(account.limitedModelCount) 个模型，最近 \($0.formatted(date: .omitted, time: .shortened)) 恢复）"
            } ?? "可用"
            let item = NSMenuItem(title: "\(account.name) · \(balance) · \(status)",
                                  action: #selector(selectWorkBuddyAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = account.id
            item.state = account.preferred ? .on : .off
            item.isEnabled = account.enabled
            accountsMenu.addItem(item)
        }
        if !accountSummaries.isEmpty { accountsMenu.addItem(.separator()) }
        let importAccount = NSMenuItem(title: "保存当前 WorkBuddy 登录账号", action: #selector(importCurrentWorkBuddyAccount), keyEquivalent: "")
        importAccount.target = self
        accountsMenu.addItem(importAccount)
        accountsItem.submenu = accountsMenu
        menu.addItem(accountsItem)
        let moreItem = NSMenuItem(title: "更多…", action: nil, keyEquivalent: "")
        let moreMenu = NSMenu()
        let proxyEnabled = NSMenuItem(title: "启用代理", action: #selector(toggleWorkBuddyProxy), keyEquivalent: "")
        proxyEnabled.target = self
        proxyEnabled.state = workBuddyProxy.isWorkBuddyRouteEnabled ? .on : .off
        moreMenu.addItem(proxyEnabled)
        func workBuddyInfo(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            moreMenu.addItem(item)
        }
        if let state = workBuddyState {
            workBuddyInfo(state.checkedIn ? "今日已签到 · 连续 \(state.streakDays) 天" : "今日待签到 · +\(state.todayCredit.formatted()) 积分")
        } else { workBuddyInfo("签到状态暂不可用") }
        let modelsItem = NSMenuItem(title: "模型列表（\(workBuddyModels.count)）", action: nil, keyEquivalent: "")
        let modelsMenu = NSMenu()
        for model in workBuddyModels {
            let rate = model.credits.flatMap { $0.isEmpty ? nil : $0 } ?? "未标注倍率"
            let item = NSMenuItem(title: "\(model.name) · \(rate)", action: nil, keyEquivalent: "")
            item.toolTip = model.id
            item.isEnabled = false
            modelsMenu.addItem(item)
        }
        if workBuddyModels.isEmpty {
            let item = NSMenuItem(title: "暂无模型数据", action: nil, keyEquivalent: "")
            item.isEnabled = false
            modelsMenu.addItem(item)
        }
        modelsItem.submenu = modelsMenu
        moreMenu.addItem(modelsItem)
        let curl = NSMenuItem(title: "复制 curl 示例", action: #selector(copyInstallInstruction(_:)), keyEquivalent: "")
        curl.target = self
        curl.representedObject = workBuddyCurlExample(model: workBuddyModels.first(where: { $0.type == "chat" })?.id ?? "glm-5.3")
        moreMenu.addItem(curl)
        let claim = NSMenuItem(title: workBuddyState?.checkedIn == true ? "今日已签到" : "立即签到",
                               action: #selector(claimWorkBuddyCheckin), keyEquivalent: "")
        claim.target = self
        claim.isEnabled = !workBuddyBusy && workBuddyState?.checkedIn != true && workBuddyState?.checkinActive == true
        moreMenu.addItem(claim)
        let automatic = NSMenuItem(title: "每日自动签到", action: #selector(toggleWorkBuddyAutoCheckin), keyEquivalent: "")
        automatic.target = self
        automatic.state = autoCheckin ? .on : .off
        moreMenu.addItem(automatic)
        let workBuddyRefresh = NSMenuItem(title: workBuddyBusy ? "正在刷新…" : "刷新积分与模型", action: #selector(refreshWorkBuddyNow), keyEquivalent: "")
        workBuddyRefresh.target = self
        workBuddyRefresh.isEnabled = !workBuddyBusy
        moreMenu.addItem(workBuddyRefresh)
        moreItem.submenu = moreMenu
        menu.addItem(moreItem)
        menu.addItem(.separator())
    }
    if traeEnabled {
        let traeSummaries = traeAccounts.summaries
        let preferredID = traeSummaries.first(where: { $0.preferred })?.id
        let balanceText = preferredID.flatMap { traeCreditsByAccount[$0]?.text } ?? "积分未知"
        info("Trae Proxy " + (workBuddyProxy.isTraeRunning ? "Running" : "Stop"))
        info("当前账号剩余积分：\(balanceText)")
        let traeAccountsItem = NSMenuItem(title: "账号池（\(traeSummaries.count)）", action: nil, keyEquivalent: "")
        let traeAccountsMenu = NSMenu()
        for account in traeSummaries {
            let balance = traeCreditsByAccount[account.id]?.text ?? "积分未知"
            let item = NSMenuItem(title: "\(account.name) · \(balance)",
                                  action: #selector(selectTraeAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = account.id
            item.state = account.preferred ? .on : .off
            traeAccountsMenu.addItem(item)
        }
        if !traeSummaries.isEmpty { traeAccountsMenu.addItem(.separator()) }
        let importTrae = NSMenuItem(title: "保存当前 Trae 登录账号",
                                    action: #selector(importCurrentTraeAccount), keyEquivalent: "")
        importTrae.target = self
        traeAccountsMenu.addItem(importTrae)
        traeAccountsItem.submenu = traeAccountsMenu
        menu.addItem(traeAccountsItem)
        let traeMoreItem = NSMenuItem(title: "更多…", action: nil, keyEquivalent: "")
        let traeMoreMenu = NSMenu()
        let traeProxyEnabled = NSMenuItem(title: "启用代理", action: #selector(toggleTraeProxy), keyEquivalent: "")
        traeProxyEnabled.target = self
        traeProxyEnabled.state = workBuddyProxy.isTraeRouteEnabled ? .on : .off
        traeMoreMenu.addItem(traeProxyEnabled)
        let checkinText: String
        if let state = traeState {
            checkinText = state.checkedIn || state.didCheckedIn
                ? "今日已签到"
                : "今日待签到 · +\(state.todayCredit.formatted()) 积分"
        } else {
            checkinText = "签到状态暂不可用"
        }
        let traeCheckinInfo = NSMenuItem(title: checkinText, action: nil, keyEquivalent: "")
        traeCheckinInfo.isEnabled = false
        traeMoreMenu.addItem(traeCheckinInfo)
        let traeModelsItem = NSMenuItem(title: "模型列表（\(traeModels.count)）", action: nil, keyEquivalent: "")
        let traeModelsMenu = NSMenu()
        for model in traeModels {
            let item = NSMenuItem(title: "\(model.name) · \(model.multiplier ?? "未提供倍率")",
                                  action: nil, keyEquivalent: "")
            item.toolTip = model.id
            item.isEnabled = false
            traeModelsMenu.addItem(item)
        }
        if traeModels.isEmpty {
            let item = NSMenuItem(title: traeError ?? (traeBusy ? "正在读取…" : "暂无模型数据"),
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            traeModelsMenu.addItem(item)
        }
        traeModelsItem.submenu = traeModelsMenu
        traeMoreMenu.addItem(traeModelsItem)
        let traeCurl = NSMenuItem(title: "复制 curl 示例", action: #selector(copyInstallInstruction(_:)), keyEquivalent: "")
        traeCurl.target = self
        traeCurl.representedObject = traeCurlExample(model: traeModels.first?.id ?? traeDefaultModel)
        traeMoreMenu.addItem(traeCurl)
        let traeClaim = NSMenuItem(title: traeState?.checkedIn == true || traeState?.didCheckedIn == true
                                  ? "今日已签到" : "立即签到",
                                   action: #selector(claimTraeCheckin), keyEquivalent: "")
        traeClaim.target = self
        traeClaim.isEnabled = !traeBusy && traeState?.checkedIn != true
            && traeState?.didCheckedIn != true && traeState?.checkinActive == true
        traeMoreMenu.addItem(traeClaim)
        let traeAutomatic = NSMenuItem(title: "每日自动签到", action: #selector(toggleTraeAutoCheckin),
                                       keyEquivalent: "")
        traeAutomatic.target = self
        traeAutomatic.state = traeAutoCheckin ? .on : .off
        traeMoreMenu.addItem(traeAutomatic)
        let traeRefresh = NSMenuItem(title: traeBusy ? "正在刷新…" : "刷新签到与模型",
                                     action: #selector(refreshTraeNow), keyEquivalent: "")
        traeRefresh.target = self
        traeRefresh.isEnabled = !traeBusy
        traeMoreMenu.addItem(traeRefresh)
        traeMoreItem.submenu = traeMoreMenu
        menu.addItem(traeMoreItem)
        menu.addItem(.separator())
    }
    ocxStatusItem = info(ocxStatusText)
        ocxActionItems = [
            ("开启代理", #selector(enableOcx)),
            ("关闭代理", #selector(disableOcx)),
            ("控制台", #selector(openDashboard))
        ].map { title, action in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = !ocxBusy && ocxInstalled
            menu.addItem(item)
            return item
        }
        let ocxMoreItem = NSMenuItem(title: "更多…", action: nil, keyEquivalent: "")
        let ocxMoreMenu = NSMenu()
        if workBuddyEnabled {
            let configureItem = NSMenuItem(title: "配置 / 刷新 WorkBuddy 代理", action: #selector(configureOcxWorkBuddy), keyEquivalent: "")
            configureItem.target = self
            configureItem.toolTip = "写入 WorkBuddy provider 并同步模型；重复点击可刷新配置"
            configureItem.isEnabled = !ocxBusy && ocxInstalled && workBuddyInstalled
            ocxMoreMenu.addItem(configureItem)
            ocxWorkBuddyConfigItem = configureItem
        } else {
            ocxWorkBuddyConfigItem = nil
        }
    if traeEnabled {
        let configureTraeItem = NSMenuItem(title: "配置 / 刷新 Trae 代理", action: #selector(configureOcxTrae), keyEquivalent: "")
        configureTraeItem.target = self
        configureTraeItem.toolTip = "写入 Trae provider 并同步模型；重复点击可刷新配置"
        configureTraeItem.isEnabled = !ocxBusy && ocxInstalled && traeRouteAvailable
        ocxMoreMenu.addItem(configureTraeItem)
        ocxTraeConfigItem = configureTraeItem
    } else {
        ocxTraeConfigItem = nil
    }
        ocxMoreMenu.addItem(.separator())
        let exportItem = NSMenuItem(title: "导出配置到下载目录", action: #selector(exportOcxConfig), keyEquivalent: "")
        exportItem.target = self
        let importItem = NSMenuItem(title: "选择配置并导入…", action: #selector(importOcxConfig), keyEquivalent: "")
        importItem.target = self
        ocxMoreMenu.addItem(exportItem)
        ocxMoreMenu.addItem(importItem)
        ocxMoreItem.submenu = ocxMoreMenu
        menu.addItem(ocxMoreItem)
        ocxActionItems += [exportItem, importItem]
        menu.addItem(.separator())
        let update = NSMenuItem(title: "检查更新…",
                                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                keyEquivalent: "")
        update.target = updaterController
        update.isEnabled = updaterController.updater.canCheckForUpdates
        menu.addItem(update)
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Codex Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        status.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if !ocxBusy { refreshOcxStatus() }
        if workBuddyEnabled, !workBuddyBusy { refreshWorkBuddy(autoClaim: true) }
        if traeEnabled, !traeBusy { refreshTrae(autoClaim: true) }
    }

    @objc func refreshWorkBuddyNow() { refreshWorkBuddy() }

    func refreshWorkBuddy(autoClaim: Bool = false) {
        guard workBuddyEnabled, !workBuddyBusy else { return }
        guard workBuddyCLIInstalled else {
            workBuddyError = "未检测到 WorkBuddy CLI，请安装并登录"
            render()
            return
        }
        workBuddyBusy = true
        render()
        let shouldAutoClaim = autoClaim && autoCheckin
        DispatchQueue.global(qos: .utility).async {
            let models = (try? self.workBuddyClient.models()) ?? []
            let result = Result { () -> WorkBuddyAccountState in
                if self.workBuddyAccounts.summaries.isEmpty { _ = try self.workBuddyAccounts.importCurrentAccount() }
                let summaries = self.workBuddyAccounts.summaries
                var attempts = (UserDefaults.standard.dictionary(forKey: "workBuddyLastAutoCheckins") ?? [:])
                    .compactMapValues { ($0 as? NSNumber)?.doubleValue }
                var states: [String: WorkBuddyAccountState] = [:]
                var firstState: WorkBuddyAccountState?
                var lastError: Error?
                for account in summaries {
                    do {
                        var state = try self.workBuddyClient.snapshot(accountID: account.id)
                        if shouldAutoClaim && shouldAutoCheckinWorkBuddy(state, lastAttempt: attempts[account.id]) {
                            attempts[account.id] = Date().timeIntervalSince1970
                            UserDefaults.standard.set(attempts, forKey: "workBuddyLastAutoCheckins")
                            state = try self.workBuddyClient.claimCheckin(accountID: account.id)
                        }
                        states[account.id] = state
                        if firstState == nil { firstState = state }
                    } catch { lastError = error }
                }
                let balances = states.compactMapValues(\.remaining)
                let rotatedID = self.workBuddyAccounts.recordBalances(balances)
                let preferredID = rotatedID ?? self.workBuddyAccounts.summaries.first(where: { $0.preferred })?.id
                if let preferredID, let state = states[preferredID] { return state }
                if let state = firstState { return state }
                throw lastError ?? WorkBuddyError.message("没有可用的 WorkBuddy 账号")
            }
            DispatchQueue.main.async {
                self.workBuddyBusy = false
                self.workBuddyModels = models
                switch result {
                case .success(let state): self.workBuddyState = state; self.workBuddyError = nil
                case .failure(let error): self.workBuddyError = error.localizedDescription
                }
                self.render()
            }
        }
    }

    @objc func claimWorkBuddyCheckin() {
        guard workBuddyEnabled, !workBuddyBusy else { return }
        workBuddyBusy = true
        render()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.workBuddyClient.claimCheckin() }
            DispatchQueue.main.async {
                self.workBuddyBusy = false
                switch result {
                case .success(let state): self.workBuddyState = state; self.workBuddyError = nil
                case .failure(let error): self.workBuddyError = error.localizedDescription
                }
                self.render()
            }
        }
    }

    @objc func toggleWorkBuddyAutoCheckin() {
        guard workBuddyEnabled else { return }
        UserDefaults.standard.set(!autoCheckin, forKey: "workBuddyAutoCheckin")
        resetWorkBuddyTimer()
        render()
        if autoCheckin { refreshWorkBuddy(autoClaim: true) }
    }

    @objc func toggleWorkBuddyProxy() {
        guard workBuddyRouteAvailable else { return }
        try? workBuddyProxy.setWorkBuddyRunning(!workBuddyProxy.isWorkBuddyRouteEnabled)
        render()
    }

    @objc func toggleTraeProxy() {
        guard traeRouteAvailable else { return }
        try? workBuddyProxy.setTraeRunning(!workBuddyProxy.isTraeRouteEnabled)
        render()
    }

    @objc func importCurrentTraeAccount() {
        let result = Result { try traeAccounts.importCurrentAccount() }
        let alert = NSAlert()
        switch result {
        case .success(let account):
            alert.messageText = "Trae 账号已保存"
            alert.informativeText = account.name
            refreshTrae()
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "保存账号失败"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
        render()
    }

    @objc func selectTraeAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        try? traeAccounts.prefer(id)
        refreshTrae()
        render()
    }

    @objc func claimTraeCheckin() {
        guard traeEnabled, !traeBusy else { return }
        traeBusy = true
        render()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.traeClient.claimCheckin() }
            DispatchQueue.main.async {
                self.traeBusy = false
                switch result {
                case .success(let state): self.traeState = state; self.traeError = nil
                case .failure(let error): self.traeError = error.localizedDescription
                }
                self.render()
            }
        }
    }

    @objc func toggleTraeAutoCheckin() {
        guard traeEnabled else { return }
        UserDefaults.standard.set(!traeAutoCheckin, forKey: "traeAutoCheckin")
        resetTraeTimer()
        render()
        if traeAutoCheckin { refreshTrae(autoClaim: true) }
    }

    @objc func importCurrentWorkBuddyAccount() {
        let result = Result { try workBuddyAccounts.importCurrentAccount() }
        let alert = NSAlert()
        switch result {
        case .success(let account):
            alert.messageText = "WorkBuddy 账号已保存"
            alert.informativeText = account.name
            refreshWorkBuddy()
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "保存账号失败"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
        render()
    }

    @objc func selectWorkBuddyAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        try? workBuddyAccounts.prefer(id)
        refreshWorkBuddy()
        render()
    }

    @objc func copyInstallInstruction(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let alert = NSAlert()
        alert.messageText = "已复制到剪贴板"
        alert.informativeText = text
        alert.runModal()
    }

    @objc func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 188),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex Helper 设置"
        window.isReleasedWhenClosed = false
        window.center()
        guard let content = window.contentView else { return }

    let workBuddy = NSButton(checkboxWithTitle: "启用 WorkBuddy 功能", target: self, action: #selector(settingsChanged))
    workBuddy.state = workBuddyEnabled ? .on : .off
    workBuddy.frame = NSRect(x: 24, y: 137, width: 342, height: 22)
    workBuddyEnabledButton = workBuddy

    let trae = NSButton(checkboxWithTitle: "启用 Trae 代理", target: self, action: #selector(settingsChanged))
    trae.state = traeEnabled ? .on : .off
    trae.frame = NSRect(x: 24, y: 107, width: 342, height: 22)
    traeEnabledButton = trae

        let intervalLabel = NSTextField(labelWithString: "刷新间隔")
        intervalLabel.frame = NSRect(x: 24, y: 69, width: 76, height: 22)
        let field = NSTextField(string: String(Int(refreshInterval)))
        field.frame = NSRect(x: 104, y: 66, width: 72, height: 26)
        field.alignment = .right
        field.formatter = NumberFormatter()
        field.delegate = self
        field.setAccessibilityLabel("刷新间隔秒数")
        intervalField = field
        let seconds = NSTextField(labelWithString: "秒（5–3600）")
        seconds.textColor = .secondaryLabelColor
        seconds.frame = NSRect(x: 184, y: 69, width: 100, height: 22)
        let save = NSButton(title: "保存", target: self, action: #selector(saveSettings))
        save.frame = NSRect(x: 296, y: 64, width: 70, height: 30)
        settingsSaveButton = save
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        let versionLabel = NSTextField(labelWithString: "Codex Helper \(version)（Build \(build)）")
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 24, y: 20, width: 342, height: 22)
    [workBuddy, trae, intervalLabel, field, seconds, save, versionLabel].forEach { content.addSubview($0) }
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshOcxStatus()
    }

    @objc func settingsChanged() {
        settingsSaveButton?.isEnabled = true
    }

    func controlTextDidChange(_ obj: Notification) {
        settingsSaveButton?.isEnabled = true
    }

    @objc func saveSettings() {
        guard let field = intervalField else { return }
        let value = min(3600, max(5, field.doubleValue))
        UserDefaults.standard.set(value, forKey: "refreshInterval")
    let enabled = workBuddyEnabledButton?.state == .on
    UserDefaults.standard.set(enabled, forKey: "workBuddyEnabled")
    let traeOn = traeEnabledButton?.state == .on
    UserDefaults.standard.set(traeOn, forKey: "traeEnabled")
    field.stringValue = String(Int(value))
    resetTimer()
    // 两条路由各自按自己的开关与上游可用性生效，互不影响。
    if enabled, workBuddyCLIInstalled {
        refreshWorkBuddy()
        resetWorkBuddyTimer()
    } else {
        workBuddyTimer?.invalidate()
        workBuddyTimer = nil
        workBuddyState = nil
        workBuddyModels = []
        workBuddyError = nil
    }
    if traeRouteAvailable {
        refreshTrae()
        resetTraeTimer()
    } else {
        // 关闭 Trae 时清空它自己的临时 UI 状态，WorkBuddy 不受影响。
        traeTimer?.invalidate()
        traeTimer = nil
        traeState = nil
        traeCreditsByAccount = [:]
        traeModels = []
        traeError = nil
    }
    applyProxyRouteState()
    render()
        settingsSaveButton?.isEnabled = false
        let alert = NSAlert()
        alert.messageText = "设置已保存"
        alert.runModal()
    }

    func setOcxBusy(_ busy: Bool, message: String? = nil) {
        ocxBusy = busy
        let ocxInstalled = executable(named: "ocx") != nil
    ocxActionItems.forEach { $0.isEnabled = !busy && ocxInstalled }
    ocxWorkBuddyConfigItem?.isEnabled = !busy && ocxInstalled && workBuddyCLIInstalled
    ocxTraeConfigItem?.isEnabled = !busy && ocxInstalled && traeRouteAvailable
        if let message {
            ocxStatusText = message
            ocxStatusItem?.title = message
        }
    }

    @objc func refreshOcxStatus() {
        guard !ocxBusy, !ocxChecking else { return }
        guard executable(named: "ocx") != nil else {
            ocxStatusText = "未检测到 OpenCodex"
            ocxStatusItem?.title = ocxStatusText
            return
        }
        ocxChecking = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try runCommand("ocx", ["health", "--json"], timeout: 5) }
            DispatchQueue.main.async {
                self.ocxChecking = false
                switch result {
                case .success(let health):
                    let running = health.data(using: .utf8)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["ok"] as? Bool ?? false
                    self.ocxStatusText = running ? "OpenCodex Running" : "OpenCodex Stop"
                case .failure:
                    self.ocxStatusText = "OpenCodex 状态不可用"
                }
                self.ocxStatusItem?.title = self.ocxStatusText
            }
        }
    }

    func runOcx(_ commands: [[String]], progress: String, success: String,
                completion: ((Result<Void, Error>) -> Void)? = nil) {
        setOcxBusy(true, message: progress)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                for command in commands { _ = try runCommand("ocx", command) }
                DispatchQueue.main.async {
                    self.setOcxBusy(false, message: success)
                    self.refreshOcxStatus()
                    completion?(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    self.setOcxBusy(false, message: "操作失败，请运行 ocx status 检查")
                    completion?(.failure(error))
                }
            }
        }
    }

    @objc func enableOcx() {
        runOcx([["restart"], ["restore", "back"], ["sync", "--restart-codex"]],
               progress: "OpenCodex Starting…", success: "OpenCodex Running")
    }

    @objc func disableOcx() {
        runOcx([["restore"], ["system", "codex-restart", "--yes"], ["stop"], ["restore"]],
               progress: "OpenCodex Stopping…", success: "OpenCodex Stop")
    }

    @objc func openDashboard() {
        runOcx([["gui"]], progress: "Opening Console…", success: "OpenCodex Running")
    }

    @objc func configureOcxWorkBuddy() {
        guard workBuddyRouteAvailable, executable(named: "ocx") != nil else {
            render()
            return
        }
        do { try workBuddyProxy.setWorkBuddyRunning(true) }
        catch {
            showOcxTransferResult(.failure(error), success: "", detail: "")
            return
        }
        let firstConfiguration = (try? runCommand("ocx", ["provider", "show", "workbuddy", "--json"])) == nil
        runOcx(workBuddyOcxConfigurationCommands(firstConfiguration: firstConfiguration),
               progress: "正在配置 WorkBuddy…", success: "WorkBuddy 已配置") { result in
            self.showOcxTransferResult(result, success: "WorkBuddy 代理已配置",
                                       detail: "模型已经同步到 Codex；再次点击可刷新配置。")
        }
    }

    @objc func configureOcxTrae() {
        guard traeRouteAvailable, executable(named: "ocx") != nil else {
            render()
            return
        }
        do { try workBuddyProxy.setTraeRunning(true) }
        catch {
            showOcxTransferResult(.failure(error), success: "", detail: "")
            return
        }
        let firstConfiguration = (try? runCommand("ocx", ["provider", "show", "trae", "--json"])) == nil
        runOcx(traeOcxConfigurationCommands(firstConfiguration: firstConfiguration),
               progress: "正在配置 Trae…", success: "Trae 已配置") { result in
            self.showOcxTransferResult(result, success: "Trae 代理已配置",
                                       detail: "模型已经同步到 Codex；再次点击可刷新配置。")
        }
    }

    func showOcxTransferResult(_ result: Result<Void, Error>, success: String, detail: String) {
        let alert = NSAlert()
        switch result {
        case .success:
            alert.messageText = success
            alert.informativeText = detail
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "操作失败"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    @objc func exportOcxConfig() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/OCX_CONF.json").path
        runOcx([["config", "export", path]], progress: "正在导出配置…", success: "配置已导出") { result in
            self.showOcxTransferResult(result, success: "OpenCodex 配置已导出", detail: path)
        }
    }

    @objc func importOcxConfig() {
        let panel = NSOpenPanel()
        panel.title = "选择 OpenCodex 配置"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "导入并覆盖当前 OpenCodex 配置？"
        alert.informativeText = url.path
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runOcx([["config", "import", url.path, "--yes"]], progress: "正在导入配置…", success: "配置已导入") { result in
            self.showOcxTransferResult(result, success: "OpenCodex 配置已导入", detail: "新配置将在下次启动或同步后生效。")
        }
    }
}

@main
struct CodexHelperMain {
static func main() throws {
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--self-test") {
    let sample = #"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300},"secondary":null},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":0,"windowDurationMins":300},"secondary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":1789368213},"planType":"plus"}}}"#
    let parsed = try JSONDecoder().decode(Quota.self, from: Data(sample.utf8))
    precondition(parsed.title == "5h: 100% · 1w: 94%")
    precondition(parsed.buckets[0].1.windows[1].label == "7天")
    precondition(Window(usedPercent: 110, windowDurationMins: nil, resetsAt: nil).remaining == 0)
    precondition(Window(usedPercent: -10, windowDurationMins: 60, resetsAt: nil).remaining == 100)
    precondition(Window(usedPercent: 99.1, windowDurationMins: 60, resetsAt: nil).remaining == 0)
    let legacy = try JSONDecoder().decode(Quota.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}"#.utf8))
    precondition(legacy.title == "5h: 75%")
    let empty = try JSONDecoder().decode(Quota.self, from: Data(#"{"rateLimits":null,"rateLimitsByLimitId":{}}"#.utf8))
    precondition(empty.title == "额度暂无")
    let setup = workBuddyOcxConfigurationCommands(firstConfiguration: true)
    precondition(setup.first?.contains("--force") == true)
    precondition(setup.contains(["models", "provider", "workbuddy", "on"]))
    precondition(workBuddyOcxConfigurationCommands(firstConfiguration: false).count == 4)
    let pendingCheckin = WorkBuddyAccountState(remaining: 1, unit: "积分", checkedIn: false,
                                                checkinActive: true, todayCredit: 1, streakDays: 0)
    precondition(shouldAutoCheckinWorkBuddy(pendingCheckin, lastAttempt: nil))
    precondition(!shouldAutoCheckinWorkBuddy(pendingCheckin, lastAttempt: Date().timeIntervalSince1970))
    let pendingTraeCheckin = TraeCheckinState(checkedIn: false, didCheckedIn: false, checkinActive: true,
                                              baseCredit: 150, bonusCredit: 50)
    precondition(shouldAutoCheckinTrae(pendingTraeCheckin, lastAttempt: nil))
    precondition(!shouldAutoCheckinTrae(pendingTraeCheckin, lastAttempt: Date().timeIntervalSince1970))
    precondition(shouldAutoCheckinTrae(pendingTraeCheckin,
                                      lastAttempt: Date().addingTimeInterval(-601).timeIntervalSince1970))
    precondition(!shouldAutoCheckinTrae(TraeCheckinState(checkedIn: true, didCheckedIn: true,
                                                        checkinActive: true, baseCredit: 0, bonusCredit: 0),
                                       lastAttempt: nil))
    precondition(openCodexInstallCommand.contains("npm install -g @bitkyc08/opencodex"))
    precondition(workBuddyInstallURL.hasPrefix("https://"))
    precondition(setup.first?.joined(separator: " ").contains("http://127.0.0.1:58100/workbuddy/v1") == true)
    precondition(!setup.first!.joined(separator: " ").contains(":58100/v1 "))
    precondition(workBuddyCurlExample(model: "test-model").contains("/workbuddy/v1/chat/completions"))
    precondition(workBuddyCurlExample(model: "test-model").contains("Bearer workbuddy-local"))
    precondition(traeOcxConfigurationCommands(firstConfiguration: true).first?.joined(separator: " ")
        .contains("http://127.0.0.1:58100/trae/v1") == true)
    let traeSetup = traeOcxConfigurationCommands(firstConfiguration: true)
    precondition(traeSetup.first?.joined(separator: " ").contains("http://127.0.0.1:58100/trae/v1") == true)
    precondition(traeSetup.contains(["models", "provider", "trae", "on"]))
    precondition(traeSetup.last == ["sync", "--restart-codex"])
    precondition(traeOcxConfigurationCommands(firstConfiguration: false).count == 4)
    precondition(traeCurlExample(model: "test-model").contains("/trae/v1/chat/completions"))
    precondition(traeCurlExample(model: "test-model").contains("Bearer trae-local"))
    precondition(workBuddyRotationCredits(previousBalance: nil, currentBalance: 2500, accumulated: 0) == 0)
    precondition(workBuddyRotationCredits(previousBalance: 2500, currentBalance: 2440, accumulated: 45) == 105)
    precondition(workBuddyRotationCredits(previousBalance: 2440, currentBalance: 2500, accumulated: 45) == 45)
    WorkBuddyClient.selfTest()
    WorkBuddyAccountPool.selfTest()
    WorkBuddyProxy.selfTest()
    TraeClient.selfTest()
    TraeAccountPool.selfTest()
    print("PASS: 配额解析、账号限流识别、WorkBuddy Chat 转发与 Trae Chat 翻译")
} else if CommandLine.arguments.contains("--check-workbuddy") {
    let accounts = WorkBuddyAccountPool()
    let client = WorkBuddyClient(accounts: accounts)
    let state = try client.snapshot()
    print("\(state.balanceText)；\(state.checkedIn ? "今日已签到" : "今日待签到")；模型 \(try client.models().count) 个；账号 \(accounts.summaries.count) 个")
    } else if CommandLine.arguments.contains("--serve-proxy") {
        let accounts = WorkBuddyAccountPool()
        let client = WorkBuddyClient(accounts: accounts)
        let traeAccounts = TraeAccountPool()
        let proxy = WorkBuddyProxy(client: client, traeClient: TraeClient(accounts: traeAccounts))
        // 由 set* 决定是否真的监听：两个路由都关时不应占用端口。
        try proxy.setWorkBuddyRunning(ProcessInfo.processInfo.environment["CODEX_HELPER_WORKBUDDY"] != "0")
        try proxy.setTraeRunning(ProcessInfo.processInfo.environment["CODEX_HELPER_TRAE"] != "0")
        print("Chat proxy listening on 127.0.0.1:\(WorkBuddyProxy.port)")
        RunLoop.main.run()
} else if CommandLine.arguments.contains("--check") {
    do { print("当前账户剩余：\(try readQuota().title)") }
    catch {
        print((error as? QueryError)?.rawValue ?? QueryError.response.rawValue)
        if !(error is QueryError) {
            let detail = error as NSError
            print("诊断：\(type(of: error)) / \(detail.domain) / \(detail.code)")
            if case DecodingError.keyNotFound(let key, _) = error { print("缺失字段：\(key.stringValue)") }
            if case DecodingError.typeMismatch(_, let context) = error { print("类型不匹配：\(context.codingPath.map { $0.stringValue }.joined(separator: "."))") }
        }
        exit(1)
    }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
}
}
