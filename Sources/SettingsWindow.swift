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
    private let deviceLabel = NSTextField(labelWithString: "偵測中…")
    private let batteryLabel = NSTextField(labelWithString: "")
    private let dpiValue = NSTextField(labelWithString: "–")
    private let dpiSlider = NSSlider(value: 1600, minValue: 100, maxValue: 6400, target: nil, action: nil)
    private let rateControl = NSSegmentedControl(labels: ["125", "250", "500", "1000"], trackingMode: .selectOne, target: nil, action: nil)
    private let rgbControl = NSSegmentedControl(labels: ["關燈 ⚡", "Cycle", "Breathing"], trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: " ")
    private var lastIndex: UInt8 = 1
    private var lastRGB: String?
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

        let saveBtn = NSButton(title: "存為預設", target: self, action: #selector(saveAction))
        let applyBtn = NSButton(title: "套用設定檔", target: self, action: #selector(applyAction))
        let btnRow = NSStackView(views: [saveBtn, applyBtn])
        btnRow.spacing = 8

        let stack = NSStackView(views: [
            deviceLabel, batteryLabel,
            sectionLabel("DPI"), dpiRow,
            sectionLabel("回報率（Hz）"), rateControl,
            sectionLabel("燈效（runtime，斷電回復）"), rgbControl,
            NSBox(), btnRow, statusLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 12, right: 20)
        if let box = stack.views.first(where: { $0 is NSBox }) as? NSBox { box.boxType = .separator }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Nibble"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        loadState()
    }

    // 設定器哲學：關窗即退出
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

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
                batteryLabel.stringValue = "🔋 \(b.percent)%\(volt) · \(b.charging ? "充電中 ⚡" : "放電中")"
            }
            if let dpi = try? dev.currentDPI() {
                dpiSlider.integerValue = dpi
                dpiValue.stringValue = "\(dpi)"
            }
            if let hz = try? dev.reportRateHz(), let i = Self.rateValues.firstIndex(of: hz) {
                rateControl.selectedSegment = i
            }
            statusLabel.stringValue = "就緒（所有變更即時寫入，寫後回讀驗證）"
        } catch {
            deviceLabel.stringValue = "滑鼠離線／睡眠中"
            batteryLabel.stringValue = "晃兩下滑鼠後重開面板"
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
            statusLabel.stringValue = got == snapped ? "DPI → \(got) ✓" : "⚠️ 要求 \(snapped)，回讀 \(got)"
        } catch { statusLabel.stringValue = "❌ \(error)" }
    }

    @objc private func rateChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        let hz = Self.rateValues[sender.selectedSegment]
        do {
            let dev = try openDevice()
            var got = 0
            try uiHostFallback(dev) { got = try dev.setReportRateHz(hz) }
            statusLabel.stringValue = got == hz ? "回報率 → \(got) Hz ✓" : "⚠️ 要求 \(hz)，回讀 \(got)"
        } catch { statusLabel.stringValue = "❌ \(error)" }
    }

    @objc private func rgbChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        let kind = Self.rgbKinds[sender.selectedSegment]
        do {
            let dev = try openDevice()
            let applied = try uiSetRGB(dev, kind: kind)
            lastRGB = kind
            statusLabel.stringValue = applied > 0 ? "RGB → \(kind) ✓" : "⚠️ 裝置沒有這個燈效"
        } catch { statusLabel.stringValue = "❌ \(error)" }
    }

    @objc private func saveAction() {
        do {
            let dev = try openDevice()
            try uiSaveConfig(dev, rgb: lastRGB)
            statusLabel.stringValue = "已存為預設 ✓ 登入時自動重放（nibble replay）"
        } catch { statusLabel.stringValue = "❌ \(error)" }
    }

    @objc private func applyAction() {
        _ = cmdApply()
        loadState()
        statusLabel.stringValue = "設定檔已套用 ✓"
    }
}
