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
    var statusBarTitle: String {
        let separator = buckets.first?.1.windows.count == 1 ? ": " : " · "
        return title.replacingOccurrences(of: separator, with: "\n")
    }
    func weeklyRange(now: Date = Date()) -> DateInterval? {
        guard let window = buckets.first?.1.windows.first(where: { $0.windowDurationMins == 10080 }),
              let reset = window.resetsAt, reset.isFinite else { return nil }
        let end = Date(timeIntervalSince1970: reset)
        let start = end.addingTimeInterval(-7 * 24 * 60 * 60)
        guard start <= now, now < end else { return nil }
        return DateInterval(start: start, end: end)
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

func modelLatencyTier(_ seconds: Double) -> Int { seconds < 2 ? 0 : (seconds < 5 ? 1 : 2) }

private enum ModelLatency {
    case measuring
    case measured(Double)
    case failed(Double)
}

private final class ModelProbeButton: NSButton {
    let service: String
    let modelID: String
    private let baseTitle: String
    private let canMeasure: Bool

    init(service: String, modelID: String, title: String, canMeasure: Bool) {
        self.service = service
        self.modelID = modelID
        baseTitle = title
        self.canMeasure = canMeasure
        let font = NSFont.menuFont(ofSize: 0)
        let width = min(600, ceil(((title + " · 300.00s ✕") as NSString).size(withAttributes: [.font: font]).width + 8))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        isBordered = false
        alignment = .left
        self.font = font
        toolTip = canMeasure ? "点击测速，会消耗少量积分" : "该模型不支持聊天测速"
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ result: ModelLatency?) {
        let suffix: String
        let color: NSColor?
        switch result {
        case .none:
            suffix = ""
            color = nil
        case .measuring:
            suffix = " · 测速中…"
            color = nil
        case .measured(let seconds):
            suffix = String(format: " · %.2fs", seconds)
            color = [.systemGreen, .systemBrown, .systemRed][modelLatencyTier(seconds)]
        case .failed(let seconds):
            suffix = String(format: " · %.2fs ✕", seconds)
            color = .systemRed
        }
        title = baseTitle + suffix
        let text = NSMutableAttributedString(string: title)
        if let color {
            text.addAttribute(.foregroundColor, value: color,
                              range: NSRange(location: (baseTitle as NSString).length,
                                             length: (suffix as NSString).length))
        }
        attributedTitle = text
        if case .measuring? = result { isEnabled = false }
        else { isEnabled = canMeasure }
    }
}

func runCommand(_ name: String, _ arguments: [String], timeout: TimeInterval? = nil,
                includeStandardError: Bool = true) throws -> String {
    guard let path = executable(named: name) else { throw QueryError.missingCLI }
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    if !includeStandardError { process.standardError = FileHandle.nullDevice }
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

private final class CardSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.withAlphaComponent(0.65).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private func label(_ text: String, frame: NSRect, size: CGFloat = 13,
                   weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.frame = frame
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

private func symbol(_ name: String, frame: NSRect, color: NSColor = .controlAccentColor) -> NSImageView {
    let image = NSImageView(frame: frame)
    image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    image.contentTintColor = color
    image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
    return image
}

func menuInfo(_ text: String) -> NSView {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: 12)
    field.textColor = .secondaryLabelColor
    field.preferredMaxLayoutWidth = 292
    let height = ceil(field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 292, height: 10_000)).height)
    field.frame = NSRect(x: 14, y: 4, width: 292, height: height)
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: height + 8))
    view.toolTip = text
    view.addSubview(field)
    return view
}

func quotaHeading(_ name: String, plan: String?) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
    let title = label(name, frame: NSRect(x: 14, y: 10, width: plan == nil ? 292 : 192, height: 25), size: 18, weight: .bold)
    title.toolTip = name
    view.addSubview(title)
    if let plan {
        let text = plan.replacingOccurrences(of: "_", with: "").lowercased() == "prolite" ? "ProLite" : plan.capitalized
        let badge = label(text, frame: NSRect(x: 222, y: 13, width: 84, height: 19), size: 12, weight: .semibold, color: .controlAccentColor)
        badge.alignment = .right
        badge.toolTip = text
        view.addSubview(badge)
    }
    return view
}

func quotaRow(_ window: Window, stale: Bool) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 88))
    let card = CardSurface(frame: NSRect(x: 12, y: 4, width: 296, height: 80))
    view.addSubview(card)
    let title = label("\(window.label)额度", frame: NSRect(x: 26, y: 58, width: 170, height: 18), weight: .medium)
    let value = label("\(window.remaining)%", frame: NSRect(x: 198, y: 47, width: 96, height: 32), size: 25, weight: .semibold)
    value.font = .monospacedDigitSystemFont(ofSize: 25, weight: .semibold)
    value.alignment = .right
    value.textColor = stale ? .secondaryLabelColor : window.remaining <= 10 ? .systemRed : .labelColor
    value.setAccessibilityLabel("\(window.label)额度剩余 \(window.remaining)%" + (stale ? "，上次结果" : ""))
    let remaining = label(stale ? "上次结果" : "剩余额度", frame: NSRect(x: 26, y: 40, width: 170, height: 16), size: 10, color: .secondaryLabelColor)
    let bar = NSProgressIndicator(frame: NSRect(x: 26, y: 29, width: 268, height: 6))
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
    let subtitle = label(reset, frame: NSRect(x: 26, y: 9, width: 268, height: 16), size: 10, color: .secondaryLabelColor)
    [title, value, remaining, bar, subtitle].forEach { view.addSubview($0) }
    return view
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTextFieldDelegate {
    lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true,
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
    private let tokenUsageReader = CodexTokenUsageReader()
    private let tokenUsageQueue = DispatchQueue(label: "local.codex.helper.token-usage", qos: .utility)
    private lazy var usageSync = CodexUsageSync()
    private var tokenUsage: CodexTokenUsageSnapshot?
    private var tokenUsageError: String?
    private var tokenUsageBusy = false
    private var tokenUsageRange: DateInterval?
    private var tokenDateWindow: NSWindow?
    private var tokenStartPicker: NSDatePicker?
    private var tokenEndPicker: NSDatePicker?
    var timer: Timer?
    var workBuddyTimer: Timer?
    var traeTimer: Timer?
    var settingsWindow: NSWindow?
    var intervalField: NSTextField?
    var workBuddyEnabledButton: NSButton?
    var traeEnabledButton: NSButton?
    var openCodexEnabledButton: NSButton?
    var usageCloudEnabledButton: NSButton?
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
    private var modelLatencies: [String: ModelLatency] = [:]
    private var menuTracking = false
    var traeState: TraeCheckinState?
    var traeCreditsByAccount: [String: TraeCredits] = [:]
    var traeError: String?
    var traeBusy = false
    var featureDefaults = UserDefaults.standard
    var workBuddyEnabled: Bool {
        featureDefaults.bool(forKey: "workBuddyEnabled")
    }
    var traeEnabled: Bool {
        featureDefaults.bool(forKey: "traeEnabled")
    }
    var openCodexEnabled: Bool {
        featureDefaults.bool(forKey: "openCodexEnabled")
    }
    var usageCloudEnabled: Bool { featureDefaults.bool(forKey: "usageCloudEnabled") }
    private var usageDevice: String? { featureDefaults.string(forKey: "usageDevice") }
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
        NotificationCenter.default.addObserver(self, selector: #selector(debugLogFailed(_:)),
                                               name: ProxyDebugLog.failureNotification, object: nil)
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
        refreshTokenUsage()
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
                    self.refreshTokenUsage()
                case .failure(let failure):
                    self.error = (failure as? QueryError)?.rawValue ?? QueryError.response.rawValue
                }
                self.render()
            }
        }
    }

    private func refreshTokenUsage() {
        guard !tokenUsageBusy else { return }
        tokenUsageBusy = true
        let requestedRange = tokenUsageRange
        let requestedWeek = quota?.weeklyRange()
        let requestedCloud = usageCloudEnabled
        let requestedDevice = usageDevice
        tokenUsageQueue.async {
            let result = Result { try self.tokenUsageReader.read(weeklyRange: requestedWeek, range: requestedRange,
                sync: requestedCloud ? self.usageSync : nil, device: requestedDevice) }
            DispatchQueue.main.async {
                self.tokenUsageBusy = false
                guard self.tokenUsageRange == requestedRange, self.quota?.weeklyRange() == requestedWeek,
                      self.usageCloudEnabled == requestedCloud, self.usageDevice == requestedDevice else {
                    self.refreshTokenUsage()
                    return
                }
                switch result {
                case .success(let snapshot):
                    self.tokenUsage = snapshot
                    self.tokenUsageError = nil
                case .failure(let error):
                    self.tokenUsageError = error.localizedDescription
                }
                self.render()
            }
        }
    }

    func render() {
        let stale = error != nil || (updated.map { Date().timeIntervalSince($0) > max(30, refreshInterval * 3) } ?? false)
        let title = (stale ? "⚠ " : "") + (quota?.statusBarTitle ?? (refreshing ? "正在\n读取" : "额度\n不可用"))
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
        if menuTracking { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.minimumWidth = 320
        @discardableResult func section(_ title: String) -> NSMenuItem {
            let item = NSMenuItem.sectionHeader(title: title)
            menu.addItem(item)
            return item
        }
        @discardableResult func info(_ text: String) -> NSMenuItem {
            let item = NSMenuItem()
            item.view = menuInfo(text)
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
        func modelProbeItem(service: String, id: String, title: String, canMeasure: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let button = ModelProbeButton(service: service, modelID: id, title: title, canMeasure: canMeasure)
            button.target = self
            button.action = #selector(measureModel(_:))
            button.show(modelLatencies["\(service):\(id)"])
            let row = NSView(frame: NSRect(x: 0, y: 0, width: button.frame.width + 32, height: 24))
            button.frame.origin.x = 16
            row.addSubview(button)
            item.view = row
            return item
        }
        let codexInstalled = codexExecutable() != nil
        let ocxInstalled = openCodexEnabled && executable(named: "ocx") != nil
        let workBuddyInstalled = workBuddyEnabled && workBuddyCLIInstalled
        if !codexInstalled { installPrompt("⚠ 未检测到 Codex CLI，点击复制安装命令", copyText: codexInstallCommand) }
        if openCodexEnabled, !ocxInstalled { installPrompt("⚠ 未检测到 OpenCodex，点击复制安装命令", copyText: openCodexInstallCommand) }
        if workBuddyEnabled, !workBuddyInstalled { installPrompt("⚠ 未检测到 WorkBuddy CLI，点击复制官网地址", copyText: workBuddyInstallURL) }
        if !codexInstalled || (openCodexEnabled && !ocxInstalled) || (workBuddyEnabled && !workBuddyInstalled) { menu.addItem(.separator()) }
        if let quota = quota, !quota.buckets.isEmpty {
            for (id, bucket) in quota.buckets {
                let name = bucket.limitName ?? (id == "codex" ? "Codex" : id)
                let heading = NSMenuItem()
                heading.view = quotaHeading(name, plan: bucket.planType)
                menu.addItem(heading)
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
        if error != nil || (stale && quota != nil) { menu.addItem(.separator()) }
        section("费用估算 · USD").toolTip = "官方 API 参考价，Fast / priority 为标准价 ×2，默认 30 分钟缓存；未确认模型单价或档位按 $0，非订阅实际账单。"
        if let tokenUsage {
            if usageCloudEnabled {
                let name = usageDevice.flatMap { id in tokenUsage.devices.first { $0.id == id }?.name } ?? (usageDevice == nil ? "全部设备" : "设备暂不可用")
                let scope = NSMenuItem(title: "统计来源：\(name)", action: nil, keyEquivalent: "")
                let choices = NSMenu()
                let all = NSMenuItem(title: "全部设备（去重合并）", action: #selector(selectUsageDevice(_:)), keyEquivalent: "")
                all.target = self
                all.state = usageDevice == nil ? .on : .off
                choices.addItem(all)
                for device in tokenUsage.devices {
                    let item = NSMenuItem(title: device.name + (device.id == usageSync.deviceID ? "（本机）" : ""),
                                          action: #selector(selectUsageDevice(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = device.id
                    item.state = usageDevice == device.id ? .on : .off
                    item.toolTip = device.updated.map { "数据更新于 " + $0.formatted(date: .numeric, time: .standard) } ?? "暂无已同步记录"
                    choices.addItem(item)
                }
                scope.toolTip = "按提供记录的设备查看；复制历史可能重叠，全部设备总额只计算一次"
                scope.submenu = choices
                menu.addItem(scope)
                if let message = tokenUsage.syncMessage { info(message) }
            }
            for period in tokenUsage.periods {
                if period.name == "当前周额度", period.interval != quota?.weeklyRange() { continue }
                let item = NSMenuItem(title: "\(period.name) · \(CodexTokenPricing.dollars(period.estimatedUSD))", action: nil, keyEquivalent: "")
                let amount = CodexTokenPricing.dollars(period.estimatedUSD)
                let title = NSMutableAttributedString(string: "\(period.name)   \(amount)")
                title.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                                   range: NSRange(location: title.length - (amount as NSString).length, length: (amount as NSString).length))
                item.attributedTitle = title
                let periodMenu = NSMenu()
                periodMenu.autoenablesItems = false
                for (group, amounts) in period.models.sorted(by: {
                    let left = period.costs[$0.key]?.total ?? 0, right = period.costs[$1.key]?.total ?? 0
                    return left == right ? $0.key.title < $1.key.title : left > right
                }) {
                    let costs = period.costs[group] ?? CodexTokenCosts()
                    let price = CodexTokenPricing.dollars(costs.total)
                    let performance = period.performance[group] ?? CodexOutputPerformance()
                    let modelItem = NSMenuItem(title: "\(group.title) · \(price) · \(performance.label)", action: nil, keyEquivalent: "")
                    modelItem.toolTip = CodexOutputPerformance.explanation
                    let details = NSMenu()
                    details.autoenablesItems = false
                    for text in [performance.label, performance.sampleLabel] + costs.rows(amounts: amounts) + ["缓存已计入输入", "推理已计入输出"] {
                        let row = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                        row.isEnabled = false
                        details.addItem(row)
                    }
                    modelItem.submenu = details
                    periodMenu.addItem(modelItem)
                }
                if period.models.isEmpty {
                    let empty = NSMenuItem(title: "暂无已记录用量", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    periodMenu.addItem(empty)
                }
                item.submenu = periodMenu
                item.toolTip = "\(period.interval.start.formatted(date: .numeric, time: .shortened)) 至 \(period.interval.end.formatted(date: .numeric, time: .shortened)) · \(tokenUsage.timeZone) · 按日志模型标签分类"
                if let range = tokenUsageRange, period.interval == range {
                    let end = range.end.addingTimeInterval(-1)
                    item.toolTip = "\(range.start.formatted(date: .numeric, time: .omitted)) 至 \(end.formatted(date: .numeric, time: .omitted))（含首尾当天）· \(tokenUsage.timeZone)"
                }
                menu.addItem(item)
            }
            if quota?.weeklyRange() == nil { info("当前周额度 · 周期暂不可用") }
            info("更新于 \(tokenUsage.updated.formatted(date: .omitted, time: .standard))")
            if tokenUsage.unreadableFiles > 0 { info("⚠ \(tokenUsage.unreadableFiles) 个文件未能读取，统计可能不完整") }
            if tokenUsage.skippedEvents > 0 { info("⚠ \(tokenUsage.skippedEvents) 条用量缺失或异常，已跳过") }
        } else if tokenUsageError == nil {
            info(tokenUsageBusy ? "正在计算本地用量…" : "暂无本地用量数据")
        }
        if let tokenUsageError { info("⚠ Token 统计：" + tokenUsageError + (tokenUsage == nil ? "" : "（保留上次结果）")) }
        let dateQuery = NSMenuItem(title: "按日期区间查询…", action: #selector(showTokenDateRange), keyEquivalent: "")
        dateQuery.target = self
        menu.addItem(dateQuery)
        menu.addItem(.separator())
    if workBuddyEnabled {
        section("WorkBuddy  ·  " + (workBuddyProxy.isWorkBuddyRunning ? "运行中" : "已停止"))
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
        let modelsItem = NSMenuItem(title: "模型列表（\(workBuddyModels.count)）", action: nil, keyEquivalent: "")
        let modelsMenu = NSMenu()
        modelsMenu.autoenablesItems = false
        for model in workBuddyModels {
            let rate = model.credits.flatMap { $0.isEmpty ? nil : $0 } ?? "未标注倍率"
            modelsMenu.addItem(modelProbeItem(service: "workbuddy", id: model.id,
                                              title: "\(model.name) · \(rate)", canMeasure: model.type == "chat"))
        }
        if workBuddyModels.isEmpty {
            let item = NSMenuItem(title: "暂无模型数据", action: nil, keyEquivalent: "")
            item.isEnabled = false
            modelsMenu.addItem(item)
        }
        modelsItem.submenu = modelsMenu
        menu.addItem(modelsItem)
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
        section("Trae  ·  " + (workBuddyProxy.isTraeRunning ? "运行中" : "已停止"))
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
        let traeModelsItem = NSMenuItem(title: "模型列表（\(traeModels.count)）", action: nil, keyEquivalent: "")
        let traeModelsMenu = NSMenu()
        traeModelsMenu.autoenablesItems = false
        for model in traeModels {
            traeModelsMenu.addItem(modelProbeItem(service: "trae", id: model.id,
                                                  title: "\(model.name) · \(model.multiplier ?? "未提供倍率")"))
        }
        if traeModels.isEmpty {
            let item = NSMenuItem(title: traeError ?? (traeBusy ? "正在读取…" : "暂无模型数据"),
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            traeModelsMenu.addItem(item)
        }
        traeModelsItem.submenu = traeModelsMenu
        menu.addItem(traeModelsItem)
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
    ocxStatusItem = nil
    ocxActionItems = []
    ocxWorkBuddyConfigItem = nil
    ocxTraeConfigItem = nil
    if openCodexEnabled {
        ocxStatusItem = section(ocxStatusText)
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
    }
        let update = NSMenuItem(title: "检查更新…",
                                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                keyEquivalent: "")
        update.target = updaterController
        update.isEnabled = updaterController.updater.canCheckForUpdates
        menu.addItem(update)
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let debug = NSMenuItem(title: "Debug Mode", action: #selector(toggleDebugMode), keyEquivalent: "")
        debug.target = self
        debug.state = ProxyDebugLog.enabled ? .on : .off
        debug.toolTip = "仅本次运行有效；记录完整请求文本到 ~/Downloads/CodexHelper-Debug，可能包含私人内容"
        menu.addItem(debug)
        if ProxyDebugLog.enabled {
            let logs = NSMenuItem(title: "打开 Debug 日志目录", action: #selector(openDebugLogs), keyEquivalent: "")
            logs.target = self
            menu.addItem(logs)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Codex Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        status.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuTracking = true
        refreshTokenUsage()
        if !ocxBusy { refreshOcxStatus() }
        if workBuddyEnabled, !workBuddyBusy { refreshWorkBuddy(autoClaim: true) }
        if traeEnabled, !traeBusy { refreshTrae(autoClaim: true) }
    }

    @objc func toggleDebugMode() {
        if !ProxyDebugLog.enabled {
            let alert = NSAlert()
            alert.messageText = "开启 Debug Mode？"
            alert.informativeText = "将完整请求文本、工具定义和错误写入 ~/Downloads/CodexHelper-Debug。可能包含私人对话和代码；鉴权头及二进制内容不记录，但文本中的敏感信息无法全部自动识别。关闭或重启应用后停止记录，已有文件需手动清理。"
            alert.addButton(withTitle: "开启")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        ProxyDebugLog.enabled.toggle()
        render()
    }

    @objc func openDebugLogs() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ProxyDebugLog.directory.path)
    }

    @objc func debugLogFailed(_ notification: Notification) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Debug Mode 已关闭"
        alert.informativeText = notification.userInfo?["error"] as? String ?? "无法写入日志，代理请求不受影响。"
        alert.runModal()
        render()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTracking = false
        render()
    }

    @objc func measureModel(_ sender: NSButton) {
        guard let button = sender as? ModelProbeButton, button.isEnabled else { return }
        let service = button.service, id = button.modelID
        let key = "\(service):\(id)"
        if case .measuring? = modelLatencies[key] { return }
        modelLatencies[key] = .measuring
        button.show(.measuring)
        let started = ProcessInfo.processInfo.systemUptime
        let request: [String: Any] = ["model": id, "messages": [["role": "user", "content": "请只回复 OK"]], "stream": true]
        var streamFailed = false
        let onData: (Data) -> Void = { data in
            if String(data: data, encoding: .utf8)?.contains("upstream_error") == true { streamFailed = true }
        }
        let completion: (Error?) -> Void = { [weak self, weak button] error in
            let seconds = ProcessInfo.processInfo.systemUptime - started
            let failed = error != nil || streamFailed
            RunLoop.main.perform(inModes: [.common, .eventTracking]) { [weak self] in
                let result: ModelLatency = failed ? .failed(seconds) : .measured(seconds)
                self?.modelLatencies[key] = result
                button?.show(result)
            }
        }
        if service == "workbuddy" {
            workBuddyClient.chat(request, onStart: {}, onData: onData, completion: completion)
        } else if service == "trae" {
            traeClient.chat(request, onStart: {}, onData: onData, completion: completion)
        }
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

    @objc func showTokenDateRange() {
        if let window = tokenDateWindow {
            tokenStartPicker?.maxDate = Date()
            tokenEndPicker?.maxDate = Date()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 252),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "按日期查询用量"
        window.isReleasedWhenClosed = false
        window.center()
        guard let content = window.contentView else { return }
        content.addSubview(label("查询历史用量", frame: NSRect(x: 24, y: 202, width: 352, height: 27), size: 21, weight: .semibold))
        content.addSubview(label("选择日期范围，查看费用与 Token 明细。", frame: NSRect(x: 24, y: 178, width: 352, height: 18), size: 12, color: .secondaryLabelColor))
        content.addSubview(CardSurface(frame: NSRect(x: 24, y: 68, width: 352, height: 98)))
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = tokenUsageRange?.start ?? quota?.weeklyRange(now: now)?.start ?? calendar.startOfDay(for: now)
        let end = tokenUsageRange?.end.addingTimeInterval(-1) ?? now
        for (index, name) in ["开始日期", "结束日期"].enumerated() {
            let y = CGFloat(128 - index * 40)
            let label = NSTextField(labelWithString: name)
            label.frame = NSRect(x: 40, y: y, width: 74, height: 22)
            let picker = NSDatePicker(frame: NSRect(x: 132, y: y - 2, width: 226, height: 26))
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .yearMonthDay
            picker.calendar = calendar
            picker.timeZone = .current
            picker.maxDate = now
            picker.dateValue = index == 0 ? start : end
            picker.setAccessibilityLabel(name)
            content.addSubview(label)
            content.addSubview(picker)
            if index == 0 { tokenStartPicker = picker } else { tokenEndPicker = picker }
        }
        let hint = NSTextField(labelWithString: "包含开始和结束当天")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 24, y: 25, width: 170, height: 18)
        let cancel = NSButton(title: "取消", target: window, action: #selector(NSWindow.performClose(_:)))
        cancel.frame = NSRect(x: 208, y: 19, width: 76, height: 30)
        let query = NSButton(title: "查询", target: self, action: #selector(applyTokenDateRange))
        query.frame = NSRect(x: 296, y: 19, width: 80, height: 30)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        query.bezelStyle = .rounded
        query.keyEquivalent = "\r"
        [hint, cancel, query].forEach { content.addSubview($0) }
        tokenDateWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func applyTokenDateRange() {
        guard let start = tokenStartPicker?.dateValue, let end = tokenEndPicker?.dateValue else { return }
        do {
            tokenUsageRange = try CodexTokenUsageReader.dateRange(from: start, through: end)
        } catch {
            let alert = NSAlert()
            alert.messageText = "日期区间无效"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        tokenUsage = nil
        tokenUsageError = nil
        tokenDateWindow?.close()
        refreshTokenUsage()
        render()
    }

    @objc func selectUsageDevice(_ sender: NSMenuItem) {
        featureDefaults.set(sender.representedObject as? String, forKey: "usageDevice")
        tokenUsage = nil
        refreshTokenUsage()
        render()
    }

    @objc func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 530),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex Helper 设置"
        window.isReleasedWhenClosed = false
        window.center()
        guard let content = window.contentView else { return }
        content.addSubview(symbol("slider.horizontal.3", frame: NSRect(x: 24, y: 461, width: 38, height: 38)))
        content.addSubview(label("偏好设置", frame: NSRect(x: 76, y: 478, width: 360, height: 29), size: 23, weight: .semibold))
        content.addSubview(label("按你的工作方式，配置 Helper。", frame: NSRect(x: 76, y: 456, width: 360, height: 18), size: 12, color: .secondaryLabelColor))
        content.addSubview(label("集成服务", frame: NSRect(x: 26, y: 416, width: 410, height: 20), size: 12, weight: .semibold, color: .secondaryLabelColor))
        content.addSubview(CardSurface(frame: NSRect(x: 24, y: 148, width: 412, height: 258)))

        let workBuddy = NSButton(checkboxWithTitle: "启用 WorkBuddy 功能", target: self, action: #selector(settingsChanged))
        workBuddy.state = workBuddyEnabled ? .on : .off
        workBuddyEnabledButton = workBuddy
        let trae = NSButton(checkboxWithTitle: "启用 Trae 代理", target: self, action: #selector(settingsChanged))
        trae.state = traeEnabled ? .on : .off
        traeEnabledButton = trae
        let openCodex = NSButton(checkboxWithTitle: "启用 OpenCodex 功能", target: self, action: #selector(settingsChanged))
        openCodex.state = openCodexEnabled ? .on : .off
        openCodex.toolTip = "检测 OpenCodex 安装、运行状态并显示相关操作"
        openCodexEnabledButton = openCodex
        let cloud = NSButton(checkboxWithTitle: "通过 iCloud 同步用量", target: self, action: #selector(settingsChanged))
        cloud.state = usageCloudEnabled ? .on : .off
        cloud.toolTip = "跨设备同步用量统计，不同步对话内容或账号凭据"
        usageCloudEnabledButton = cloud
        let integrations: [(NSButton, String)] = [
            (workBuddy, "管理账号、积分与本地模型代理"),
            (trae, "连接 Trae 模型与独立账号池"),
            (openCodex, "查看运行状态、配置与控制代理"),
            (cloud, "跨设备汇总统计，不同步对话内容")
        ]
        for (index, entry) in integrations.enumerated() {
            let y = CGFloat(372 - index * 62)
            entry.0.frame = NSRect(x: 40, y: y, width: 376, height: 22)
            entry.0.font = .systemFont(ofSize: 13, weight: .medium)
            content.addSubview(entry.0)
            content.addSubview(label(entry.1, frame: NSRect(x: 60, y: y - 21, width: 354, height: 17), size: 11, color: .secondaryLabelColor))
            if index < integrations.count - 1 {
                let line = NSBox(frame: NSRect(x: 40, y: y - 32, width: 376, height: 1))
                line.boxType = .separator
                content.addSubview(line)
            }
        }
        content.addSubview(CardSurface(frame: NSRect(x: 24, y: 70, width: 412, height: 64)))
        content.addSubview(label("自动刷新", frame: NSRect(x: 40, y: 105, width: 200, height: 18), weight: .medium))
        content.addSubview(label("每 5–3600 秒更新一次额度", frame: NSRect(x: 40, y: 84, width: 220, height: 17), size: 11, color: .secondaryLabelColor))
        let field = NSTextField(string: String(Int(refreshInterval)))
        field.frame = NSRect(x: 310, y: 89, width: 70, height: 26)
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        field.formatter = NumberFormatter()
        field.delegate = self
        field.setAccessibilityLabel("刷新间隔秒数")
        intervalField = field
        content.addSubview(field)
        content.addSubview(label("秒", frame: NSRect(x: 390, y: 92, width: 28, height: 20), color: .secondaryLabelColor))
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        save.frame = NSRect(x: 334, y: 20, width: 102, height: 32)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        settingsSaveButton = save
        content.addSubview(save)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        content.addSubview(label("Codex Helper \(version) · Build \(build)", frame: NSRect(x: 26, y: 26, width: 300, height: 18), size: 11, color: .secondaryLabelColor))
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
    featureDefaults.set(enabled, forKey: "workBuddyEnabled")
    let traeOn = traeEnabledButton?.state == .on
    featureDefaults.set(traeOn, forKey: "traeEnabled")
    featureDefaults.set(openCodexEnabledButton?.state == .on, forKey: "openCodexEnabled")
    featureDefaults.set(usageCloudEnabledButton?.state == .on, forKey: "usageCloudEnabled")
    tokenUsage = nil
    refreshTokenUsage()
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
    refreshOcxStatus()
    render()
        settingsSaveButton?.isEnabled = false
        let alert = NSAlert()
        alert.messageText = "设置已保存"
        alert.runModal()
    }

    func setOcxBusy(_ busy: Bool, message: String? = nil) {
        ocxBusy = busy
        let ocxInstalled = openCodexEnabled && executable(named: "ocx") != nil
    ocxActionItems.forEach { $0.isEnabled = !busy && ocxInstalled }
    ocxWorkBuddyConfigItem?.isEnabled = !busy && ocxInstalled && workBuddyCLIInstalled
    ocxTraeConfigItem?.isEnabled = !busy && ocxInstalled && traeRouteAvailable
        if let message {
            ocxStatusText = message
            ocxStatusItem?.title = message
        }
    }

    @objc func refreshOcxStatus() {
        guard openCodexEnabled, !ocxBusy, !ocxChecking else { return }
        guard executable(named: "ocx") != nil else {
            ocxStatusText = "未检测到 OpenCodex"
            ocxStatusItem?.title = ocxStatusText
            return
        }
        ocxChecking = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try runCommand("ocx", ["health", "--json"], timeout: 5, includeStandardError: false) }
            DispatchQueue.main.async {
                self.ocxChecking = false
                guard self.openCodexEnabled else { return }
                switch result {
                case .success(let health):
                    let running = health.data(using: .utf8)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["ok"] as? Bool
                    self.ocxStatusText = running.map { $0 ? "OpenCodex Running" : "OpenCodex Stop" } ?? "OpenCodex 状态不可用"
                case .failure:
                    self.ocxStatusText = "OpenCodex 状态不可用"
                }
                self.ocxStatusItem?.title = self.ocxStatusText
            }
        }
    }

    func runOcx(_ commands: [[String]], progress: String, success: String,
                completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard openCodexEnabled else { return }
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
        guard openCodexEnabled, workBuddyRouteAvailable, executable(named: "ocx") != nil else {
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
        guard openCodexEnabled, traeRouteAvailable, executable(named: "ocx") != nil else {
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
        guard openCodexEnabled else { return }
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
    let featureDefaults = UserDefaults(suiteName: "local.codex.helper.self-test.\(UUID().uuidString)")!
    let settingsDelegate = AppDelegate()
    settingsDelegate.featureDefaults = featureDefaults
    precondition(!settingsDelegate.workBuddyEnabled && !settingsDelegate.traeEnabled && !settingsDelegate.openCodexEnabled && !settingsDelegate.usageCloudEnabled)
    precondition(!settingsDelegate.workBuddyRouteAvailable && !settingsDelegate.traeRouteAvailable)
    settingsDelegate.ocxStatusText = "unchecked"
    settingsDelegate.refreshOcxStatus()
    settingsDelegate.runOcx([["--version"]], progress: "unexpected", success: "unexpected")
    precondition(!settingsDelegate.ocxChecking && !settingsDelegate.ocxBusy && settingsDelegate.ocxStatusText == "unchecked")
    featureDefaults.setVolatileDomain(["workBuddyEnabled": true, "traeEnabled": true, "openCodexEnabled": true],
                                     forName: UserDefaults.argumentDomain)
    precondition(settingsDelegate.workBuddyEnabled && settingsDelegate.traeEnabled && settingsDelegate.openCodexEnabled)
    try CodexTokenUsageReader.selfTest()
    try CodexResponseTimingReader.selfTest()
    try CodexUsageSync.selfTest()
    let sample = #"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300},"secondary":null},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":0,"windowDurationMins":300},"secondary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":1789368213},"planType":"plus"}}}"#
    let parsed = try JSONDecoder().decode(Quota.self, from: Data(sample.utf8))
    precondition(parsed.title == "5h: 100% · 1w: 94%")
    precondition(parsed.statusBarTitle == "5h: 100%\n1w: 94%")
    precondition(parsed.buckets[0].1.windows[1].label == "7天")
    let reset = Date(timeIntervalSince1970: 1789368213)
    let currentWeek = parsed.weeklyRange(now: reset.addingTimeInterval(-1))!
    precondition(currentWeek.end == reset && currentWeek.duration == 7 * 24 * 60 * 60)
    precondition(parsed.weeklyRange(now: currentWeek.start) == currentWeek)
    precondition(parsed.weeklyRange(now: currentWeek.start.addingTimeInterval(-0.001)) == nil)
    precondition(parsed.weeklyRange(now: reset) == nil)
    precondition(Window(usedPercent: 110, windowDurationMins: nil, resetsAt: nil).remaining == 0)
    precondition(Window(usedPercent: -10, windowDurationMins: 60, resetsAt: nil).remaining == 100)
    precondition(Window(usedPercent: 99.1, windowDurationMins: 60, resetsAt: nil).remaining == 0)
    let legacy = try JSONDecoder().decode(Quota.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}"#.utf8))
    precondition(legacy.title == "5h: 75%")
    precondition(legacy.statusBarTitle == "5h\n75%")
    precondition(legacy.weeklyRange() == nil)
    let weekly = try JSONDecoder().decode(Quota.self, from: Data(#"{"rateLimits":{"primary":null,"secondary":{"usedPercent":0,"windowDurationMins":10080}}}"#.utf8))
    precondition(weekly.title == "1w: 100%")
    precondition(weekly.statusBarTitle == "1w\n100%")
    precondition(weekly.weeklyRange() == nil)
    let weeklyPrimary = try JSONDecoder().decode(Quota.self, from: Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":6,"windowDurationMins":10080}}}}"#.utf8))
    precondition(weeklyPrimary.statusBarTitle == "1w\n94%")
    let primaryWithReset = try JSONDecoder().decode(Quota.self, from: Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":1789368213}}}}"#.utf8))
    precondition(primaryWithReset.weeklyRange(now: reset.addingTimeInterval(-1)) == currentWeek)
    let empty = try JSONDecoder().decode(Quota.self, from: Data(#"{"rateLimits":null,"rateLimitsByLimitId":{}}"#.utf8))
    precondition(empty.title == "额度暂无")
    precondition(empty.statusBarTitle == "额度暂无")
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
    precondition(modelLatencyTier(1.99) == 0 && modelLatencyTier(2) == 1)
    precondition(modelLatencyTier(4.99) == 1 && modelLatencyTier(5) == 2)
    let cleanHealth = try runCommand("sh", ["-c", "printf '%s' '{\"ok\":true}'; printf '%s' warning >&2"],
                                     timeout: 5, includeStandardError: false)
    precondition(cleanHealth == "{\"ok\":true}")
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
    try ProxyDebugLog.selfTest()
    TraeClient.selfTest()
    TraeAccountPool.selfTest()
    print("PASS: 配额解析、本地 Token 统计、账号限流识别、WorkBuddy Chat 转发与 Trae Chat 翻译")
} else if CommandLine.arguments.contains("--check-token-usage") {
    let weeklyRange = (try? readQuota())?.weeklyRange()
    let cloud = UserDefaults.standard.bool(forKey: "usageCloudEnabled") ? CodexUsageSync() : nil
    let snapshot = try CodexTokenUsageReader().read(weeklyRange: weeklyRange, sync: cloud,
        device: UserDefaults.standard.string(forKey: "usageDevice"))
    print("本机 Token 用量 · \(snapshot.timeZone)")
    if let message = snapshot.syncMessage { print(message) }
    for device in snapshot.devices { print("设备：\(device.name)；数据更新：\(device.updated?.description ?? "暂无")") }
    if weeklyRange == nil { print("当前周额度：周期暂不可用") }
    for period in snapshot.periods {
        print("\(period.name)：\(CodexTokenPricing.dollars(period.estimatedUSD))；\(try period.total.total) tokens；\(period.interval.start) 至 \(period.interval.end)")
        for (group, amounts) in period.models.sorted(by: { $0.key.title < $1.key.title }) {
            let costs = period.costs[group] ?? CodexTokenCosts()
            let performance = period.performance[group] ?? CodexOutputPerformance()
            print("  \(group.title)：\(CodexTokenPricing.dollars(costs.total))；\(performance.label)；\(performance.sampleLabel)；" + costs.rows(amounts: amounts).joined(separator: "；"))
        }
    }
    print("读取失败：\(snapshot.unreadableFiles)；跳过异常或缺失用量：\(snapshot.skippedEvents)")
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
