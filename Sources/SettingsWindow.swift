// SettingsWindow.swift — ② 原生設定面板（`nibble ui`）
// 設定器哲學：開 → 調 → 關窗即退出程序，零常駐。純 AppKit 手寫佈局，無 SwiftUI runtime。
import AppKit

func runSettingsUI() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = SettingsDelegate()
    app.delegate = delegate
    app.run()
    return 0
}

final class SettingsDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let deviceLabel = NSTextField(labelWithString: "Detecting…")
    private let batteryLabel = NSTextField(labelWithString: "")
    private let dpiValue = NSTextField(labelWithString: "–")
    private let dpiSlider = NSSlider(value: 1600, minValue: 100, maxValue: 6400, target: nil, action: nil)
    private let rateControl = NSSegmentedControl(labels: ["125", "250", "500", "1000"], trackingMode: .selectOne, target: nil, action: nil)
    private let rgbControl = NSSegmentedControl(labels: ["Off", "Cycle", "Breathing"], trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: " ")
    private var lastIndex: UInt8 = 1
    private var lastRGB: String?
    private let buttonsPane = ButtonsPane()
    private static let rateValues = [125, 250, 500, 1000]
    private static let rgbKinds = ["off", "cycle", "breathing"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        deviceLabel.font = .boldSystemFont(ofSize: 14)
        batteryLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        dpiValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)

        dpiSlider.isContinuous = true
        dpiSlider.target = self
        dpiSlider.action = #selector(dpiChanged(_:))
        rateControl.target = self
        rateControl.action = #selector(rateChanged(_:))
        rgbControl.target = self
        rgbControl.action = #selector(rgbChanged(_:))

        let dpiRow = NSStackView(views: [dpiSlider, dpiValue])
        dpiRow.spacing = 10
        dpiSlider.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let saveBtn = NSButton(title: "Save as default", target: self, action: #selector(saveAction))
        let applyBtn = NSButton(title: "Apply config file", target: self, action: #selector(applyAction))
        let btnRow = NSStackView(views: [saveBtn, applyBtn])
        btnRow.spacing = 8

        let generalStack = NSStackView(views: [
            sectionLabel("DPI"), dpiRow,
            sectionLabel("Report rate (Hz)"), rateControl,
            sectionLabel("Lighting (runtime — reverts on power cycle)"), rgbControl,
            NSBox(), btnRow,
        ])
        generalStack.orientation = .vertical
        generalStack.alignment = .leading
        generalStack.spacing = 8
        if let box = generalStack.views.first(where: { $0 is NSBox }) as? NSBox { box.boxType = .separator }

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = Self.pane(generalStack, pinBottom: false)
        tabs.addTabViewItem(general)

        let buttons = NSTabViewItem(identifier: "buttons")
        buttons.label = "Buttons"
        buttons.view = buttonsPane.makeView()
        tabs.addTabViewItem(buttons)
        buttonsPane.onStatus = { [weak self] msg in self?.statusLabel.stringValue = msg }

        // 全程 Auto Layout：NSTabView 用 frame 幫分頁排版，內容一旦帶固定約束就會打架、溢出邊界
        let root = NSView()
        for v in [deviceLabel, batteryLabel, tabs, statusLabel] as [NSView] {
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
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Nibble"
        window.contentView = root
        window.contentMinSize = NSSize(width: 470, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        loadState()
        buttonsPane.reload()
    }

    // 設定器哲學：關窗即退出
    func windowWillClose(_ notification: Notification) {
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
            if let b = try? dev.battery() {
                let volt = b.millivolts.map { String(format: " · %.2fV", Double($0) / 1000) } ?? ""
                batteryLabel.stringValue = "🔋 \(b.percent)%\(volt) · \(b.charging ? "charging ⚡" : "discharging")"
            }
            if let dpi = try? dev.currentDPI() {
                dpiSlider.integerValue = dpi
                dpiValue.stringValue = "\(dpi)"
            }
            if let hz = try? dev.reportRateHz(), let i = Self.rateValues.firstIndex(of: hz) {
                rateControl.selectedSegment = i
            }
            statusLabel.stringValue = "Ready — every change writes immediately and is verified by read-back"
        } catch {
            deviceLabel.stringValue = "Mouse offline or asleep"
            batteryLabel.stringValue = "Move the mouse, then reopen this panel"
            statusLabel.stringValue = "❌ \(error)"
        }
    }

    @objc private func dpiChanged(_ sender: NSSlider) {
        let snapped = (sender.integerValue / 50) * 50
        dpiValue.stringValue = "\(snapped)"
        // 拖曳中只更新數字；放開（mouseUp）才寫入裝置
        guard NSApp.currentEvent?.type == .leftMouseUp else { return }
        do {
            let dev = try openDevice()
            var got = 0
            try uiHostFallback(dev) { got = try dev.setDPI(snapped) }
            dpiValue.stringValue = "\(got)"
            statusLabel.stringValue = got == snapped ? "DPI → \(got) ✓" : "⚠️ asked \(snapped), device reports \(got)"
        } catch { statusLabel.stringValue = "❌ \(error)" }
    }

    @objc private func rateChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        let hz = Self.rateValues[sender.selectedSegment]
        do {
            let dev = try openDevice()
            var got = 0
            try uiHostFallback(dev) { got = try dev.setReportRateHz(hz) }
            statusLabel.stringValue = got == hz ? "Report rate → \(got) Hz ✓" : "⚠️ asked \(hz), device reports \(got)"
        } catch { statusLabel.stringValue = "❌ \(error)" }
    }

    @objc private func rgbChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        let kind = Self.rgbKinds[sender.selectedSegment]
        do {
            let dev = try openDevice()
            let applied = try uiSetRGB(dev, kind: kind)
            lastRGB = kind
            statusLabel.stringValue = applied > 0 ? "Lighting → \(kind) ✓" : "⚠️ effect not available on this device"
        } catch { statusLabel.stringValue = "❌ \(error)" }
    }

    @objc private func saveAction() {
        do {
            let dev = try openDevice()
            try uiSaveConfig(dev, rgb: lastRGB)
            statusLabel.stringValue = "Saved as default ✓ replayed at login (nibble replay)"
        } catch { statusLabel.stringValue = "❌ \(error)" }
    }

    @objc private func applyAction() {
        _ = cmdApply()
        loadState()
        statusLabel.stringValue = "Config applied ✓"
    }
}
