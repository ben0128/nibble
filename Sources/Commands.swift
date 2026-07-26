// Commands.swift — 指令層：status / battery / dump
import Foundation

/// 掃描接收器下掛的裝置索引 1–6（空索引接收器會秒回錯誤，睡眠裝置吃 timeout）
func discover(_ tr: HIDPPTransport, maxIndex: UInt8 = 6)
    -> [(idx: UInt8, dev: HIDPPDevice, ver: (major: Int, minor: Int))] {
    var out: [(idx: UInt8, dev: HIDPPDevice, ver: (major: Int, minor: Int))] = []
    for i in 1...maxIndex {
        let d = HIDPPDevice(transport: tr, index: i)
        if let v = try? d.ping(timeout: 0.6) { out.append((i, d, v)) }
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
        let tr = try ReceiverTransport.openFirst()
        let devs = discover(tr)
        guard let hit = devs.first else {
            emitError("receiver present (PID 0x\(String(format: "%04X", tr.productID))) but no awake device — move the mouse and retry",
                      code: "no-awake-device")
            return 1
        }
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
        print(" link      HID++ \(hit.ver.major).\(hit.ver.minor) · receiver 046D:\(String(format: "%04X", tr.productID)) · device #\(hit.idx)")
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
        let tr = try ReceiverTransport.openFirst()
        guard let hit = discover(tr).first else {
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

    var transport: ReceiverTransport?
    do {
        let tr = try ReceiverTransport.openFirst()
        transport = tr
        add("input-monitoring", true, "granted")
        add("receiver", true, String(format: "046D:%04X", tr.productID))
    } catch {
        let msg = "\(error)"
        if msg.contains("Input Monitoring") || msg.contains("E00002E2") {
            add("input-monitoring", false, msg,
                fix: "System Settings > Privacy & Security > Input Monitoring > enable your terminal (or Nibble.app), then rerun")
            add("receiver", nil, "skipped — cannot open HID without permission")
        } else {
            add("input-monitoring", nil, "unknown")
            add("receiver", false, msg, fix: "Plug the Logitech USB receiver in (vendor 046D, HID usage page 0xFF00)")
        }
    }

    if let tr = transport {
        let devs = discover(tr, maxIndex: 3)
        if let hit = devs.first {
            let name = (try? hit.dev.name()) ?? "unknown"
            add("device", true, "\(name) · HID++ \(hit.ver.major).\(hit.ver.minor) · index \(hit.idx)")
            if let b = try? hit.dev.battery() {
                add("battery", b.percent > 10 || b.charging, "\(b.percent)% \(b.charging ? "charging" : "discharging") (\(b.source))",
                    fix: b.percent <= 10 && !b.charging ? "Charge the mouse" : nil)
            }
            let remapCapable = hit.dev.has(0x8110) || hit.dev.has(0x1b04)
            add("remap-capable", remapCapable,
                hit.dev.has(0x8110) ? "0x8110 MouseButtonSpy (G-series)" :
                hit.dev.has(0x1b04) ? "0x1b04 ReprogControlsV4 (MX-series)" : "neither feature present")
        } else {
            add("device", false, "receiver present but no awake device", fix: "Move the mouse to wake it, then rerun")
        }
    }

    let cfg = loadConfig()
    let mapCount = cfg?.buttonMaps?.values.reduce(0) { $0 + $1.count } ?? 0
    add("config", cfg != nil, cfg == nil ? "not created" : "\(bmConfigURL.path) · \(mapCount) button mapping(s)",
        fix: cfg == nil ? "nibble config init" : nil)

    // 改鍵引擎跑在選單列那個程序裡，狀態靠它寫的檔案回報——CLI 自己的 AX 權限不代表引擎的
    if mapCount > 0 {
        let st = EngineState.read()
        let active = st["active"] as? Bool ?? false
        let reason = st["reason"] as? String ?? "menu bar app has not reported yet"
        add("remap-engine", active, active ? "running · \(st["mappings"] as? Int ?? 0) mapping(s) · \(st["path"] as? String ?? "")" : reason,
            fix: active ? nil : (st["fix"] as? String ?? "start the menu bar app: open Nibble.app"))
        if let last = st["lastEventButton"] as? String {
            let mapped = st["lastEventMapped"] as? Bool ?? false
            add("last-button-event", nil,
                "\(last) (bit \(st["lastEventBit"] as? Int ?? -1), mask \(st["lastEventMask"] as? String ?? "?")) → \(mapped ? "fired \(st["lastEventAction"] as? String ?? "")" : "no mapping on this button")")
        }
    }

    let menubarRunning = sh(["/usr/bin/pgrep", "-f", "nibble menubar"]) == 0
        || sh(["/usr/bin/pgrep", "-f", "Nibble.app"]) == 0
    add("menubar", mapCount > 0 ? menubarRunning : nil,
        menubarRunning ? "running (remap engine host)" : "not running",
        fix: (mapCount > 0 && !menubarRunning) ? "nibble menubar &   (or open Nibble.app)" : nil)

    let replayInstalled = FileManager.default.fileExists(atPath: replayPlistURL.path)
    add("login-replay", nil, replayInstalled ? "installed" : "not installed",
        fix: replayInstalled ? nil : "nibble replay install")

    let failed = checks.filter { $0["status"] as? String == "fail" }.count
    if jsonMode {
        emitJSON(["ok": failed == 0, "failed": failed, "checks": checks,
                  "nextStep": firstFix as Any, "version": NIBBLE_VERSION])
    } else {
        print("Nibble doctor v\(NIBBLE_VERSION)\n")
        for c in checks {
            let s = c["status"] as? String ?? "?"
            let icon = s == "ok" ? "✅" : s == "fail" ? "❌" : "•"
            let name = (c["check"] as? String ?? "").padding(toLength: 18, withPad: " ", startingAt: 0)
            print(" \(icon) \(name)\(c["detail"] as? String ?? "")")
            if let fix = c["fix"] as? String { print("      → \(fix)") }
        }
        print("\n \(failed == 0 ? "All good." : "\(failed) issue(s) — fix the first arrow above and rerun.")")
    }
    return failed == 0 ? 0 : 1
}

/// 共用樣板：開接收器 → 找第一個醒著的裝置 → 執行
func withDevice(_ body: (HIDPPDevice, ReceiverTransport) throws -> Int32) -> Int32 {
    do {
        let tr = try ReceiverTransport.openFirst()
        guard let hit = discover(tr).first else {
            print("Receiver present but no awake device — move the mouse and retry")
            return 1
        }
        return try body(hit.dev, tr)
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

struct BMConfig: Codable {
    var dpi: Int? = nil
    var reportRateHz: Int? = nil
    var rgb: String? = nil            // "off" | "keep"
    var wheelMode: String? = nil      // "free" | "ratchet"（MX 系）
    var wheelThreshold: Int? = nil
    // per-device 改鍵表：裝置名稱 → { "G7": {type,keys,action} }（ButtonAction 定義在 Actions.swift）
    var buttonMaps: [String: [String: ButtonAction]]? = nil
}

func loadConfig() -> BMConfig? {
    (try? Data(contentsOf: bmConfigURL)).flatMap { try? JSONDecoder().decode(BMConfig.self, from: $0) }
}

func saveConfig(_ c: BMConfig) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try (try enc.encode(c)).write(to: bmConfigURL)
}

let bmConfigURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/nibble.json")

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
        if cfg.rgb == "off" {
            if let log = try? dev.rgbOff() { print(" rgb off ✓ (\(log.count) zones)") }
            else { print(" rgb off ✗"); failures += 1 }
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

/// 先試偏好索引（0.4s 快 ping），失敗才掃 1–3
func uiOpenDevice(preferred: UInt8) throws -> (dev: HIDPPDevice, index: UInt8) {
    let tr = try ReceiverTransport.openFirst()
    let d = HIDPPDevice(transport: tr, index: preferred)
    if (try? d.ping(timeout: 0.4)) != nil { return (d, preferred) }
    guard let hit = discover(tr, maxIndex: 3).first else { throw HIDPPError.timeout }
    return (hit.dev, hit.idx)
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
func uiSaveConfig(_ dev: HIDPPDevice, rgb: String?) throws {
    var cfg = loadConfig() ?? BMConfig()
    cfg.dpi = try? dev.currentDPI()
    cfg.reportRateHz = try? dev.reportRateHz()
    cfg.rgb = rgb == "off" ? "off" : (cfg.rgb ?? "keep")
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
        let tr = try ReceiverTransport.openFirst()
        let devs = discover(tr)
        guard let hit = devs.first else { print("Receiver present but no awake device"); return 1 }
        let name = (try? hit.dev.name()) ?? "Unknown"
        print("\(name) · HID++ \(hit.ver.major).\(hit.ver.minor) · device #\(hit.idx)\n")
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
            let saved = loadConfig()?.buttonMaps?[name] ?? [:]
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
        print("Action type? [k]eystroke [s]ystem action [d]efault [x]disable: ", terminator: "")
        guard let choice = readLine()?.lowercased().first else { return 1 }
        var action: ButtonAction?
        switch choice {
        case "k":
            print("Key combination (e.g. cmd+shift+4 / ctrl+left / f13): ", terminator: "")
            guard let combo = readLine(), parseCombo(combo) != nil else { print("could not parse that combination"); return 64 }
            action = ButtonAction(type: "keys", keys: combo, action: nil)
        case "s":
            print("Options: \(SystemAction.allCases.map(\.rawValue).joined(separator: " / ")) / app:Name")
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
        var cfg = loadConfig() ?? BMConfig()
        var maps = cfg.buttonMaps ?? [:]
        var devMap = maps[devName] ?? [:]
        if let action { devMap[bName] = action } else { devMap.removeValue(forKey: bName) }
        maps[devName] = devMap.isEmpty ? nil : devMap
        cfg.buttonMaps = maps
        try saveConfig(cfg)
        let desc = action.map { $0.type == "keys" ? "keys: \($0.keys ?? "")" : $0.type == "disable" ? "disabled" : "system: \($0.action ?? "")" } ?? "restore default"
        print("✓ \(bName) → \(desc) (saved)")
        print("  Takes effect in the menu bar app, which reloads this file automatically")
        if action != nil, action?.type != "disable", !axTrusted() {
            print("  ⚠️ Accessibility not granted yet — the menu bar app will prompt when the engine starts")
        }
        return 0
    }
}
