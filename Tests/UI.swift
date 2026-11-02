import AppKit

@main
struct UICheck {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        let defaults = UserDefaults(suiteName: "local.codex.helper.ui-check")!
        defaults.setVolatileDomain(["workBuddyEnabled": false, "traeEnabled": false,
                                   "openCodexEnabled": false, "usageCloudEnabled": false],
                                  forName: UserDefaults.argumentDomain)
        delegate.featureDefaults = defaults
        delegate.showSettings()
        delegate.showTokenDateRange()
        let settings = delegate.settingsWindow!
        precondition([delegate.workBuddyEnabledButton, delegate.traeEnabledButton,
                      delegate.openCodexEnabledButton, delegate.usageCloudEnabledButton].allSatisfy {
            $0?.state == .off && $0?.action == #selector(AppDelegate.settingsChanged)
        })
        delegate.settingsSaveButton?.isEnabled = false
        delegate.settingsChanged()
        precondition(delegate.settingsSaveButton?.isEnabled == true)
        let dateWindow = app.windows.first { $0.title == "按日期查询用量" }!
        let pickers = dateWindow.contentView!.subviews.compactMap { $0 as? NSDatePicker }
        precondition(pickers.count == 2 && pickers.allSatisfy { $0.maxDate != nil })
        for rawPlan in ["prolite", "pro_lite", "ProLite"] {
            let heading = quotaHeading("Codex", plan: rawPlan)
            let fields = heading.subviews.compactMap { $0 as? NSTextField }
            precondition(fields.map(\.stringValue) == ["Codex", "ProLite"])
            precondition(fields[0].font!.pointSize > fields[1].font!.pointSize)
        }
        precondition(quotaHeading("Codex", plan: nil).subviews.count == 1)
        let warning = "⚠ 无法读取额度，请确认 Codex 已使用 ChatGPT 账户登录"
        precondition(quotaHeading("Codex", plan: "prolite").subviews[0].frame.minX == 14)
        precondition(menuInfo("提示").subviews[0].frame.minX == 14)
        let shortInfo = menuInfo("显示上次结果，请刷新后确认")
        let longInfo = menuInfo(warning)
        precondition(longInfo.frame.width == shortInfo.frame.width)
        precondition(longInfo.frame.height > shortInfo.frame.height)
        precondition((longInfo.subviews.first as? NSTextField)?.stringValue == warning)
        func menuWidth(_ view: NSView) -> CGFloat {
            let menu = NSMenu()
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
            return menu.size.width
        }
        precondition(menuWidth(longInfo) == menuWidth(shortInfo), "Long warnings must not widen the menu")
        let now = Date()
        delegate.quota = Quota(rateLimits: Bucket(limitName: nil, primary: nil,
            secondary: Window(usedPercent: 6, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(86400).timeIntervalSince1970),
            planType: "prolite"), rateLimitsByLimitId: nil)
        let week = delegate.quota!.weeklyRange()!
        let custom = try CodexTokenUsageReader.dateRange(from: now.addingTimeInterval(-86400), through: now)
        let group = CodexTokenUsageGroup(model: "gpt-6.1-sol", tier: .fast)
        let amounts = CodexTokenAmounts(input: 100, output: 10)
        let periods = [("今日", DateInterval(start: now.addingTimeInterval(-3600), duration: 7200)),
                       ("当前周额度", week), ("自选区间", custom)].map { name, range in
            var period = CodexTokenUsagePeriod(name: name, interval: range)
            period.models[group] = amounts
            return period
        }
        let snapshot = CodexTokenUsageSnapshot(periods: periods, updated: now, timeZone: "Asia/Shanghai",
            unreadableFiles: 0, skippedEvents: 0,
            devices: [CodexUsageDevice(id: UUID().uuidString, name: "Test Mac", updated: now)], syncMessage: "iCloud · 已读取 2 台设备的数据")
        defaults.setVolatileDomain(["workBuddyEnabled": false, "traeEnabled": false,
                                   "openCodexEnabled": false, "usageCloudEnabled": true],
                                  forName: UserDefaults.argumentDomain)
        delegate.setUsageForUICheck(snapshot, range: custom)
        delegate.status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(delegate.status) }
        delegate.render()
        let menu = delegate.status.menu!
        let usageStart = menu.items.firstIndex { $0.title == "费用估算 · USD" }!
        let usageEnd = menu.items.firstIndex { $0.title == "按日期区间查询…" }!
        func noViewTooltips(_ view: NSView) {
            precondition(view.toolTip == nil, "An informational view must not cover the submenu")
            view.subviews.forEach(noViewTooltips)
        }
        func noMenuTooltips(_ item: NSMenuItem) {
            precondition(item.toolTip == nil, "Hover obscures statistics: \(item.title)")
            if let view = item.view { noViewTooltips(view) }
            item.submenu?.items.forEach(noMenuTooltips)
        }
        menu.items[usageStart...usageEnd].forEach(noMenuTooltips)
        for name in ["今日", "当前周额度", "自选区间"] {
            let item = menu.items.first { $0.title.hasPrefix(name) }!
            let notes = item.submenu!.items.compactMap { ($0.view?.subviews.first as? NSTextField)?.stringValue }
            precondition(notes.contains { $0.contains("Asia/Shanghai") && $0.contains(" 至 ") }, "Keep the date range visible without hovering")
        }
        let source = menu.items.first { $0.title.hasPrefix("统计来源：") }!
        precondition(source.submenu!.items.contains { ($0.view?.subviews.first as? NSTextField)?.stringValue.hasPrefix("数据更新于 ") == true })
        let intervalText = (menu.items.first { $0.title.hasPrefix("当前周额度") }!.submenu!.items.last!.view!.subviews.first as! NSTextField).stringValue
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: appearance)
            let theme = appearance == .aqua ? "light" : "dark"
            for (name, view) in [("warning", menuInfo(warning)),
                                  ("sync-warning", menuInfo("⚠ iCloud 暂不可用，保留本机及已缓存的其他设备用量；部分用量尚未写入 iCloud，下次自动重试")),
                                  ("usage-interval", menuInfo(intervalText)),
                                  ("heading", quotaHeading("Codex", plan: "prolite")),
                                  ("heading-no-plan", quotaHeading("Codex", plan: nil)),
                                  ("settings", settings.contentView!), ("date", dateWindow.contentView!),
                                  ("quota", quotaRow(Window(usedPercent: 6, windowDurationMins: 10080, resetsAt: 1793659200), stale: false)),
                                  ("low", quotaRow(Window(usedPercent: 96, windowDurationMins: 300, resetsAt: nil), stale: false)),
                                  ("stale", quotaRow(Window(usedPercent: 0, windowDurationMins: 300, resetsAt: nil), stale: true))] {
                view.appearance = app.appearance
                view.layoutSubtreeIfNeeded()
                for child in view.subviews {
                    precondition(view.bounds.contains(child.frame), "Clipped view in \(name): \(child.frame)")
                    if let text = child as? NSTextField, !text.isEditable, text.preferredMaxLayoutWidth == 0 {
                        precondition(text.intrinsicContentSize.width <= text.frame.width + 1,
                                     "Truncated label in \(name): \(text.stringValue)")
                    }
                }
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.appearance!.performAsCurrentDrawingAppearance {
                    view.displayIfNeeded()
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
                let image = NSImage(size: view.bounds.size)
                image.lockFocus()
                (appearance == .aqua ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.15, alpha: 1)).setFill()
                view.bounds.fill()
                NSImage(cgImage: bitmap.cgImage!, size: view.bounds.size).draw(in: view.bounds)
                image.unlockFocus()
                let composed = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try composed.representation(using: .png, properties: [:])!.write(
                    to: URL(fileURLWithPath: ".build/ui-check/\(name)-\(theme).png"))
            }
        }
        settings.close()
        dateWindow.close()
        print("PASS: light/dark UI, label bounds, settings, dates, and no hover tooltips throughout usage menus")
    }
}
