// SettingsWindow.swift — ② 原生設定面板（`nibble ui`）
// 設定器哲學：開 → 調 → 關窗即退出程序，零常駐。純 AppKit 手寫佈局，無 SwiftUI runtime。
import AppKit

func runSettingsUI(initialTab: String? = nil) -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = SettingsDelegate()
    delegate.initialTab = initialTab
    app.delegate = delegate
    app.run()
    return 0
}

final class SettingsDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTabViewDelegate {
    private var window: NSWindow!
    private let deviceLabel = NSTextField(labelWithString: "Detecting…")
    private let batteryLabel = NSTextField(labelWithString: "")
    // DPI 用與選單列相同的級距——先前滑桿 100–6400、選單 400–3200、CLI 50–25600 三套並存
    private let dpiControl = NSSegmentedControl(labels: MenuBarDelegate.dpiPresets.map(String.init),
                                                trackingMode: .selectOne, target: nil, action: nil)
    private let dpiCustom = NSTextField(string: "")
    private let rateControl = NSSegmentedControl(labels: ["125", "250", "500", "1000"], trackingMode: .selectOne, target: nil, action: nil)
    private let rgbControl = NSSegmentedControl(labels: ["Off", "Cycle", "Breathing"], trackingMode: .selectOne, target: nil, action: nil)
    private let rgbNote = NSTextField(labelWithString: "Lighting can't be read back from the mouse")
    private let replayCheck = NSButton(checkboxWithTitle: "Re-apply my settings at login", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: " ")
    private let aboutButton = NSButton(title: "GitHub", target: nil, action: nil)
    private var lastIndex: UInt8 = 1
    private var lastRGB: String? = lastKnownRGB()
    private let buttonsPane = ButtonsPane()
    private var headerTimer: Timer?
    private var statusClear: DispatchWorkItem?
    var initialTab: String?
    private static let rateValues = [125, 250, 500, 1000]
    private static let rgbKinds = ["off", "cycle", "breathing"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        deviceLabel.font = .boldSystemFont(ofSize: 14)
        batteryLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        rgbControl.toolTip = "Written to the device immediately. The mouse has no way to report its current effect back, so Nibble shows the last one it applied."
        rateControl.toolTip = "Higher rates poll more often — smoother tracking, slightly more battery. Writing this requires host mode; Nibble switches automatically."
        replayCheck.toolTip = "Installs a one-shot launchd agent that runs `nibble apply` at login. It exits immediately after — nothing stays resident."
        for note in [rgbNote] {
            note.font = .systemFont(ofSize: 11)
            note.textColor = .tertiaryLabelColor
        }

        dpiControl.target = self
        dpiControl.action = #selector(dpiPresetChanged)
        dpiControl.segmentDistribution = .fillEqually
        // 欄位只需容納 5 位數；全寬的輸入框會讓人以為要填長字串
        dpiCustom.placeholderString = "50–25600"
        dpiCustom.toolTip = "Any value the sensor accepts. A DPI set with the mouse's own buttons shows up here when it isn't one of the presets."
        dpiCustom.target = self
        dpiCustom.action = #selector(dpiCustomCommitted)
        dpiCustom.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dpiCustom.alignment = .right
        dpiCustom.translatesAutoresizingMaskIntoConstraints = false
        dpiCustom.widthAnchor.constraint(equalToConstant: 74).isActive = true
        replayCheck.target = self
        replayCheck.action = #selector(replayToggled)
        rateControl.target = self
        rateControl.action = #selector(rateChanged(_:))
        rgbControl.target = self
        rgbControl.action = #selector(rgbChanged(_:))

        let customCaption = NSTextField(labelWithString: "Custom")
        customCaption.font = .systemFont(ofSize: 11)
        customCaption.textColor = .secondaryLabelColor
        let dpiCustomRow = NSStackView(views: [customCaption, dpiCustom])
        dpiCustomRow.spacing = 6
        dpiCustomRow.alignment = .centerY

        // 「斷電就沒了」是必須理解的行為模型，解法（登入重放）就擺在同一段，不再散落各處
        let lifecycle = NSTextField(wrappingLabelWithString:
            "Changes apply instantly and are lost when the mouse powers off.")
        lifecycle.font = .systemFont(ofSize: 11)
        lifecycle.textColor = .secondaryLabelColor
        let saveBtn = NSButton(title: "Save current as my settings", target: self, action: #selector(saveAction))
        let startupRow = NSStackView(views: [replayCheck, saveBtn])
        startupRow.spacing = 12

        let generalStack = NSStackView(views: [
            sectionLabel("DPI"), dpiControl, dpiCustomRow,
            sectionLabel("Report rate (Hz)"), rateControl,
            sectionLabel("Lighting"), rgbControl, rgbNote,
            NSBox(), lifecycle, startupRow,
        ])
        generalStack.orientation = .vertical
        generalStack.alignment = .leading
        generalStack.spacing = 8
        if let box = generalStack.views.first(where: { $0 is NSBox }) as? NSBox { box.boxType = .separator }

        let tabs = NSTabView()
        tabs.delegate = self
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = Self.pane(generalStack, pinBottom: false)
        tabs.addTabViewItem(general)

        let buttons = NSTabViewItem(identifier: "buttons")
        buttons.label = "Buttons"
        buttons.view = buttonsPane.makeView()
        tabs.addTabViewItem(buttons)
        buttonsPane.onStatus = { [weak self] msg in self?.setStatus(msg) }

        // 版本資訊從選單列搬來這裡：選單留給日常操作，關於資訊屬於設定視窗
        aboutButton.bezelStyle = .inline
        aboutButton.isBordered = false
        aboutButton.target = self
        aboutButton.action = #selector(openRepo)
        // 「GitHub」用強調色標示可點，版本號用次要色——一眼分得出哪部分是連結
        let footer = NSMutableAttributedString(string: "GitHub", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.controlAccentColor,
        ])
        footer.append(NSAttributedString(string: "  ·  v\(NIBBLE_VERSION)", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        aboutButton.attributedTitle = footer
        aboutButton.toolTip = "github.com/ben0128/nibble — MIT"
        aboutButton.setContentHuggingPriority(.required, for: .horizontal)
        aboutButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 全程 Auto Layout：NSTabView 用 frame 幫分頁排版，內容一旦帶固定約束就會打架、溢出邊界
        let root = NSView()
        for v in [deviceLabel, batteryLabel, tabs, statusLabel, aboutButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.usesSingleLineMode = true
        statusLabel.cell?.truncatesLastVisibleLine = true
        // 關鍵：不讓長字串把視窗頂寬——標籤讓步，超長就截斷
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        deviceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        deviceLabel.lineBreakMode = .byTruncatingTail
        batteryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            deviceLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            deviceLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            deviceLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),

            batteryLabel.topAnchor.constraint(equalTo: deviceLabel.bottomAnchor, constant: 2),
            batteryLabel.leadingAnchor.constraint(equalTo: deviceLabel.leadingAnchor),
            batteryLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),

            tabs.topAnchor.constraint(equalTo: batteryLabel.bottomAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: aboutButton.leadingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            aboutButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            aboutButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
        ])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Nibble"
        window.contentView = root
        window.contentMinSize = NSSize(width: 640, height: 450)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if initialTab == "buttons" { tabs.selectTabViewItem(withIdentifier: "buttons") }
        loadState()
        buttonsPane.reload()
        headerTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.refreshHeader()
        }
    }

    /// 狀態列是兩個分頁共用的，訊息卻是當下情境的——不清掉的話，
    /// 在 General 觸發的警告會跟著你飄到 Buttons 分頁，看起來像在講別的事。
    private func setStatus(_ text: String, sticky: Bool = false) {
        statusClear?.cancel()
        statusLabel.stringValue = text
        guard !sticky, !text.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.statusLabel.stringValue = "" }
        statusClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        setStatus("")
    }

    // 設定器哲學：關窗即退出
    func windowWillClose(_ notification: Notification) {
        headerTimer?.invalidate()
        buttonsPane.teardown()
        NSApp.terminate(nil)
    }

    /// 分頁內容統一包一層容器，四邊用約束釘住——這樣分頁縮放時內容跟著走，不會溢出
    static func pane(_ content: NSView, pinBottom: Bool) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        var cs = [
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ]
        cs.append(pinBottom
            ? content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
            : content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12))
        NSLayoutConstraint.activate(cs)
        return container
    }

    @objc private func openRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/ben0128/nibble")!)
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func openDevice() throws -> HIDPPDevice {
        let (dev, idx) = try uiOpenDevice(preferred: lastIndex)
        lastIndex = idx
        return dev
    }

    private func loadState() {
        do {
            let dev = try openDevice()
            deviceLabel.stringValue = (try? dev.name()) ?? "Logitech #\(lastIndex)"
            updateBattery(dev)
            if let tr = dev.transport as? ReceiverTransport {
                // 連線細節屬於除錯資訊，放 hover；表頭留給名字和電量
                deviceLabel.toolTip = String(format: "%@ 046D:%04X · device index %d · HID++",
                                             tr.isDirect ? "bluetooth-direct" : "receiver",
                                             tr.productID, Int(lastIndex))
            }
            if let dpi = try? dev.currentDPI() { showDPI(dpi) }
            if let hz = try? dev.reportRateHz(), let i = Self.rateValues.firstIndex(of: hz) {
                rateControl.selectedSegment = i
            }
            let supported = (try? dev.supportedReportRatesHz()) ?? []
            // 支援清單放 tooltip：它和上面那排按鈕通常一模一樣，常駐顯示只是重複
            if !supported.isEmpty {
                rateControl.toolTip = "This device supports "
                    + supported.sorted().map(String.init).joined(separator: " / ") + " Hz. "
                    + "Writing the rate requires host mode; Nibble switches automatically."
            }
            showLighting()
            replayCheck.state = FileManager.default.fileExists(atPath: replayPlistURL.path) ? .on : .off
            setStatus("Ready")
        } catch {
            deviceLabel.stringValue = "Mouse offline or asleep"
            batteryLabel.stringValue = "Move the mouse, then reopen this panel"
            setStatus("❌ \(error)", sticky: true)
        }
    }

    /// 只更新表頭；失敗就沿用上次的值，不要把畫面清空或跳錯誤
    /// （選單列的引擎同時握著裝置，偶爾搶不到很正常）
    private func refreshHeader() {
        guard let dev = try? openDevice() else { return }
        updateBattery(dev)
    }

    private func updateBattery(_ dev: HIDPPDevice) {
        guard let b = try? dev.battery() else { return }
        let volt = b.millivolts.map { String(format: " · %.2fV", Double($0) / 1000) } ?? ""
        batteryLabel.stringValue = "🔋 \(b.percent)%\(volt) · \(b.charging ? "charging" : "discharging")"
    }

    /// 現值若不在級距上（例如滑鼠上的 DPI 鍵調出來的），就顯示在 Custom 欄位而不是假裝選中某一格
    private func showDPI(_ dpi: Int) {
        if let i = MenuBarDelegate.dpiPresets.firstIndex(of: dpi) {
            dpiControl.selectedSegment = i
            dpiCustom.stringValue = ""
        } else {
            dpiControl.selectedSegment = -1
            dpiCustom.stringValue = "\(dpi)"
        }
    }

    private func showLighting() {
        if let kind = lastRGB, let i = Self.rgbKinds.firstIndex(of: kind) {
            rgbControl.selectedSegment = i
            rgbNote.stringValue = ""   // 知道值就不必每次都提醒但書，tooltip 裡有
        } else {
            rgbControl.selectedSegment = -1
            rgbNote.stringValue = "Current effect is unknown — the mouse can't report it back"
        }
    }

    private func applyDPI(_ target: Int) {
        do {
            let dev = try openDevice()
            var got = 0
            try uiHostFallback(dev) { got = try dev.setDPI(target) }
            showDPI(got)
            statusLabel.stringValue = got == target ? "DPI → \(got) ✓" : "⚠️ asked \(target), device reports \(got)"
        } catch { setStatus("❌ \(error)") }
    }

    @objc private func dpiPresetChanged() {
        guard dpiControl.selectedSegment >= 0 else { return }
        applyDPI(MenuBarDelegate.dpiPresets[dpiControl.selectedSegment])
    }

    @objc private func dpiCustomCommitted() {
        let text = dpiCustom.stringValue.trimmingCharacters(in: .whitespaces)
        guard let v = Int(text), (50...25600).contains(v) else {
            setStatus("⚠️ DPI must be a number between 50 and 25600")
            return
        }
        applyDPI(v)
    }

    @objc private func replayToggled() {
        let on = replayCheck.state == .on
        _ = cmdReplay([on ? "install" : "uninstall"])
        replayCheck.state = FileManager.default.fileExists(atPath: replayPlistURL.path) ? .on : .off
        statusLabel.stringValue = replayCheck.state == .on
            ? "Settings will be re-applied at login ✓"
            : "Login re-apply turned off"
    }

    @objc private func rateChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        let hz = Self.rateValues[sender.selectedSegment]
        do {
            let dev = try openDevice()
            var got = 0
            try uiHostFallback(dev) { got = try dev.setReportRateHz(hz) }
            statusLabel.stringValue = got == hz ? "Report rate → \(got) Hz ✓" : "⚠️ asked \(hz), device reports \(got)"
        } catch { setStatus("❌ \(error)") }
    }

    @objc private func rgbChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        let kind = Self.rgbKinds[sender.selectedSegment]
        do {
            let dev = try openDevice()
            let applied = try uiSetRGB(dev, kind: kind)
            lastRGB = kind
            showLighting()
            statusLabel.stringValue = applied > 0 ? "Lighting → \(kind) ✓" : "⚠️ effect not available on this device"
        } catch { setStatus("❌ \(error)") }
    }

    @objc private func saveAction() {
        do {
            let dev = try openDevice()
            try uiSaveConfig(dev, rgb: lastRGB)
            statusLabel.stringValue = replayCheck.state == .on
                ? "Saved ✓ these settings come back at login"
                : "Saved ✓ tick the box to have them re-applied at login"
        } catch { setStatus("❌ \(error)") }
    }
}
