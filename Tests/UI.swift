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
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: appearance)
            let theme = appearance == .aqua ? "light" : "dark"
            for (name, view) in [("warning", menuInfo(warning)),
                                  ("sync-warning", menuInfo("⚠ iCloud 暂不可用，保留本机及已缓存的其他设备用量；部分用量尚未写入 iCloud，下次自动重试")),
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
        print("PASS: light/dark UI snapshots, label bounds, settings actions and date controls")
    }
}
