// MenuBar.swift — 互動式選單列（opt-in 常駐；AppKit NSStatusItem）
// UI 哲學：選單即控制台——新增 RAM ≈ 0（NSStatusItem 的錢已經付了）。
// 每個動作直接呼叫 HIDPPCore API，寫後同步勾選狀態。共用邏輯在 Commands.swift 的 ui* 助手。
import AppKit
import UserNotifications

/// 單一實例保護：重複啟動會在選單列疊出第二個圖示，兩個程序還會搶同一個 HID 裝置。
/// 用檔案鎖而非檢查程序名——後者在 .app 與 CLI 混用時不可靠。
/// var 而非 let：測試要能把探測指向暫存檔，否則這段跨程序邏輯無法驗證
var menuBarLockURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/nibble/menubar.lock")

/// 從別的程序判斷選單列還活著沒：試搶它的鎖，搶到就馬上放掉。
/// 不用 pgrep——設定視窗是同一個 binary 跑出來的子程序，比對程序名會把自己算進去。
func menuBarRunning() -> Bool {
    let fd = open(menuBarLockURL.path, O_WRONLY)   // 不建檔：沒有這個檔就代表從沒跑過
    guard fd >= 0 else { return false }
    defer { close(fd) }
    // 只有「搶到了」能證明沒人在跑。EWOULDBLOCK 是有人握著，其他 errno
    //（網路家目錄不支援 flock 等）代表探測本身失效——那就假設在跑，
    // 跟 acquireMenuBarLock 的偏向一致（它也選擇別擋使用者）。
    // 反過來回 false 會讓 doctor 和健康狀態列謊報「改鍵沒在跑」。
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
    return true
}

private func acquireMenuBarLock() -> Bool {
    let dir = menuBarLockURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(menuBarLockURL.path, O_CREAT | O_WRONLY, 0o644)
    guard fd >= 0 else { return true }   // 拿不到鎖檔就別擋使用者
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        let blocked = errno == EWOULDBLOCK   // 其他 errno 代表檔案系統不支援等狀況，別擋使用者
        close(fd)
        if !blocked { return true }
        return false
    }
    return true   // 故意不關 fd：鎖跟著程序生命週期，退出時由系統釋放
}

func runMenuBar() -> Int32 {
    guard acquireMenuBarLock() else {
        // 從 Finder 啟動時沒有終端機可印訊息——直接把既有那個實例叫到前面才看得出發生什麼事
        print("Nibble menu bar is already running.")
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            others.first?.activate()
        }
        return 0
    }
    nibbleFastTooltips()
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
    private let deviceItem = NSMenuItem(title: "Detecting…", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var dpiItems: [Int: NSMenuItem] = [:]
    private var rateItems: [Int: NSMenuItem] = [:]
    private var rgbItems: [String: NSMenuItem] = [:]
    private var lastIndex: UInt8 = 1
    private var lastRGB: String? = lastKnownRGB()   // 協定無法回讀，改用設定檔記著的最後套用值
    private var engine: RemapEngineProtocol?
    private var lowBatteryLatch = LowBatteryLatch()
    /// 圖示轉紅的門檻，跟著低電量通知的設定走。每次 refresh() 重讀——
    /// 先前掛在 startEngine() 裡，而那條路在「沒有任何改鍵映射」時根本不會被走到
    /// （refresh() 的呼叫有 !activeButtonMaps.isEmpty 的條件），於是只想用電量監看的人
    /// 改了門檻，通知照新值發、圖示卻停在舊值直到重開程式
    private var warnPercent = defaultLowBatteryPercent
    private var refreshing = false
    private var settingsProcess: Process?
    private var engineNeedsAX = false
    private var engineRetryScheduled = false
    private var engineRetryDelay: TimeInterval = 4
    private var axPrompted = false
    private var configWatch: DispatchSourceFileSystemObject?
    private var flashWork: DispatchWorkItem?
    private var batteryPercent: Int?
    private var batteryCharging = false
    private var statusTooltip = "Nibble"
    private var permissionDenied = false
    private var dpiRoot: NSMenuItem!
    private var rateRoot: NSMenuItem!
    private var rgbRoot: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var openSettingsItem: NSMenuItem!
    private var remapRoot: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var profileRoot: NSMenuItem!
    private var remapPaused = false
    private let engineItem = NSMenuItem(title: "Remapping: off", action: nil, keyEquivalent: "")

    static let dpiPresets = [400, 800, 1200, 1600, 2000, 2400, 2800, 3200]
    static let ratePresets = [1000, 500, 250, 125]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusAppearance()

        let menu = NSMenu()
        menu.delegate = self   // menuWillOpen → refresh，開選單永遠是新狀態
        menu.addItem(deviceItem)
        menu.addItem(detailItem)

        // 權限未授權時才出現的引導（可點，直接開系統設定）
        permissionItem = makeItem("⚠️ Input Monitoring required", #selector(openInputMonitoring))
        openSettingsItem = makeItem("Open System Settings…", #selector(openInputMonitoring))
        permissionItem.isHidden = true
        openSettingsItem.isHidden = true
        menu.addItem(permissionItem)
        menu.addItem(openSettingsItem)

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

        rateRoot = NSMenuItem(title: "Report rate", action: nil, keyEquivalent: "")
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

        rgbRoot = NSMenuItem(title: "Lighting", action: nil, keyEquivalent: "")
        let rgbMenu = NSMenu()
        for (title, kind) in [("Off", "off"),
                              ("Cycle", "cycle"),
                              ("Breathing", "breathing")] {
            let item = NSMenuItem(title: title, action: #selector(setRGBAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind
            rgbMenu.addItem(item)
            rgbItems[kind] = item
        }
        rgbRoot.submenu = rgbMenu
        menu.addItem(rgbRoot)

        // 改鍵從一行唯讀訊息升級成可操作的子選單：暫停／恢復、看狀態、直接跳去編輯
        remapRoot = NSMenuItem(title: "Remapping", action: nil, keyEquivalent: "")
        let remapMenu = NSMenu()
        pauseItem = makeItem("Pause remapping", #selector(togglePause))
        profileRoot = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        profileRoot.submenu = NSMenu()
        remapMenu.addItem(profileRoot)
        remapMenu.addItem(.separator())
        remapMenu.addItem(pauseItem)
        remapMenu.addItem(engineItem)          // 狀態／失敗原因，必要時可點去開權限設定
        remapMenu.addItem(.separator())
        remapMenu.addItem(makeItem("Edit buttons…", #selector(openButtonsAction)))
        remapRoot.submenu = remapMenu
        menu.addItem(remapRoot)

        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", #selector(openPanelAction), key: ","))
        menu.addItem(makeItem("Save current settings", #selector(saveAction)))
        menu.addItem(makeItem("Refresh now", #selector(refreshAction), key: "r"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit (mouse keeps working)", #selector(quitAction), key: "q"))
        statusItem.menu = menu

        refresh()
        rebuildProfileMenu()
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

    /// 狀態列外觀：電量畫在滑鼠圖示裡（低電量轉紅），不再是「圖示＋文字」兩段
    private func applyStatusAppearance() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = StatusIcon.mouse(percent: batteryPercent, charging: batteryCharging)
        button.contentTintColor = (batteryPercent.map { $0 <= warnPercent } ?? false) && !batteryCharging ? .systemRed : nil
        button.toolTip = statusTooltip
    }

    /// 操作回饋：選單點完就關，訊息寫在選單裡沒人看得到 → 狀態列短暫顯示結果再變回圖示
    private func flash(_ text: String, revertAfter: TimeInterval = 1.6) {
        flashWork?.cancel()
        statusItem.button?.image = nil
        statusItem.button?.title = text
        let work = DispatchWorkItem { [weak self] in self?.applyStatusAppearance() }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + revertAfter, execute: work)
    }

    /// 改鍵引擎：讀 config 的 per-device 映射，掛上 spy 事件流（G 系路徑）
    private func startEngine() {
        engine?.stop()
        engine = nil
        defer { updateRemapSummary() }
        guard !remapPaused else { engineItem.title = "Paused — buttons behave normally"; return }
        engineNeedsAX = false
        engineItem.action = nil
        engineItem.target = nil
        let maps = activeButtonMaps(loadConfig())
        guard !maps.isEmpty else {
            engineItem.title = "Remapping: none configured"
            EngineState.writeStatus(["active": false, "reason": "no mappings configured", "mappings": 0, "axTrusted": axTrusted()])
            return
        }
        do {
            let dev = try openDevice()
            let devName = (try? dev.name()) ?? "unknown"
            guard let devMap = maps[devName], !devMap.isEmpty else {
                engineItem.title = "Remapping: none for \(devName)"
                EngineState.writeStatus(["active": false, "reason": "no mappings for \(devName)", "mappings": 0, "axTrusted": axTrusted()])
                return
            }
            let needsAX = devMap.values.contains { $0.type == "keys" || $0.type == "system" }
            // 只在第一次跳系統授權對話框，之後靜靜重試就好
            if needsAX && !axTrusted(promptIfNeeded: !axPrompted) {
                axPrompted = true
                // 這是最容易靜默失敗的一步：整列做成可點的捷徑，並寫進狀態檔讓 doctor 看得到
                engineNeedsAX = true
                engineItem.title = "Remapping: ⚠️ needs Accessibility — click here"
                engineItem.action = #selector(openAccessibility)
                engineItem.target = self
                EngineState.writeStatus(["active": false, "reason": "Accessibility permission not granted",
                                   "mappings": devMap.count, "axTrusted": false,
                                   "fix": "System Settings > Privacy & Security > Accessibility > add Nibble.app"])
                scheduleEngineRetry()
                return
            }
            guard let tr = dev.transport as? ReceiverTransport,
                  let eng = makeRemapEngine(transport: tr, dev: dev, savedMap: devMap) else {
                engineItem.title = "Remapping: unsupported device"
                EngineState.writeStatus(["active": false, "reason": "device exposes neither 0x8110 nor 0x1b04",
                                   "mappings": devMap.count, "axTrusted": axTrusted()])
                return
            }
            try eng.start()
            engine = eng   // engine 持有 dev+transport → 事件流常駐
            // 裝置消失（藍牙斷線、拔接收器）沒有 0x41 通知可等：拆掉引擎讓重試退避接手，
            // 否則引擎看似在跑、實際永遠收不到事件（弱引用：引擎換代後舊 callback 自動失效）
            tr.onRemoval = { [weak self, weak eng] in
                guard let self, let eng, self.engine === eng else { return }
                self.engine = nil
                eng.stop()
                self.engineItem.title = "Remapping: device disconnected — will retry"
                EngineState.writeStatus(["active": false, "reason": "device disconnected — waiting for reconnect",
                                         "axTrusted": axTrusted()])
                self.updateRemapSummary()
                self.scheduleEngineRetry()
            }
            engineRetryDelay = 4
            engineItem.title = "Remapping: ✓ \(eng.mappingCount) active"
            EngineState.writeStatus(["active": true, "reason": "running", "mappings": eng.mappingCount,
                               "axTrusted": axTrusted(), "device": devName,
                               "path": dev.has(0x8110) ? "0x8110 spy" : "0x1b04 divert"])
        } catch {
            engineItem.title = "Remapping: ❌ \(error)"
            EngineState.writeStatus(["active": false, "reason": "\(error)", "axTrusted": axTrusted(),
                               "mappings": maps.values.reduce(0, { $0 + $1.count })])
            scheduleEngineRetry()
        }
    }

    /// 啟動失敗（裝置睡著、被其他程序佔用、剛授權完）→ 排一次延遲重試，不必使用者手動
    private func scheduleEngineRetry() {
        guard !engineRetryScheduled else { return }
        engineRetryScheduled = true
        let delay = engineRetryDelay
        engineRetryDelay = min(engineRetryDelay * 2, 120)   // 退避到 2 分鐘：永久性失敗不該一直喚醒 USB
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.engineRetryScheduled = false
            guard let self, self.engine == nil else { return }
            self.startEngine()
        }
    }

    @objc private func togglePause() {
        remapPaused.toggle()
        if remapPaused {
            engine?.stop()
            engine = nil
            engineItem.title = "Paused — buttons behave normally"
            EngineState.writeStatus(["active": false, "reason": "paused by user"])
        } else {
            startEngine()
        }
        pauseItem.title = remapPaused ? "Resume remapping" : "Pause remapping"
        updateRemapSummary()
    }

    @objc private func openButtonsAction() { openPanel(tab: "buttons") }

    private func rebuildProfileMenu() {
        let cfg = loadConfig()
        let names = profileNames(cfg)
        let current = currentProfileName(cfg)
        let menu = NSMenu()
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(switchProfileAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit profiles…", action: #selector(openButtonsAction), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        profileRoot.submenu = menu
        profileRoot.title = names.count > 1 ? "Profile\t\(current)" : "Profile"
    }

    @objc private func switchProfileAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        do {
            try switchProfile(to: name)
            startEngine()          // 立即生效，不等檔案監看那 0.3 秒
            rebuildProfileMenu()
            flash("✓\(name.prefix(6))")
        } catch {
            detailItem.title = "❌ \(error)"
        }
    }

    /// 父列直接說明狀態，不必展開子選單
    private func updateRemapSummary() {
        let cfg = loadConfig()
        let profileTag = profileNames(cfg).count > 1 ? "\(currentProfileName(cfg)) · " : ""
        if remapPaused { remapRoot.title = "Remapping\tpaused"; return }
        if let e = engine, e.active { remapRoot.title = "Remapping\t\(profileTag)\(e.mappingCount) active" }
        else if activeButtonMaps(cfg).values.reduce(0, { $0 + $1.count }) == 0 {
            remapRoot.title = "Remapping\tnone"
        } else {
            remapRoot.title = "Remapping\t⚠️ not running"
        }
    }

    @objc private func reloadEngineAction() { startEngine() }

    /// 低電量通知：需要 .app bundle（`make app`）；裸 binary 執行時靜默略過。
    /// 一次充放電週期只提醒一次，充電後重置。門檻由設定檔決定（設定視窗可調、可關）。
    private func notifyLowBatteryIfNeeded(percent: Int, charging: Bool, device: String, limit: Int?) {
        // 通知需要真正的 .app（bundleIdentifier 在 repo 根目錄會誤判成有 bundle）
        guard runningFromAppBundle() else { return }
        guard lowBatteryLatch.shouldFire(percent: percent, charging: charging, limit: limit) else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(device) at \(percent)%"
            content.body = "Time to charge 🔌"
            center.add(UNNotificationRequest(identifier: "nibble.lowbattery",
                                             content: content, trigger: nil))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()   // 還原 spy remap 表——退出後滑鼠回到原生行為
        if let p = settingsProcess, p.isRunning { p.terminate() }
    }

    private func makeItem(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        return item
    }

    /// 選單先用快取值秒開，refresh 排到選單顯示之後再跑——同步做裝置 I/O 就是先前那個 lag
    func menuWillOpen(_ menu: NSMenu) {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
            self?.rebuildProfileMenu()
            self?.refreshing = false
        }
    }

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
        rateRoot.title = curRate > 0 ? "Report rate\t\(curRate) Hz" : "Report rate"
        // 燈效無法回讀，只能顯示本 session 設過的值
        for (kind, item) in rgbItems { item.state = (kind == lastRGB) ? .on : .off }
        let rgbLabel = lastRGB.map { $0 == "off" ? "Off" : $0.capitalized }
        rgbRoot.title = "Lighting" + (rgbLabel.map { "\t\($0)" } ?? "")
    }

    /// 讀不到裝置時：控制列變灰、父列不顯示過期數值（顯示舊值等於在說謊）
    private func setControlsLive(_ live: Bool) {
        for item in [dpiRoot, rateRoot, rgbRoot] { item?.isEnabled = live }
        if !live {
            dpiRoot.title = "DPI"
            rateRoot.title = "Report rate"
            rgbRoot.title = "Lighting"
        }
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
        // 一次讀設定檔，圖示門檻和通知門檻共用同一個值——兩者不同步過一次就再也對不回來
        let limit = lowBatteryThreshold(loadConfig())
        warnPercent = limit ?? defaultLowBatteryPercent
        do {
            let dev = try openDevice()
            setPermissionUI(denied: false)
            deviceItem.title = (try? dev.name()) ?? "Logitech #\(lastIndex)"
            if let b = try? dev.battery() {
                batteryPercent = b.percent
                batteryCharging = b.charging
                let volt = b.millivolts.map { String(format: " · %.2fV", Double($0) / 1000) } ?? ""
                detailItem.title = "\(b.percent)% · \(b.charging ? "charging ⚡" : "discharging")\(volt)"
                statusTooltip = "\(deviceItem.title) · \(b.percent)%\(volt)"
                applyStatusAppearance()
                notifyLowBatteryIfNeeded(percent: b.percent, charging: b.charging, device: deviceItem.title,
                                         limit: limit)
            }
            syncChecks(dev)
            setControlsLive(true)
            if engine == nil, !remapPaused, !activeButtonMaps(loadConfig()).isEmpty { startEngine() }
        } catch let e as HIDPPError {
            if case .transport(let msg) = e, msg.contains("Input Monitoring") {
                batteryPercent = nil
                statusTooltip = "Nibble — Input Monitoring permission required"
                applyStatusAppearance()
                deviceItem.title = "Nibble can't read your mouse"
                detailItem.title = "Grant Input Monitoring, then Refresh"
                setPermissionUI(denied: true)
            } else {
                batteryPercent = nil
                statusTooltip = "Nibble — mouse offline or asleep"
                applyStatusAppearance()
                deviceItem.title = "Mouse asleep"
                detailItem.title = "Move it to wake — values below are hidden until then"
                setPermissionUI(denied: false)
                setControlsLive(false)
            }
        } catch {
            batteryPercent = nil
            statusTooltip = "Nibble — \(error)"
            applyStatusAppearance()
            deviceItem.title = "Mouse offline"
            detailItem.title = "\(error)"
            setControlsLive(false)
        }
    }

    @objc private func refreshAction() { refresh(); flash("🔄") }

    @objc private func openAccessibility() { openAccessibilitySettings() }

    @objc private func openInputMonitoring() { openInputMonitoringSettings() }

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
            detailItem.title = got == target ? "DPI → \(got) ✓" : "⚠️ asked \(target), device reports \(got)"
            flash(got == target ? "✓\(got)" : "⚠️\(got)")
        }
    }

    @objc private func setRateAction(_ sender: NSMenuItem) {
        guard let hz = sender.representedObject as? Int else { return }
        act { dev in
            var got = 0
            try uiHostFallback(dev) { got = try dev.setReportRateHz(hz) }
            detailItem.title = got == hz ? "Report rate → \(got) Hz ✓" : "⚠️ asked \(hz), device reports \(got)"
            flash(got == hz ? "✓\(got)Hz" : "⚠️\(got)Hz")
        }
    }

    @objc private func setRGBAction(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        let title = sender.title
        act { dev in
            let applied = try uiSetRGB(dev, kind: kind)
            lastRGB = kind
            detailItem.title = applied > 0 ? "RGB → \(title) ✓" : "⚠️ effect not available on this device"
            flash(applied > 0 ? (kind == "off" ? "✓💡" : "✓🌈") : "⚠️")
        }
    }

    @objc private func openPanelAction() { openPanel(tab: nil) }

    private func openPanel(tab: String?) {
        // 已經開著就把它帶到最前面，不要每次點都開一個新視窗
        if let running = settingsProcess, running.isRunning {
            NSRunningApplication(processIdentifier: running.processIdentifier)?.activate()
            return
        }
        guard let exe = Bundle.main.executablePath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = tab.map { ["ui", $0] } ?? ["ui"]
        try? p.run()   // 獨立程序：面板關掉即退出，menubar 不揹它的記憶體
        settingsProcess = p
    }

    @objc private func saveAction() {
        act { dev in
            try uiSaveConfig(dev, rgb: lastRGB)
            detailItem.title = "Saved as default ✓ replayed at login"
            flash("✓💾")
        }
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}
