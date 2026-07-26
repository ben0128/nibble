// MenuBar.swift — 互動式選單列（opt-in 常駐；AppKit NSStatusItem）
// UI 哲學：選單即控制台——新增 RAM ≈ 0（NSStatusItem 的錢已經付了）。
// 每個動作直接呼叫 HIDPPCore API，寫後同步勾選狀態。共用邏輯在 Commands.swift 的 ui* 助手。
import AppKit
import UserNotifications

func runMenuBar() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // 無 Dock 圖示
    let delegate = MenuBarDelegate()
    app.delegate = delegate
    app.run()
    return 0
}

final class MenuBarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let deviceItem = NSMenuItem(title: "偵測中…", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var dpiItems: [Int: NSMenuItem] = [:]
    private var rateItems: [Int: NSMenuItem] = [:]
    private var lastIndex: UInt8 = 1
    private var lastRGB: String?   // 協定無法回讀燈效，追蹤本 session 設過的值
    private var engine: RemapEngineProtocol?
    private var lowBatteryNotified = false
    private let engineItem = NSMenuItem(title: "改鍵引擎：未啟用", action: nil, keyEquivalent: "")

    static let dpiPresets = [400, 800, 1600, 3200, 6400, 12800]
    static let ratePresets = [1000, 500, 250, 125]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖱…"

        let menu = NSMenu()
        menu.delegate = self   // menuWillOpen → refresh，開選單永遠是新狀態
        menu.addItem(deviceItem)
        menu.addItem(detailItem)
        menu.addItem(engineItem)
        menu.addItem(.separator())

        let dpiRoot = NSMenuItem(title: "DPI", action: nil, keyEquivalent: "")
        let dpiMenu = NSMenu()
        for v in Self.dpiPresets {
            let item = NSMenuItem(title: "\(v)", action: #selector(setDPIAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v
            dpiMenu.addItem(item)
            dpiItems[v] = item
        }
        dpiRoot.submenu = dpiMenu
        menu.addItem(dpiRoot)

        let rateRoot = NSMenuItem(title: "回報率", action: nil, keyEquivalent: "")
        let rateMenu = NSMenu()
        for v in Self.ratePresets {
            let item = NSMenuItem(title: "\(v) Hz", action: #selector(setRateAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v
            rateMenu.addItem(item)
            rateItems[v] = item
        }
        rateRoot.submenu = rateMenu
        menu.addItem(rateRoot)

        let rgbRoot = NSMenuItem(title: "RGB", action: nil, keyEquivalent: "")
        let rgbMenu = NSMenu()
        for (title, kind) in [("關燈（省電 ⚡）", "off"), ("Cycle 循環", "cycle"), ("Breathing 呼吸", "breathing")] {
            let item = NSMenuItem(title: title, action: #selector(setRGBAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind
            rgbMenu.addItem(item)
        }
        rgbRoot.submenu = rgbMenu
        menu.addItem(rgbRoot)

        menu.addItem(.separator())
        menu.addItem(makeItem("開啟設定面板…", #selector(openPanelAction)))
        menu.addItem(makeItem("重新載入改鍵引擎", #selector(reloadEngineAction)))
        menu.addItem(makeItem("存為預設（登入自動重放）", #selector(saveAction)))
        menu.addItem(makeItem("套用設定檔（apply）", #selector(applyAction)))
        menu.addItem(.separator())
        menu.addItem(makeItem("結束（滑鼠照常運作）", #selector(quitAction), key: "q"))
        statusItem.menu = menu

        refresh()
        startEngine()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// 改鍵引擎：讀 config 的 per-device 映射，掛上 spy 事件流（G 系路徑）
    private func startEngine() {
        engine?.stop()
        engine = nil
        guard let maps = loadConfig()?.buttonMaps, !maps.isEmpty else {
            engineItem.title = "改鍵引擎：未啟用（用 nibble remap 新增映射）"
            return
        }
        do {
            let dev = try openDevice()
            let devName = (try? dev.name()) ?? "unknown"
            guard let devMap = maps[devName], !devMap.isEmpty else {
                engineItem.title = "改鍵引擎：此裝置（\(devName)）無映射"
                return
            }
            let needsAX = devMap.values.contains { $0.type == "keys" || $0.type == "system" }
            if needsAX && !axTrusted(promptIfNeeded: true) {
                engineItem.title = "改鍵引擎：⚠️ 授權「輔助使用」後按重新載入"
                return
            }
            guard let tr = dev.transport as? ReceiverTransport,
                  let eng = makeRemapEngine(transport: tr, dev: dev, savedMap: devMap) else {
                engineItem.title = "改鍵引擎：此裝置不支援改鍵（無 0x8110／0x1b04）"
                return
            }
            try eng.start()
            engine = eng   // engine 持有 dev+transport → 事件流常駐
            engineItem.title = "改鍵引擎：✓ \(eng.mappingCount) 個映射運作中"
        } catch {
            engineItem.title = "改鍵引擎：❌ \(error)"
        }
    }

    @objc private func reloadEngineAction() { startEngine() }

    /// 低電量通知：需要 .app bundle（`make app`）；裸 binary 執行時靜默略過。
    /// 一次充放電週期只提醒一次，充電後重置。
    private func notifyLowBatteryIfNeeded(percent: Int, charging: Bool, device: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        if charging || percent > 15 { lowBatteryNotified = false; return }
        guard !lowBatteryNotified else { return }
        lowBatteryNotified = true
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(device) 電量 \(percent)%"
            content.body = "該充電了 🔌"
            center.add(UNNotificationRequest(identifier: "nibble.lowbattery",
                                             content: content, trigger: nil))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()   // 還原 spy remap 表——退出後滑鼠回到原生行為
    }

    private func makeItem(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func openDevice() throws -> HIDPPDevice {
        let (dev, idx) = try uiOpenDevice(preferred: lastIndex)
        lastIndex = idx
        return dev
    }

    private func syncChecks(_ dev: HIDPPDevice) {
        let curDPI = (try? dev.currentDPI()) ?? -1
        for (v, item) in dpiItems { item.state = (v == curDPI) ? .on : .off }
        let curRate = (try? dev.reportRateHz()) ?? -1
        for (v, item) in rateItems { item.state = (v == curRate) ? .on : .off }
    }

    private func refresh() {
        do {
            let dev = try openDevice()
            deviceItem.title = (try? dev.name()) ?? "Logitech #\(lastIndex)"
            if let b = try? dev.battery() {
                let warn = b.percent <= 15 && !b.charging
                statusItem.button?.title = "\(warn ? "⚠️" : "🖱")\(b.percent)%"
                let volt = b.millivolts.map { String(format: " · %.2fV", Double($0) / 1000) } ?? ""
                detailItem.title = "\(b.charging ? "充電中 ⚡" : "放電中")\(volt)"
                notifyLowBatteryIfNeeded(percent: b.percent, charging: b.charging,
                                         device: deviceItem.title)
            }
            syncChecks(dev)
        } catch {
            statusItem.button?.title = "🖱💤"
            deviceItem.title = "滑鼠離線／睡眠中"
            detailItem.title = "晃兩下滑鼠再開選單"
        }
    }

    private func act(_ body: (HIDPPDevice) throws -> Void) {
        do {
            let dev = try openDevice()
            try body(dev)
            syncChecks(dev)
        } catch {
            detailItem.title = "❌ \(error)"
        }
    }

    @objc private func setDPIAction(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? Int else { return }
        act { dev in
            var got = 0
            try uiHostFallback(dev) { got = try dev.setDPI(target) }
            detailItem.title = got == target ? "DPI → \(got) ✓" : "⚠️ DPI 要求 \(target)，回讀 \(got)"
        }
    }

    @objc private func setRateAction(_ sender: NSMenuItem) {
        guard let hz = sender.representedObject as? Int else { return }
        act { dev in
            var got = 0
            try uiHostFallback(dev) { got = try dev.setReportRateHz(hz) }
            detailItem.title = got == hz ? "回報率 → \(got) Hz ✓" : "⚠️ 回報率要求 \(hz)，回讀 \(got)"
        }
    }

    @objc private func setRGBAction(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        let title = sender.title
        act { dev in
            let applied = try uiSetRGB(dev, kind: kind)
            lastRGB = kind
            detailItem.title = applied > 0 ? "RGB → \(title) ✓" : "⚠️ 裝置沒有這個燈效"
        }
    }

    @objc private func openPanelAction() {
        guard let exe = Bundle.main.executablePath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["ui"]
        try? p.run()   // 獨立程序：面板關掉即退出，menubar 不揹它的記憶體
    }

    @objc private func saveAction() {
        act { dev in
            try uiSaveConfig(dev, rgb: lastRGB)
            detailItem.title = "已存為預設 ✓ 登入時自動重放"
        }
    }

    @objc private func applyAction() {
        _ = cmdApply()
        refresh()
        detailItem.title = "設定檔已套用 ✓"
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}
