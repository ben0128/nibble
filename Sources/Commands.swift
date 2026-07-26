// Commands.swift — 指令層：status / battery / dump
import Foundation

/// 掃描一個 transport 上的裝置：接收器探測下掛索引 1–6，直連（藍牙）固定 0xFF
func discover(_ tr: ReceiverTransport, maxIndex: UInt8 = 6)
    -> [(idx: UInt8, dev: HIDPPDevice, ver: (major: Int, minor: Int))] {
    var out: [(idx: UInt8, dev: HIDPPDevice, ver: (major: Int, minor: Int))] = []
    if tr.isDirect {
        let d = HIDPPDevice(transport: tr, index: 0xFF)
        if let v = try? d.ping(timeout: 0.8) { out.append((0xFF, d, v)) }
        return out
    }
    for i in 1...maxIndex {
        let d = HIDPPDevice(transport: tr, index: i)
        if let v = try? d.ping(timeout: 0.6) { out.append((i, d, v)) }
    }
    // USB 上的 0xFF00 不一定是接收器——有線滑鼠（如 G502 插充電線）也在這頁，
    // 但它只回應直連索引 0xFF。1–6 都沒人時補問一次；真接收器會秒回 1.0 錯誤，不多花時間。
    if out.isEmpty {
        let d = HIDPPDevice(transport: tr, index: 0xFF)
        if let v = try? d.ping(timeout: 0.6) { out.append((0xFF, d, v)) }
    }
    return out
}

/// 走遍所有 transport（接收器優先），回傳所有醒著的裝置
func discoverEverything() throws -> [(idx: UInt8, dev: HIDPPDevice, tr: ReceiverTransport, ver: (major: Int, minor: Int))] {
    var out: [(idx: UInt8, dev: HIDPPDevice, tr: ReceiverTransport, ver: (major: Int, minor: Int))] = []
    for tr in try ReceiverTransport.openAll() {
        for hit in discover(tr) { out.append((hit.idx, hit.dev, tr, hit.ver)) }
    }
    return out
}

private func footer(since t0: Date) -> String {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    let ms = Date().timeIntervalSince(t0) * 1000
    let mb = Double(ru.ru_maxrss) / 1_048_576
    return String(format: " 0 daemons · query %.0f ms · peak RAM %.1f MB", ms, mb)
}

private func batteryBar(_ percent: Int) -> String {
    let filled = max(0, min(10, Int((Double(percent) / 10).rounded())))
    return "[" + String(repeating: "#", count: filled) + String(repeating: ".", count: 10 - filled) + "]"
}

func cmdStatus() -> Int32 {
    let t0 = Date()
    do {
        let devs = try discoverEverything()
        guard let hit = devs.first else {
            emitError("transport present but no awake device — move the mouse and retry",
                      code: "no-awake-device")
            return 1
        }
        let tr = hit.tr
        if jsonMode {
            let b = try? hit.dev.battery()
            emitJSON([
                "version": NIBBLE_VERSION,
                "device": (try? hit.dev.name()) ?? "unknown",
                "deviceIndex": Int(hit.idx),
                "receiverPID": String(format: "0x%04X", tr.productID),
                "hidppVersion": "\(hit.ver.major).\(hit.ver.minor)",
                "battery": b.map { ["percent": $0.percent, "millivolts": $0.millivolts as Any,
                                    "charging": $0.charging, "source": $0.source] } as Any,
                "dpi": (try? hit.dev.currentDPI()) as Any,
                "reportRateHz": (try? hit.dev.reportRateHz()) as Any,
                "features": ["onboardProfiles": hit.dev.has(0x8100),
                             "rgb": hit.dev.has(0x8071) || hit.dev.has(0x8070),
                             "smartShift": hit.dev.has(0x2110) || hit.dev.has(0x2111),
                             "remapSpy": hit.dev.has(0x8110), "remapDivert": hit.dev.has(0x1b04)],
                "otherDevicesOnline": devs.count - 1,
                "queryMs": Int(Date().timeIntervalSince(t0) * 1000),
            ])
            return 0
        }
        let dev = hit.dev
        let name = (try? dev.name()) ?? "Unknown"
        let rule = String(repeating: "─", count: 58)

        print("Nibble v\(NIBBLE_VERSION) ── \(name)")
        print(rule)
        let linkDesc = tr.isDirect
            ? "bluetooth-direct 046D:\(String(format: "%04X", tr.productID))\(tr.longOnly ? " · BLE long-only" : "")"
            : hit.idx == 0xFF
                ? "wired-usb 046D:\(String(format: "%04X", tr.productID))"
                : "receiver 046D:\(String(format: "%04X", tr.productID)) · device #\(hit.idx)"
        print(" link      HID++ \(hit.ver.major).\(hit.ver.minor) · \(linkDesc)")
        if let b = try? dev.battery() {
            let volt = b.millivolts.map { String(format: "%.2fV  ", Double($0) / 1000) } ?? ""
            print(" battery   \(batteryBar(b.percent)) \(b.percent)%  \(volt)\(b.charging ? "charging ⚡" : "discharging")  (\(b.source))")
        } else {
            print(" battery   —")
        }
        if let dpi = try? dev.currentDPI() { print(" dpi       \(dpi)") } else { print(" dpi       —") }
        if let hz = try? dev.reportRateHz() { print(" rate      \(hz) Hz") } else { print(" rate      —") }
        let flags = [
            ("onboard-profiles", dev.has(0x8100)),
            ("rgb", dev.has(0x8071) || dev.has(0x8070)),
            ("smartshift", dev.has(0x2110) || dev.has(0x2111)),
        ]
        print(" features  " + flags.map { "\($0.0) \($0.1 ? "✓" : "✗")" }.joined(separator: " · "))
        if devs.count > 1 {
            print(" others    \(devs.count - 1) more device(s) online (index \(devs.dropFirst().map { String($0.idx) }.joined(separator: ",")))")
        }
        print(rule)
        print(footer(since: t0))
        return 0
    } catch {
        print("❌ \(error)")
        return 2
    }
}

func cmdBattery() -> Int32 {
    do {
        guard let hit = try discoverEverything().first else {
            emitError("no awake device", code: "no-awake-device")
            return 1
        }
        let b = try hit.dev.battery()
        if jsonMode {
            emitJSON(["percent": b.percent, "millivolts": b.millivolts as Any,
                      "charging": b.charging, "source": b.source,
                      "device": (try? hit.dev.name()) ?? "unknown"])
        } else {
            let volt = b.millivolts.map { String(format: " %.2fV", Double($0) / 1000) } ?? ""
            print("\(b.percent)%\(volt) \(b.charging ? "charging" : "discharging")")
        }
        return 0
    } catch {
        emitError("\(error)", code: "transport")
        return 2
    }
}

// MARK: - doctor：一鍵診斷（AI 安裝流程的第一站）

func cmdDoctor() -> Int32 {
    var checks: [[String: Any]] = []
    var firstFix: String?
    func add(_ name: String, _ ok: Bool?, _ detail: String, fix: String? = nil) {
        checks.append(["check": name, "status": ok == nil ? "warn" : (ok! ? "ok" : "fail"),
                       "detail": detail, "fix": fix as Any])
        if ok == false, firstFix == nil { firstFix = fix }
    }

    var transports: [ReceiverTransport] = []
    do {
        transports = try ReceiverTransport.openAll()
        add("input-monitoring", true, "granted")
        let desc = transports.map {
            String(format: "%@ 046D:%04X", $0.isDirect ? "bluetooth" : "receiver", $0.productID)
        }.joined(separator: " · ")
        add("transports", true, desc)
    } catch {
        let msg = "\(error)"
        if msg.contains("Input Monitoring") || msg.contains("E00002E2") {
            add("input-monitoring", false, msg,
                fix: "System Settings > Privacy & Security > Input Monitoring > enable your terminal (or Nibble.app), then rerun")
            add("transports", nil, "skipped — cannot open HID without permission")
        } else {
            add("input-monitoring", nil, "unknown")
            add("transports", false, msg, fix: "Plug in the USB receiver or connect the mouse over Bluetooth")
        }
    }

    if !transports.isEmpty {
        let devs = transports.flatMap { tr in discover(tr, maxIndex: 3).map { ($0.idx, $0.dev, tr, $0.ver) } }
        if let hit = devs.map({ (idx: $0.0, dev: $0.1, tr: $0.2, ver: $0.3) }).first {
            let name = (try? hit.dev.name()) ?? "unknown"
            add("device", true, "\(name) · HID++ \(hit.ver.major).\(hit.ver.minor) · \(hit.tr.isDirect ? "bluetooth" : "index \(hit.idx)")")
            if devs.count > 1 { add("more-devices", nil, "\(devs.count - 1) more awake device(s) found") }
            if let b = try? hit.dev.battery() {
                add("battery", b.percent > 10 || b.charging, "\(b.percent)% \(b.charging ? "charging" : "discharging") (\(b.source))",
                    fix: b.percent <= 10 && !b.charging ? "Charge the mouse" : nil)
            }
            let remapCapable = hit.dev.has(0x8110) || hit.dev.has(0x1b04)
            add("remap-capable", remapCapable,
                hit.dev.has(0x8110) ? "0x8110 MouseButtonSpy (G-series)" :
                hit.dev.has(0x1b04) ? "0x1b04 ReprogControlsV4 (MX-series)" : "neither feature present")
        } else {
            add("device", false, "transport present but no awake device", fix: "Move the mouse to wake it, then rerun")
        }
    }

    let cfg = loadConfig()
    let mapCount = activeButtonMaps(cfg).values.reduce(0, { $0 + $1.count })
    let profiles = profileNames(cfg)
    let profileNote = profiles.count > 1 ? " · profile \(currentProfileName(cfg)) of \(profiles.count)" : ""
    add("config", cfg != nil, cfg == nil ? "not created" : "\(bmConfigURL.path) · \(mapCount) button mapping(s)\(profileNote)",
        fix: cfg == nil ? "nibble config init" : nil)

    // 鎖檔而非 pgrep：doctor 自己也是同一個 binary，比對程序名會把自己算成選單列
    let menubarRunning = menuBarRunning()

    // 改鍵引擎跑在選單列那個程序裡，狀態靠它寫的檔案回報——CLI 自己的 AX 權限不代表引擎的
    if mapCount > 0 {
        let st = EngineState.read()
        // 狀態檔是上一次回報留下的，不會在選單列被關掉時自己更新——
        // 少了這個 && 就會出現「引擎 ✅ 執行中、選單列 ❌ 沒在跑」這種自相矛盾的診斷
        let active = (st["active"] as? Bool ?? false) && menubarRunning
        let reason = menubarRunning
            ? (st["reason"] as? String ?? "menu bar app has not reported yet")
            : "menu bar not running — the engine died with it"
        add("remap-engine", active, active ? "running · \(st["mappings"] as? Int ?? 0) mapping(s) · \(st["path"] as? String ?? "")" : reason,
            // 選單列明明開著卻叫人「去開選單列」是先前這裡的錯字面值：
            // 引擎失敗最常見的原因是滑鼠睡著，而它自己會退避重試
            fix: active ? nil : (st["fix"] as? String
                ?? (menubarRunning ? "wake the mouse — the engine retries on its own"
                                   : "start the menu bar app: open Nibble.app")))
        if let fired = st["lastFiredButton"] as? String {
            add("last-remap-fired", nil,
                "\(fired) → \(st["lastFiredAction"] as? String ?? "?") at \(st["lastFiredAt"] as? String ?? "?")")
        }
        if let last = st["lastEventButton"] as? String {
            add("last-unmapped-press", nil,
                "\(last) (bit \(st["lastEventBit"] as? Int ?? -1), mask \(st["lastEventMask"] as? String ?? "?"))")
        }
    }

    add("menubar", mapCount > 0 ? menubarRunning : nil,
        menubarRunning ? "running (remap engine host)" : "not running",
        fix: (mapCount > 0 && !menubarRunning) ? "nibble menubar &   (or open Nibble.app)" : nil)

    // 開機自動啟動是改鍵能不能撐過重開機的關鍵，但它綁在 .app bundle 上，
    // 所以從終端機跑 doctor 時只能報告「無法從這裡判斷」
    add("login-startup", nil,
        LoginItem.supported ? LoginItem.note : "not visible from the CLI — check Nibble.app > Settings > General",
        fix: (LoginItem.supported && !LoginItem.enabled)
            ? "nibble startup on   (or tick “Start Nibble at login” in Settings > General)" : nil)

    let replayInstalled = FileManager.default.fileExists(atPath: replayPlistURL.path)
    add("login-replay", nil, replayInstalled ? "installed" : "not installed",
        fix: replayInstalled ? nil : "nibble replay install")

    let notifyLimit = lowBatteryThreshold(cfg)
    add("low-battery-alert", nil, notifyLimit.map { "below \($0)%" } ?? "off")

    let failed = checks.filter { $0["status"] as? String == "fail" }.count
    if jsonMode {
        emitJSON(["ok": failed == 0, "failed": failed, "checks": checks,
                  "nextStep": firstFix as Any, "version": NIBBLE_VERSION])
    } else {
        // 欄寬取最長檢查名，新增檢查項不必回頭改字面值
        let width = (checks.compactMap { ($0["check"] as? String)?.count }.max() ?? 16) + 2
        print("Nibble doctor v\(NIBBLE_VERSION)\n")
        for c in checks {
            let s = c["status"] as? String ?? "?"
            let icon = s == "ok" ? "✅" : s == "fail" ? "❌" : "•"
            let name = (c["check"] as? String ?? "").padding(toLength: width, withPad: " ", startingAt: 0)
            print(" \(icon) \(name)\(c["detail"] as? String ?? "")")
            if let fix = c["fix"] as? String { print("      → \(fix)") }
        }
        print("\n \(failed == 0 ? "All good." : "\(failed) issue(s) — fix the first arrow above and rerun.")")
    }
    return failed == 0 ? 0 : 1
}

/// 共用樣板：走遍所有 transport（接收器優先）→ 第一個醒著的裝置 → 執行
/// 一定要走遍：插著閒置 dongle 時第一個 transport 永遠是接收器，藍牙滑鼠會被擋住
func withDevice(_ body: (HIDPPDevice, ReceiverTransport) throws -> Int32) -> Int32 {
    do {
        guard let hit = try discoverEverything().first else {
            print("transport present but no awake device — move the mouse and retry")
            return 1
        }
        return try body(hit.dev, hit.tr)
    } catch {
        print("❌ \(error)")
        return 2
    }
}

// MARK: - M2 寫入組（runtime 寫入 + 寫後回讀驗證 + onboard→host 自動退路）

func cmdDPI(_ args: [String]) -> Int32 {
    withDevice { dev, _ in
        guard let arg = args.first else { print("dpi \(try dev.currentDPI())"); return 0 }
        guard let target = Int(arg), (50...25600).contains(target) else {
            print("usage: nibble dpi [50-25600]"); return 64
        }
        var got = try dev.setDPI(target)
        if got != target, dev.has(0x8100), (try? dev.onboardMode()) == .onboard {
            print("write ignored in onboard mode (read back \(got)) -> retrying in host mode (reverts on power cycle)")
            try dev.setOnboardMode(.host)
            got = try dev.setDPI(target)
        }
        print(got == target ? "dpi \(got) ✓ (verified by read-back)" : "⚠️ asked \(target), device reports \(got)")
        return got == target ? 0 : 1
    }
}

func cmdRate(_ args: [String]) -> Int32 {
    withDevice { dev, _ in
        let supported = (try? dev.supportedReportRatesHz()) ?? []
        guard let arg = args.first else {
            print("rate \(try dev.reportRateHz()) Hz (supported: \(supported.map(String.init).joined(separator: "/")) Hz)")
            return 0
        }
        guard let hz = Int(arg), supported.isEmpty || supported.contains(hz) else {
            print("usage: nibble rate [\(supported.map(String.init).joined(separator: "|"))]"); return 64
        }
        // 0x8060 寫入只在 host 模式被允許（onboard 模式回 err 0x02）——直接報錯也要走退路
        var got: Int
        do {
            got = try dev.setReportRateHz(hz)
        } catch {
            guard dev.has(0x8100), (try? dev.onboardMode()) == .onboard else { throw error }
            print("onboard mode rejected the write (\(error)) -> retrying in host mode (reverts on power cycle)")
            try dev.setOnboardMode(.host)
            got = try dev.setReportRateHz(hz)
        }
        if got != hz, dev.has(0x8100), (try? dev.onboardMode()) == .onboard {
            try dev.setOnboardMode(.host)
            got = try dev.setReportRateHz(hz)
        }
        print(got == hz ? "rate \(got) Hz ✓ (verified by read-back)" : "⚠️ asked \(hz)Hz, device reports \(got)Hz")
        return got == hz ? 0 : 1
    }
}

func cmdRGB(_ args: [String]) -> Int32 {
    withDevice { dev, _ in
        switch args.first ?? "show" {
        case "off":
            if dev.has(0x8100), (try? dev.onboardMode()) == .onboard {
                print("lighting is owned by the onboard profile -> switching to host mode (reverts on power cycle)")
                try dev.setOnboardMode(.host)
            }
            for line in try dev.rgbOff() { print(" \(line)") }
            print("rgb off ✓ check the mouse — lights should be out (RAM only, flash untouched)")
            return 0
        case "show":
            let zones = try dev.rgbZoneCount()
            print("RGB feature 0x\(String(format: "%04X", try dev.rgbFeatureID())) · \(zones) zones")
            for z in 0..<zones {
                let fx = dev.rgbZoneEffects(zone: UInt8(z))
                let names: [UInt16: String] = [0: "off", 1: "fixed", 2: "pulse", 3: "cycle", 10: "breathing"]
                print(" zone \(z): " + fx.map { "slot\($0.slot)=\(names[$0.effectID] ?? String(format: "0x%04X", $0.effectID))" }.joined(separator: "  "))
            }
            return 0
        default:
            print("usage: nibble rgb [off|show]"); return 64
        }
    }
}

func cmdMode(_ args: [String]) -> Int32 {
    withDevice { dev, _ in
        switch args.first {
        case nil:
            print("mode \(try dev.onboardMode())")
        case "host":
            try dev.setOnboardMode(.host); print("mode \(try dev.onboardMode()) ✓")
        case "onboard":
            try dev.setOnboardMode(.onboard); print("mode \(try dev.onboardMode()) ✓")
        default:
            print("usage: nibble mode [host|onboard]"); return 64
        }
        return 0
    }
}

func cmdWheel(_ args: [String]) -> Int32 {
    withDevice { dev, _ in
        switch args.first {
        case "free":    _ = try dev.setWheel(freespin: true)
        case "ratchet": _ = try dev.setWheel(freespin: false)
        case "threshold":
            guard let n = Int(args.dropFirst().first ?? ""), (1...254).contains(n) else {
                print("usage: nibble wheel threshold <1-254>"); return 64
            }
            _ = try dev.setWheel(freespin: false, threshold: n)
        default:
            print("usage: nibble wheel [free|ratchet|threshold N] (MX-series only)"); return 64
        }
        print("wheel ✓ (not yet hardware-verified — MX-series path)")
        return 0
    }
}

// MARK: - M3 安全版：板載記憶體「唯讀」backup

func cmdOnboard(_ args: [String]) -> Int32 {
    withDevice { dev, tr in
        let info = try dev.onboardInfo()
        switch args.first ?? "info" {
        case "info":
            if jsonMode {
                emitJSON(["memoryModel": info.memoryModel, "profileFormat": info.profileFormat,
                          "macroFormat": info.macroFormat, "profileCount": info.profileCount,
                          "profileCountOOB": info.profileCountOOB, "buttonCount": info.buttonCount,
                          "sectorCount": info.sectorCount, "sectorSize": info.sectorSize,
                          "mode": "\(try dev.onboardMode())", "writable": false])
                return 0
            }
            print("""
            onboard-profiles（0x8100）
             memory model    \(info.memoryModel)
             profile format  \(info.profileFormat)
             macro format    \(info.macroFormat)
             profiles        \(info.profileCount)（出廠 \(info.profileCountOOB)）
             buttons         \(info.buttonCount)
             sectors         \(info.sectorCount) × \(info.sectorSize) bytes
             mode            \(try dev.onboardMode())
            """)
            return 0
        case "backup":
            let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/nibble/backups", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var blob = Data()
            var unreadable: [Int] = []
            print("backing up \(info.sectorCount) sectors x \(info.sectorSize)B (read-only, device state untouched)...")
            for sector in 0..<info.sectorCount {
                var sectorData = [UInt8]()
                var failed = false
                var offset = 0
                // sector size 可能不是 16 的倍數（G502 = 255B）：尾端越界會被裝置拒絕（err 0x02），
                // 所以最後一塊用「重疊讀」——從 sectorSize-16 讀起，只取沒讀過的尾巴
                while offset < info.sectorSize {
                    let readOff = min(offset, max(0, info.sectorSize - 16))
                    do {
                        let chunk = try dev.onboardRead(sector: UInt16(sector), offset: UInt16(readOff))
                        let skip = offset - readOff
                        let want = info.sectorSize - offset
                        sectorData.append(contentsOf: chunk.dropFirst(skip).prefix(want))
                        offset += 16 - skip
                    } catch {
                        failed = true
                        break
                    }
                }
                if failed {
                    unreadable.append(sector)
                    sectorData = [UInt8](repeating: 0xFF, count: info.sectorSize)
                }
                blob.append(contentsOf: sectorData.prefix(info.sectorSize))
                print(" sector \(sector) \(failed ? "✗ (unreadable, filled with FF)" : "✓")")
            }
            let bin = dir.appendingPathComponent("onboard-\(ts).bin")
            try blob.write(to: bin)
            let meta: [String: Any] = [
                "device": (try? dev.name()) ?? "?", "receiverPID": String(format: "0x%04X", tr.productID),
                "date": ts, "sectorCount": info.sectorCount, "sectorSize": info.sectorSize,
                "profileFormat": info.profileFormat, "macroFormat": info.macroFormat,
                "unreadableSectors": unreadable,
            ]
            let metaURL = dir.appendingPathComponent("onboard-\(ts).json")
            try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: metaURL)
            print("✅ \(blob.count) bytes → \(bin.path)")
            return 0
        default:
            print("usage: nibble onboard [info|backup] (writes are frozen by design)"); return 64
        }
    }
}

// MARK: - 設定檔 + apply（重放的核心）

func cmdConfig(_ args: [String]) -> Int32 {
    switch args.first ?? "show" {
    case "init":
        return withDevice { dev, _ in
            var cfg = loadConfig() ?? BMConfig()   // 合併：不蓋掉既有的改鍵表
            cfg.dpi = try? dev.currentDPI()
            cfg.reportRateHz = try? dev.reportRateHz()
            if cfg.rgb == nil { cfg.rgb = "keep" }
            try saveConfig(cfg)
            print("✅ updated \(bmConfigURL.path) from current device state (rgb defaults to keep; set \"off\" to save power)")
            return 0
        }
    case "show":
        guard let data = try? Data(contentsOf: bmConfigURL), let s = String(data: data, encoding: .utf8) else {
            print("no config yet — run: nibble config init"); return 1
        }
        print(s)
        return 0
    default:
        print("usage: nibble config [init|show]"); return 64
    }
}

func cmdApply() -> Int32 {
    guard let data = try? Data(contentsOf: bmConfigURL),
          let cfg = try? JSONDecoder().decode(BMConfig.self, from: data) else {
        print("cannot read \(bmConfigURL.path) — run: nibble config init")
        return 1
    }
    return withDevice { dev, _ in
        var failures = 0
        // runtime 設定要 host 模式才穩定生效；模式旗標斷電自動回復，安全
        if dev.has(0x8100), (try? dev.onboardMode()) == .onboard {
            try dev.setOnboardMode(.host)
            print(" mode -> host (runtime settings in charge; reverts on power cycle)")
        }
        if let dpi = cfg.dpi {
            let got = (try? dev.setDPI(dpi)) ?? -1
            print(" dpi \(dpi) \(got == dpi ? "✓" : "✗ (read back \(got))")"); if got != dpi { failures += 1 }
        }
        if let hz = cfg.reportRateHz {
            let got = (try? dev.setReportRateHz(hz)) ?? -1
            print(" rate \(hz)Hz \(got == hz ? "✓" : "✗ (read back \(got))")"); if got != hz { failures += 1 }
        }
        // rgb 可以是 off / cycle / breathing（keep 或未設就不動）
        if let kind = cfg.rgb, kind != "keep" {
            if let applied = try? uiSetRGB(dev, kind: kind), applied > 0 {
                print(" rgb \(kind) ✓ (\(applied) zones)")
            } else { print(" rgb \(kind) ✗"); failures += 1 }
        }
        if let wm = cfg.wheelMode {
            if (try? dev.setWheel(freespin: wm == "free", threshold: cfg.wheelThreshold)) != nil {
                print(" wheel \(wm) ✓")
            } else { print(" wheel \(wm) — (unsupported on this device)") }
        }
        print(failures == 0 ? "apply complete ✓" : "apply complete, \(failures) setting(s) did not take effect")
        return failures == 0 ? 0 : 1
    }
}

// MARK: - 登入自動重放（launchd 一次性 agent，跑完即退，零常駐）

let replayPlistURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/com.ben0128.nibble.replay.plist")

func cmdReplay(_ args: [String]) -> Int32 {
    let label = "com.ben0128.nibble.replay"
    let uid = getuid()
    switch args.first ?? "status" {
    case "install":
        guard let exe = Bundle.main.executablePath else { print("❌ cannot resolve executable path"); return 2 }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>\(exe)</string><string>apply</string></array>
            <key>RunAtLoad</key><true/>
            <key>StandardOutPath</key><string>/tmp/nibble-replay.log</string>
            <key>StandardErrorPath</key><string>/tmp/nibble-replay.log</string>
        </dict>
        </plist>
        """
        _ = sh(["/bin/launchctl", "bootout", "gui/\(uid)/\(label)"])   // 冪等：先卸舊的
        do { try plist.write(to: replayPlistURL, atomically: true, encoding: .utf8) }
        catch { print("❌ cannot write \(replayPlistURL.path): \(error)"); return 2 }
        let rc = sh(["/bin/launchctl", "bootstrap", "gui/\(uid)", replayPlistURL.path])
        print(rc == 0 ? "✅ login replay installed: runs `nibble apply` at each login (one-shot, no daemon)\n   plist: \(replayPlistURL.path)\n   ⚠️ rerun `replay install` if you move the nibble binary"
                      : "⚠️ plist written but launchctl bootstrap returned \(rc)")
        return 0
    case "uninstall":
        _ = sh(["/bin/launchctl", "bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: replayPlistURL)
        print("✅ login replay removed")
        return 0
    default:
        let installed = FileManager.default.fileExists(atPath: replayPlistURL.path)
        print(installed ? "replay: installed (\(replayPlistURL.path))" : "replay: not installed (nibble replay install)")
        return 0
    }
}

// MARK: - UI 共用助手（menubar 與 settings window 共用）

/// 先在第一個 transport 試偏好索引（0.4s 快 ping），失敗才走遍全部（含藍牙直連）
func uiOpenDevice(preferred: UInt8) throws -> (dev: HIDPPDevice, index: UInt8) {
    let transports = try ReceiverTransport.openAll()
    if let first = transports.first, !first.isDirect {
        let d = HIDPPDevice(transport: first, index: preferred)
        if (try? d.ping(timeout: 0.4)) != nil { return (d, preferred) }
    }
    for tr in transports {
        if let hit = discover(tr, maxIndex: 3).first { return (hit.dev, hit.idx) }
    }
    throw HIDPPError.timeout
}

/// runtime 寫入被 onboard 模式擋下時切 host 重試（旗標，斷電自動回復）
func uiHostFallback(_ dev: HIDPPDevice, _ write: () throws -> Void) throws {
    do { try write() } catch {
        guard dev.has(0x8100), (try? dev.onboardMode()) == .onboard else { throw error }
        try dev.setOnboardMode(.host)
        try write()
    }
}

/// 套用燈效（off/cycle/breathing），回傳成功套用的 zone 數
func uiSetRGB(_ dev: HIDPPDevice, kind: String) throws -> Int {
    let targetID: UInt16 = kind == "off" ? 0x0000 : (kind == "cycle" ? 0x0003 : 0x000A)
    if dev.has(0x8100), (try? dev.onboardMode()) == .onboard { try dev.setOnboardMode(.host) }
    var applied = 0
    for z in 0..<(try dev.rgbZoneCount()) {
        if let slot = dev.rgbZoneEffects(zone: UInt8(z)).first(where: { $0.effectID == targetID }) {
            try dev.rgbSetZone(zone: UInt8(z), slot: slot.slot)
            applied += 1
        }
    }
    return applied
}

/// 以目前裝置狀態＋UI 記住的 RGB 狀態寫設定檔（合併，不動改鍵表）
/// `nibble startup [on|off]` — 開機自動啟動選單列。設定視窗有同一個開關，
/// 但 CLI 這條路才能在沒有 GUI 的情況下驗證（而且這個專案每個功能都該有 CLI 對應）。
func cmdStartup(_ args: [String]) -> Int32 {
    let want = args.first?.lowercased()
    if let want, !["on", "off", "true", "false", "enable", "disable"].contains(want) {
        print("usage: nibble startup [on|off]")
        return 64
    }
    guard LoginItem.supported else {
        // 從 repo 或 /usr/local/bin 跑的裸 binary 沒有 bundle 可以註冊
        let msg = "startup needs the app bundle — run `make install-app`, then "
                + "/Applications/Nibble.app/Contents/MacOS/nibble startup on"
        if jsonMode { emitJSON(["error": msg, "code": "not-bundled"]) } else { print(msg) }
        return 1
    }
    if let want {
        let on = ["on", "true", "enable"].contains(want)
        do {
            try LoginItem.set(on)
        } catch {
            if jsonMode { emitJSON(["error": "\(error)", "code": "login-item-failed"]) } else { print("❌ \(error)") }
            return 2
        }
    }
    if jsonMode {
        emitJSON(["startup": LoginItem.enabled, "status": LoginItem.note, "bundle": Bundle.main.bundleURL.path])
    } else {
        print("startup: \(LoginItem.note)")
    }
    return 0
}

func uiSaveConfig(_ dev: HIDPPDevice, rgb: String?) throws {
    var cfg = loadConfig() ?? BMConfig()
    cfg.dpi = try? dev.currentDPI()
    cfg.reportRateHz = try? dev.reportRateHz()
    cfg.rgb = rgb ?? cfg.rgb ?? "keep"   // 具名燈效也要存得下，不是只有 off
    try saveConfig(cfg)
}


@discardableResult
func sh(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func cmdDump() -> Int32 {
    let t0 = Date()
    do {
        guard let hit = try discoverEverything().first else {
            print("transport present but no awake device — move the mouse and retry")
            return 1
        }
        let name = (try? hit.dev.name()) ?? "Unknown"
        let link = hit.tr.isDirect ? "bluetooth" : "device #\(hit.idx)"
        print("\(name) · HID++ \(hit.ver.major).\(hit.ver.minor) · \(link)\n")
        print(" idx  feature  flags  name")
        print(" ───  ───────  ─────  ─────────────────────")
        let list = try hit.dev.featureList()
        var hidden = 0
        for f in list {
            var fl = ""
            if f.flags & 0x80 != 0 { fl += "O" }   // obsolete
            if f.flags & 0x40 != 0 { fl += "H"; hidden += 1 }   // hidden
            if f.flags & 0x20 != 0 { fl += "E" }   // engineering
            let known = HIDPP.featureNames[f.id] ?? "?"
            print(String(format: " %3d  0x%04X   %-5@  %@", Int(f.index), Int(f.id), fl as NSString, known as NSString))
        }
        print("\n \(list.count) features · \(hidden) hidden ·" + footer(since: t0))
        return 0
    } catch {
        print("❌ \(error)")
        return 2
    }
}

// MARK: - M5a：按鍵列舉（唯讀）

func cmdButtons() -> Int32 {
    withDevice { dev, _ in
        let name = (try? dev.name()) ?? "?"
        if jsonMode {
            let saved = activeButtonMaps(loadConfig())[name] ?? [:]
            var list: [[String: Any]] = []
            if dev.has(0x8110) {
                let n = try dev.buttonSpyCount()
                for i in 0..<n {
                    let key = "G\(i + 1)"
                    list.append(["id": key, "index": i, "remappable": i >= 2,
                                 "action": saved[key].map { ["type": $0.type, "keys": $0.keys as Any, "action": $0.action as Any] } as Any])
                }
            } else if dev.has(0x1b04) {
                for c in try dev.controls() {
                    let key = HIDPP.cidNames[c.cid] ?? String(format: "CID 0x%04X", c.cid)
                    list.append(["id": key, "cid": String(format: "0x%04X", c.cid), "remappable": c.divertable,
                                 "action": saved[key].map { ["type": $0.type, "keys": $0.keys as Any, "action": $0.action as Any] } as Any])
                }
            }
            emitJSON(["device": name, "path": dev.has(0x8110) ? "0x8110" : "0x1b04", "buttons": list])
            return 0
        }
        // 路線二：G 系（0x8110 MouseButtonSpy）——G 滑鼠沒有 0x1b04
        if !dev.has(0x1b04), dev.has(0x8110) {
            let n = try dev.buttonSpyCount()
            let map = (try? dev.buttonSpyRemapping(count: n)) ?? []
            print("\(name) · \(n) buttons (0x8110 MouseButtonSpy — G-series path)\n")
            print(" btn   spy-remap")
            print(" ----  ---------------")
            for i in 0..<n {
                let target = i < map.count ? Int(map[i]) : 0
                let mapped = target == 0 ? "(default)" : (target == i + 1 ? "→ itself (unchanged)" : "→ button \(target)")
                print(String(format: " G%-3d  %@", i + 1, mapped as NSString))
            }
            print("\n (G-series button layer = 0x8110 spy/remap; this command is read-only)")
            return 0
        }
        // 路線一：MX 系（0x1b04 ReprogControlsV4）
        let list = try dev.controls()
        print("\(name) · \(list.count) controls (0x1b04, enumerated from the device)\n")
        print(" cid     name              pos  divert       reprog  type")
        print(" ------  ----------------  ---  -----------  ------  --------")
        for c in list {
            let name = HIDPP.cidNames[c.cid] ?? "?"
            let divert = c.divertable ? (c.persistentlyDivertable ? "yes+persist" : "yes") : "no"
            var type: [String] = []
            if c.isMouseButton { type.append("mouse") }
            if c.isFKey { type.append("fkey") }
            if c.isHotkey { type.append("hotkey") }
            if c.virtualControl { type.append("virtual") }
            if c.rawXY { type.append("rawXY") }
            print(String(format: " 0x%04X  %-16@  %3d  %-11@  %-6@  %@",
                         Int(c.cid), name as NSString, Int(c.pos),
                         divert as NSString, (c.reprogrammable ? "yes" : "no") as NSString,
                         type.joined(separator: ",") as NSString))
        }
        print("\n (divert = can be handed to software; pos = physical position on gaming mice; this command is read-only)")
        return 0
    }
}

// MARK: - M5b：spy 診斷 + 互動改鍵

func cmdSpy(_ args: [String]) -> Int32 {
    withDevice { dev, tr in
        guard dev.has(0x8110) else { print("this device has no 0x8110 (MX-series uses the 0x1b04 path)"); return 1 }
        guard let spyIdx = try dev.featureIndex(of: 0x8110) else { return 1 }
        let n = try dev.buttonSpyCount()
        let seconds = args.first.flatMap(Double.init)   // `nibble spy 15` = 15 秒後自動結束
        print("spy started (\(n) buttons) — press mouse buttons to see events; \(seconds.map { "stops after \(Int($0))s" } ?? "Ctrl+C to stop")\n")
        try dev.buttonSpyStart()
        var prev: UInt16 = 0
        tr.onReport = { p in
            guard p.count >= 5, p[1] == spyIdx, p[2] == 0x00 else { return }
            let mask = UInt16(p[3]) << 8 | UInt16(p[4])
            let newly = mask & ~prev
            let released = prev & ~mask
            prev = mask
            let hex = p.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            var line = "event [\(hex)…] mask=\(String(format: "%04X", mask))"
            if newly != 0 { line += "  ↓ G\((0..<16).filter { newly & (1 << $0) != 0 }.map { String($0 + 1) }.joined(separator: ",G"))" }
            if released != 0 { line += "  ↑ G\((0..<16).filter { released & (1 << $0) != 0 }.map { String($0 + 1) }.joined(separator: ",G"))" }
            print(line)
        }
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        var done = false
        sig.setEventHandler { done = true }
        sig.resume()
        let deadline = seconds.map { Date().addingTimeInterval($0) }
        while !done {
            if let dl = deadline, Date() >= dl { break }
            CFRunLoopRunInMode(.defaultMode, 0.2, true)
        }
        tr.onReport = nil
        try? dev.buttonSpyStop()
        print("\nspy stopped, device restored")
        return 0
    }
}

func cmdRemap() -> Int32 {
    withDevice { dev, tr in
        let devName = (try? dev.name()) ?? "unknown"
        var bName: String
        print("Press the mouse button you want to remap… (30s timeout)")

        if dev.has(0x8110) {
            // G 系：spy bitmask
            guard let spyIdx = try dev.featureIndex(of: 0x8110) else { return 1 }
            try dev.buttonSpyStart()
            var captured: Int?
            var prev: UInt16 = 0
            tr.onReport = { p in
                guard p.count >= 5, p[1] == spyIdx, p[2] == 0x00 else { return }
                let mask = UInt16(p[3]) << 8 | UInt16(p[4])
                let newly = mask & ~prev
                prev = mask
                if captured == nil, newly != 0 { captured = (0..<16).first { newly & (1 << $0) != 0 } }
            }
            let deadline = Date().addingTimeInterval(30)
            while captured == nil && Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.2, true) }
            tr.onReport = nil
            try? dev.buttonSpyStop()
            guard let btn = captured else { print("no button pressed, cancelled"); return 1 }
            if btn <= 1 { print("→ got G\(btn + 1) (left/right click) — refusing to remap primary buttons"); return 1 }
            bName = "G\(btn + 1)"
        } else if dev.has(0x1b04) {
            // MX 系：暫時 divert 全部可 divert 的鍵來聽事件，結束一律還原
            guard let fi = try dev.featureIndex(of: 0x1b04) else { return 1 }
            let controls = try dev.controls()
            let divertable = controls.filter(\.divertable)
            guard !divertable.isEmpty else { print("this device has no divertable buttons"); return 1 }
            for c in divertable { try? dev.setDivert(cid: c.cid, on: true) }
            var captured: UInt16?
            tr.onReport = { p in
                guard captured == nil, p.count >= 5, p[1] == fi, p[2] == 0x00 else { return }
                var i = 3
                while i + 1 < p.count && i < 11 {
                    let cid = UInt16(p[i]) << 8 | UInt16(p[i + 1])
                    if cid != 0 { captured = cid; return }
                    i += 2
                }
            }
            let deadline = Date().addingTimeInterval(30)
            while captured == nil && Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.2, true) }
            tr.onReport = nil
            for c in divertable { try? dev.setDivert(cid: c.cid, on: false) }
            guard let cid = captured else { print("no button pressed, cancelled"); return 1 }
            bName = HIDPP.cidNames[cid] ?? String(format: "CID 0x%04X", cid)
        } else {
            print("this device does not support remapping (no 0x8110 / 0x1b04)")
            return 1
        }
        print("→ got \(bName)")
        print("Action type? [k]eystroke [m]acro [s]ystem action [d]efault [x]disable: ", terminator: "")
        guard let choice = readLine()?.lowercased().first else { return 1 }
        var action: ButtonAction?
        switch choice {
        case "k":
            print("Key combination (e.g. cmd+shift+4 / ctrl+left / f13): ", terminator: "")
            guard let combo = readLine(), parseCombo(combo) != nil else { print("could not parse that combination"); return 64 }
            action = ButtonAction(type: "keys", keys: combo, action: nil)
        case "m":
            print("Steps, comma separated (e.g. cmd+c, 150ms, cmd+v): ", terminator: "")
            guard let seq = readLine(), parseMacro(seq) != nil else {
                print("could not read that macro — steps are key combos or delays (150ms), max 64 steps / 30s")
                return 64
            }
            action = ButtonAction(type: "macro", keys: seq, action: nil)
        case "s":
            print("Options: \(SystemAction.allCases.map(\.rawValue).joined(separator: " / ")) / app:Name / url:deeplink")
            print("Enter: ", terminator: "")
            guard let s = readLine(), !s.isEmpty else { return 1 }
            action = ButtonAction(type: "system", keys: nil, action: s)
        case "d":
            action = nil
        case "x":
            action = ButtonAction(type: "disable", keys: nil, action: nil)
        default:
            return 64
        }
        try updateActiveButtonMap(device: devName) { devMap in
            if let action { devMap[bName] = action } else { devMap.removeValue(forKey: bName) }
        }
        let desc = action.map {
            switch $0.type {
            case "keys": return "keys: \($0.keys ?? "")"
            case "macro": return "macro: \($0.keys ?? "")"
            case "disable": return "disabled"
            default: return "system: \($0.action ?? "")"
            }
        } ?? "restore default"
        print("✓ \(bName) → \(desc) (saved)")
        print("  Takes effect in the menu bar app, which reloads this file automatically")
        if action != nil, action?.type != "disable", !axTrusted() {
            print("  ⚠️ Accessibility not granted yet — the menu bar app will prompt when the engine starts")
        }
        return 0
    }
}

// MARK: - 改鍵組合（profile）

func cmdProfile(_ args: [String]) -> Int32 {
    let cfg = loadConfig()
    let names = profileNames(cfg)
    let current = currentProfileName(cfg)

    func counts(_ name: String) -> Int {
        (cfg?.buttonProfiles?[name] ?? (name == defaultProfileName ? cfg?.buttonMaps : nil) ?? [:])
            .values.reduce(0, { $0 + $1.count })
    }

    switch args.first ?? "list" {
    case "list":
        if jsonMode {
            emitJSON(["active": current,
                      "profiles": names.map { ["name": $0, "mappings": counts($0)] }])
        } else {
            for n in names {
                print("\(n == current ? " * " : "   ")\(n)  ·  \(counts(n)) mapping(s)")
            }
        }
        return 0

    case "use":
        guard let name = args.dropFirst().first else { print("usage: nibble profile use <name>"); return 64 }
        do {
            try switchProfile(to: name)
            print("switched to \(name) · \(counts(name)) mapping(s)")
            print("  the menu bar app reloads the engine automatically")
            return 0
        } catch { emitError("\(error)", code: "profile"); return 1 }

    case "new", "copy":
        guard let name = args.dropFirst().first else {
            print("usage: nibble profile \(args[0]) <name>"); return 64
        }
        do {
            try createProfile(name, copyFrom: args[0] == "copy" ? current : nil)
            print("created \(name)\(args[0] == "copy" ? " as a copy of \(current)" : "") and switched to it")
            return 0
        } catch { emitError("\(error)", code: "profile"); return 1 }

    case "rename":
        let rest = Array(args.dropFirst())
        guard rest.count == 2 else { print("usage: nibble profile rename <old> <new>"); return 64 }
        do { try renameProfile(rest[0], to: rest[1]); print("renamed \(rest[0]) → \(rest[1])"); return 0 }
        catch { emitError("\(error)", code: "profile"); return 1 }

    case "delete":
        guard let name = args.dropFirst().first else { print("usage: nibble profile delete <name>"); return 64 }
        do {
            try deleteProfile(name)
            print("deleted \(name)\(name == current ? " · switched to \(defaultProfileName)" : "")")
            return 0
        } catch { emitError("\(error)", code: "profile"); return 1 }

    default:
        print("usage: nibble profile [list|use <name>|new <name>|copy <name>|rename <old> <new>|delete <name>]")
        return 64
    }
}
