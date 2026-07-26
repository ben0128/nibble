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
    private let deviceItem = NSMenuItem(title: L("Detecting…", "偵測中…"), action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var dpiItems: [Int: NSMenuItem] = [:]
    private var rateItems: [Int: NSMenuItem] = [:]
    private var rgbItems: [String: NSMenuItem] = [:]
    private var lastIndex: UInt8 = 1
    private var lastRGB: String?   // 協定無法回讀燈效，追蹤本 session 設過的值
    private var engine: RemapEngineProtocol?
    private var lowBatteryNotified = false
    private var configWatch: DispatchSourceFileSystemObject?
    private var flashWork: DispatchWorkItem?
    private var batteryTitle = "🖱…"
    private var permissionDenied = false
    private var dpiRoot: NSMenuItem!
    private var rateRoot: NSMenuItem!
    private var rgbRoot: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var openSettingsItem: NSMenuItem!
    private let engineItem = NSMenuItem(title: L("Remapping: off", "改鍵引擎：未啟用"), action: nil, keyEquivalent: "")

    static let dpiPresets = [400, 800, 1600, 3200, 6400, 12800]
    static let ratePresets = [1000, 500, 250, 125]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖱…"

        let menu = NSMenu()
        menu.delegate = self   // menuWillOpen → refresh，開選單永遠是新狀態
        menu.addItem(deviceItem)
        menu.addItem(detailItem)

        // 權限未授權時才出現的引導（可點，直接開系統設定）
        permissionItem = makeItem(L("⚠️ Input Monitoring required", "⚠️ 需要「輸入監控」權限"), #selector(openInputMonitoring))
        openSettingsItem = makeItem(L("Open System Settings…", "開啟系統設定…"), #selector(openInputMonitoring))
        permissionItem.isHidden = true
        openSettingsItem.isHidden = true
        menu.addItem(permissionItem)
        menu.addItem(openSettingsItem)

        menu.addItem(engineItem)
        menu.addItem(.separator())

        dpiRoot = NSMenuItem(title: "DPI", action: nil, keyEquivalent: "")
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

        rateRoot = NSMenuItem(title: L("Report rate", "回報率"), action: nil, keyEquivalent: "")
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

        rgbRoot = NSMenuItem(title: L("Lighting", "燈效"), action: nil, keyEquivalent: "")
        let rgbMenu = NSMenu()
        for (title, kind) in [(L("Off (power saving ⚡)", "關燈（省電 ⚡）"), "off"),
                              (L("Cycle", "Cycle 循環"), "cycle"),
                              (L("Breathing", "Breathing 呼吸"), "breathing")] {
            let item = NSMenuItem(title: title, action: #selector(setRGBAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind
            rgbMenu.addItem(item)
            rgbItems[kind] = item
        }
        rgbRoot.submenu = rgbMenu
        menu.addItem(rgbRoot)

        menu.addItem(.separator())
        menu.addItem(makeItem(L("Settings…", "設定面板…"), #selector(openPanelAction), key: ","))
        menu.addItem(makeItem(L("Refresh now", "立即更新"), #selector(refreshAction), key: "r"))
        menu.addItem(makeItem(L("Save as default", "存為預設（登入自動重放）"), #selector(saveAction)))
        menu.addItem(makeItem(L("Apply config file", "套用設定檔"), #selector(applyAction)))
        menu.addItem(.separator())
        menu.addItem(makeItem(L("About Nibble \(NIBBLE_VERSION)", "關於 Nibble \(NIBBLE_VERSION)"), #selector(aboutAction)))
        menu.addItem(makeItem(L("Quit (mouse keeps working)", "結束（滑鼠照常運作）"), #selector(quitAction), key: "q"))
        statusItem.menu = menu

        refresh()
        startEngine()
        watchConfig()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// 監看設定檔：設定面板或 CLI 改完 config，引擎自動重載——使用者不必記得手動重新載入
    private func watchConfig() {
        configWatch?.cancel()
        let fd = open(bmConfigURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .rename, .delete, .extend],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // 存檔常是「換檔」而非就地寫入 → 重新掛監看
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.startEngine()
                self.watchConfig()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatch = src
    }

    /// 操作回饋：選單點完就關，訊息寫在選單裡沒人看得到 → 讓狀態列圖示短暫顯示結果
    private func flash(_ text: String, revertAfter: TimeInterval = 1.6) {
        flashWork?.cancel()
        statusItem.button?.title = text
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusItem.button?.title = self.batteryTitle
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + revertAfter, execute: work)
    }

    /// 改鍵引擎：讀 config 的 per-device 映射，掛上 spy 事件流（G 系路徑）
    private func startEngine() {
        engine?.stop()
        engine = nil
        guard let maps = loadConfig()?.buttonMaps, !maps.isEmpty else {
            engineItem.title = L("Remapping: none configured", "改鍵：尚未設定（用設定面板或 nibble remap）")
            return
        }
        do {
            let dev = try openDevice()
            let devName = (try? dev.name()) ?? "unknown"
            guard let devMap = maps[devName], !devMap.isEmpty else {
                engineItem.title = L("Remapping: none for \(devName)", "改鍵：此裝置（\(devName)）無映射")
                return
            }
            let needsAX = devMap.values.contains { $0.type == "keys" || $0.type == "system" }
            if needsAX && !axTrusted(promptIfNeeded: true) {
                engineItem.title = L("Remapping: ⚠️ grant Accessibility, then Refresh", "改鍵：⚠️ 授權「輔助使用」後點立即更新")
                return
            }
            guard let tr = dev.transport as? ReceiverTransport,
                  let eng = makeRemapEngine(transport: tr, dev: dev, savedMap: devMap) else {
                engineItem.title = L("Remapping: unsupported device", "改鍵：此裝置不支援（無 0x8110／0x1b04）")
                return
            }
            try eng.start()
            engine = eng   // engine 持有 dev+transport → 事件流常駐
            engineItem.title = L("Remapping: ✓ \(eng.mappingCount) active", "改鍵：✓ \(eng.mappingCount) 個映射運作中")
        } catch {
            engineItem.title = L("Remapping: ❌ \(error)", "改鍵：❌ \(error)")
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

    /// 同步勾選狀態，並把現值寫進父列——不用展開子選單就看得到目前設定
    private func syncChecks(_ dev: HIDPPDevice) {
        let curDPI = (try? dev.currentDPI()) ?? -1
        for (v, item) in dpiItems { item.state = (v == curDPI) ? .on : .off }
        dpiRoot.title = curDPI > 0 ? "DPI\t\(curDPI)" : "DPI"
        let curRate = (try? dev.reportRateHz()) ?? -1
        for (v, item) in rateItems { item.state = (v == curRate) ? .on : .off }
        rateRoot.title = curRate > 0 ? L("Report rate\t\(curRate) Hz", "回報率\t\(curRate) Hz") : L("Report rate", "回報率")
        // 燈效無法回讀，只能顯示本 session 設過的值
        for (kind, item) in rgbItems { item.state = (kind == lastRGB) ? .on : .off }
        let rgbLabel = lastRGB.map { $0 == "off" ? L("Off", "關閉") : $0.capitalized }
        rgbRoot.title = L("Lighting", "燈效") + (rgbLabel.map { "\t\($0)" } ?? "")
    }

    private func setPermissionUI(denied: Bool) {
        permissionDenied = denied
        permissionItem.isHidden = !denied
        openSettingsItem.isHidden = !denied
        dpiRoot.isHidden = denied
        rateRoot.isHidden = denied
        rgbRoot.isHidden = denied
        engineItem.isHidden = denied
    }

    private func refresh() {
        do {
            let dev = try openDevice()
            setPermissionUI(denied: false)
            deviceItem.title = (try? dev.name()) ?? "Logitech #\(lastIndex)"
            if let b = try? dev.battery() {
                let warn = b.percent <= 15 && !b.charging
                batteryTitle = "\(warn ? "⚠️" : "🖱")\(b.percent)%"
                if flashWork == nil || flashWork!.isCancelled { statusItem.button?.title = batteryTitle }
                let volt = b.millivolts.map { String(format: " · %.2fV", Double($0) / 1000) } ?? ""
                detailItem.title = "\(b.charging ? L("Charging ⚡", "充電中 ⚡") : L("Discharging", "放電中"))\(volt)"
                notifyLowBatteryIfNeeded(percent: b.percent, charging: b.charging, device: deviceItem.title)
            }
            syncChecks(dev)
        } catch let e as HIDPPError {
            if case .transport(let msg) = e, msg.contains("輸入監控") || msg.contains("Input Monitoring") {
                batteryTitle = "🖱⚠️"
                statusItem.button?.title = batteryTitle
                deviceItem.title = L("Nibble can't read your mouse", "Nibble 讀不到你的滑鼠")
                detailItem.title = L("Grant Input Monitoring, then Refresh", "授權「輸入監控」後點立即更新")
                setPermissionUI(denied: true)
            } else {
                batteryTitle = "🖱💤"
                statusItem.button?.title = batteryTitle
                deviceItem.title = L("Mouse offline or asleep", "滑鼠離線／睡眠中")
                detailItem.title = L("Move the mouse, then Refresh", "晃兩下滑鼠再點立即更新")
                setPermissionUI(denied: false)
            }
        } catch {
            batteryTitle = "🖱💤"
            statusItem.button?.title = batteryTitle
            deviceItem.title = L("Mouse offline or asleep", "滑鼠離線／睡眠中")
            detailItem.title = "\(error)"
        }
    }

    @objc private func refreshAction() { refresh(); flash("🔄") }

    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func aboutAction() {
        let alert = NSAlert()
        alert.messageText = "Nibble \(NIBBLE_VERSION)"
        alert.informativeText = L("""
            Lightweight Logitech mouse control for macOS.
            All writes are runtime — a power cycle restores the mouse.
            Quitting Nibble never breaks your mouse.

            github.com/ben0128/nibble · MIT
            """, """
            輕量羅技滑鼠控制工具。
            所有寫入都是 runtime——滑鼠斷電即回復原狀。
            結束 Nibble 不會影響滑鼠正常使用。

            github.com/ben0128/nibble · MIT
            """)
        alert.addButton(withTitle: "GitHub")
        alert.addButton(withTitle: L("Close", "關閉"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/ben0128/nibble")!)
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
            detailItem.title = got == target ? "DPI → \(got) ✓" : L("⚠️ asked \(target), device reports \(got)", "⚠️ 要求 \(target)，回讀 \(got)")
            flash(got == target ? "✓\(got)" : "⚠️\(got)")
        }
    }

    @objc private func setRateAction(_ sender: NSMenuItem) {
        guard let hz = sender.representedObject as? Int else { return }
        act { dev in
            var got = 0
            try uiHostFallback(dev) { got = try dev.setReportRateHz(hz) }
            detailItem.title = got == hz ? L("Report rate → \(got) Hz ✓", "回報率 → \(got) Hz ✓") : L("⚠️ asked \(hz), device reports \(got)", "⚠️ 要求 \(hz)，回讀 \(got)")
            flash(got == hz ? "✓\(got)Hz" : "⚠️\(got)Hz")
        }
    }

    @objc private func setRGBAction(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        let title = sender.title
        act { dev in
            let applied = try uiSetRGB(dev, kind: kind)
            lastRGB = kind
            detailItem.title = applied > 0 ? "RGB → \(title) ✓" : L("⚠️ effect not available on this device", "⚠️ 裝置沒有這個燈效")
            flash(applied > 0 ? (kind == "off" ? "✓💡" : "✓🌈") : "⚠️")
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
            detailItem.title = L("Saved as default ✓ replayed at login", "已存為預設 ✓ 登入時自動重放")
            flash("✓💾")
        }
    }

    @objc private func applyAction() {
        _ = cmdApply()
        refresh()
        detailItem.title = L("Config applied ✓", "設定檔已套用 ✓")
        flash("✓⚙️")
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}
