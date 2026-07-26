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
            print("接收器在（PID 0x\(String(format: "%04X", tr.productID))），但沒有醒著的裝置——滑鼠睡著了？晃兩下再試")
            return 1
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
            print(" others    另有 \(devs.count - 1) 個裝置在線（index \(devs.dropFirst().map { String($0.idx) }.joined(separator: ",")))，用 status 之外的指令指定")
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
    let t0 = Date()
    do {
        let tr = try ReceiverTransport.openFirst()
        guard let hit = discover(tr).first else { print("no-device"); return 1 }
        let b = try hit.dev.battery()
        let volt = b.millivolts.map { String(format: " %.2fV", Double($0) / 1000) } ?? ""
        print("\(b.percent)%\(volt) \(b.charging ? "charging" : "discharging")")
        _ = t0
        return 0
    } catch {
        print("❌ \(error)")
        return 2
    }
}

/// 共用樣板：開接收器 → 找第一個醒著的裝置 → 執行
func withDevice(_ body: (HIDPPDevice, ReceiverTransport) throws -> Int32) -> Int32 {
    do {
        let tr = try ReceiverTransport.openFirst()
        guard let hit = discover(tr).first else {
            print("接收器在，但沒有醒著的裝置——晃兩下滑鼠再試")
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
            print("用法：nibble dpi [50–25600]"); return 64
        }
        var got = try dev.setDPI(target)
        if got != target, dev.has(0x8100), (try? dev.onboardMode()) == .onboard {
            print("onboard 模式下寫入未生效（回讀 \(got)）→ 切 host 模式重試（斷電會自動回復）")
            try dev.setOnboardMode(.host)
            got = try dev.setDPI(target)
        }
        print(got == target ? "dpi \(got) ✓（寫後回讀驗證）" : "⚠️ 要求 \(target)，裝置回讀 \(got)")
        return got == target ? 0 : 1
    }
}

func cmdRate(_ args: [String]) -> Int32 {
    withDevice { dev, _ in
        let supported = (try? dev.supportedReportRatesHz()) ?? []
        guard let arg = args.first else {
            print("rate \(try dev.reportRateHz()) Hz（支援：\(supported.map(String.init).joined(separator: "/")) Hz）")
            return 0
        }
        guard let hz = Int(arg), supported.isEmpty || supported.contains(hz) else {
            print("用法：nibble rate [\(supported.map(String.init).joined(separator: "|"))]"); return 64
        }
        // 0x8060 寫入只在 host 模式被允許（onboard 模式回 err 0x02）——直接報錯也要走退路
        var got: Int
        do {
            got = try dev.setReportRateHz(hz)
        } catch {
            guard dev.has(0x8100), (try? dev.onboardMode()) == .onboard else { throw error }
            print("onboard 模式拒絕寫入（\(error)）→ 切 host 模式重試（斷電會自動回復）")
            try dev.setOnboardMode(.host)
            got = try dev.setReportRateHz(hz)
        }
        if got != hz, dev.has(0x8100), (try? dev.onboardMode()) == .onboard {
            try dev.setOnboardMode(.host)
            got = try dev.setReportRateHz(hz)
        }
        print(got == hz ? "rate \(got) Hz ✓（寫後回讀驗證）" : "⚠️ 要求 \(hz)Hz，裝置回讀 \(got)Hz")
        return got == hz ? 0 : 1
    }
}

func cmdRGB(_ args: [String]) -> Int32 {
    withDevice { dev, _ in
        switch args.first ?? "show" {
        case "off":
            if dev.has(0x8100), (try? dev.onboardMode()) == .onboard {
                print("RGB 在 onboard 模式由板載 profile 主導 → 切 host 模式（斷電會自動回復）")
                try dev.setOnboardMode(.host)
            }
            for line in try dev.rgbOff() { print(" \(line)") }
            print("rgb off ✓ 看一眼滑鼠——燈應該滅了（省電模式，只寫 RAM 不碰 flash）")
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
            print("用法：nibble rgb [off|show]"); return 64
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
            print("用法：nibble mode [host|onboard]"); return 64
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
                print("用法：nibble wheel threshold <1-254>"); return 64
            }
            _ = try dev.setWheel(freespin: false, threshold: n)
        default:
            print("用法：nibble wheel [free|ratchet|threshold N]（MX 系限定，G502 無此功能）"); return 64
        }
        print("wheel ✓（注意：此功能尚未在實機驗證——MX Master 3 上線後補測）")
        return 0
    }
}

// MARK: - M3 安全版：板載記憶體「唯讀」backup

func cmdOnboard(_ args: [String]) -> Int32 {
    withDevice { dev, tr in
        let info = try dev.onboardInfo()
        switch args.first ?? "info" {
        case "info":
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
            print("備份 \(info.sectorCount) sectors × \(info.sectorSize)B（唯讀，不動滑鼠任何狀態）…")
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
                print(" sector \(sector) \(failed ? "✗（不可讀，以 FF 填充）" : "✓")")
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
            print("用法：nibble onboard [info|backup]（寫入功能凍結中——安全路線）"); return 64
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
            print("✅ 以目前裝置狀態更新 \(bmConfigURL.path)（rgb 預設 keep，要省電改成 \"off\"）")
            return 0
        }
    case "show":
        guard let data = try? Data(contentsOf: bmConfigURL), let s = String(data: data, encoding: .utf8) else {
            print("還沒有設定檔——先跑 nibble config init"); return 1
        }
        print(s)
        return 0
    default:
        print("用法：nibble config [init|show]"); return 64
    }
}

func cmdApply() -> Int32 {
    guard let data = try? Data(contentsOf: bmConfigURL),
          let cfg = try? JSONDecoder().decode(BMConfig.self, from: data) else {
        print("讀不到 \(bmConfigURL.path)——先跑 nibble config init")
        return 1
    }
    return withDevice { dev, _ in
        var failures = 0
        // runtime 設定要 host 模式才穩定生效；模式旗標斷電自動回復，安全
        if dev.has(0x8100), (try? dev.onboardMode()) == .onboard {
            try dev.setOnboardMode(.host)
            print(" mode → host（runtime 設定主導；斷電自動回復 onboard）")
        }
        if let dpi = cfg.dpi {
            let got = (try? dev.setDPI(dpi)) ?? -1
            print(" dpi \(dpi) \(got == dpi ? "✓" : "✗（回讀 \(got)）")"); if got != dpi { failures += 1 }
        }
        if let hz = cfg.reportRateHz {
            let got = (try? dev.setReportRateHz(hz)) ?? -1
            print(" rate \(hz)Hz \(got == hz ? "✓" : "✗（回讀 \(got)）")"); if got != hz { failures += 1 }
        }
        if cfg.rgb == "off" {
            if let log = try? dev.rgbOff() { print(" rgb off ✓（\(log.count) zones）") }
            else { print(" rgb off ✗"); failures += 1 }
        }
        if let wm = cfg.wheelMode {
            if (try? dev.setWheel(freespin: wm == "free", threshold: cfg.wheelThreshold)) != nil {
                print(" wheel \(wm) ✓")
            } else { print(" wheel \(wm) —（裝置無此功能）") }
        }
        print(failures == 0 ? "apply 完成 ✓" : "apply 完成，\(failures) 項未生效")
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
        guard let exe = Bundle.main.executablePath else { print("❌ 找不到執行檔路徑"); return 2 }
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
        catch { print("❌ 寫不進 \(replayPlistURL.path)：\(error)"); return 2 }
        let rc = sh(["/bin/launchctl", "bootstrap", "gui/\(uid)", replayPlistURL.path])
        print(rc == 0 ? "✅ 已安裝登入重放：每次登入自動 nibble apply（跑完即退，零常駐）\n   plist：\(replayPlistURL.path)\n   ⚠️ 若移動 nibble 執行檔，要重跑 replay install"
                      : "⚠️ plist 已寫入但 launchctl bootstrap 回傳 \(rc)")
        return 0
    case "uninstall":
        _ = sh(["/bin/launchctl", "bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: replayPlistURL)
        print("✅ 已移除登入重放")
        return 0
    default:
        let installed = FileManager.default.fileExists(atPath: replayPlistURL.path)
        print(installed ? "replay：已安裝（\(replayPlistURL.path)）" : "replay：未安裝（nibble replay install）")
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
        guard let hit = devs.first else { print("接收器在，但沒有醒著的裝置"); return 1 }
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
        // 路線二：G 系（0x8110 MouseButtonSpy）——G 滑鼠沒有 0x1b04
        if !dev.has(0x1b04), dev.has(0x8110) {
            let n = try dev.buttonSpyCount()
            let map = (try? dev.buttonSpyRemapping(count: n)) ?? []
            print("\(name) · \(n) buttons（0x8110 MouseButtonSpy——G 系路徑）\n")
            print(" btn   spy-remap")
            print(" ----  ---------------")
            for i in 0..<n {
                let target = i < map.count ? Int(map[i]) : 0
                let mapped = target == 0 ? "(default)" : (target == i + 1 ? "→ 自己（未改）" : "→ button \(target)")
                print(String(format: " G%-3d  %@", i + 1, mapped as NSString))
            }
            print("\n （G 系按鍵層 = 0x8110 spy/remap；M5b divert 引擎將用 startSpy 事件流；本指令唯讀）")
            return 0
        }
        // 路線一：MX 系（0x1b04 ReprogControlsV4）
        let list = try dev.controls()
        print("\(name) · \(list.count) controls（0x1b04 裝置自我列舉，非寫死）\n")
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
        print("\n （divert = 可交給軟體接管；pos = 遊戲鼠實體位置編號；M5b 引擎未上線，本指令唯讀）")
        return 0
    }
}

// MARK: - M5b：spy 診斷 + 互動改鍵

func cmdSpy(_ args: [String]) -> Int32 {
    withDevice { dev, tr in
        guard dev.has(0x8110) else { print("此裝置沒有 0x8110（MX 系請等 0x1b04 引擎）"); return 1 }
        guard let spyIdx = try dev.featureIndex(of: 0x8110) else { return 1 }
        let n = try dev.buttonSpyCount()
        let seconds = args.first.flatMap(Double.init)   // `nibble spy 15` = 15 秒後自動結束
        print("spy 開始（\(n) 顆鍵）——按滑鼠按鍵看事件；\(seconds.map { "\(Int($0)) 秒後" } ?? "Ctrl+C ")結束並還原\n")
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
        print("\nspy 結束，已還原")
        return 0
    }
}

func cmdRemap() -> Int32 {
    withDevice { dev, tr in
        guard dev.has(0x8110) else { print("MX 系（0x1b04 divert）引擎尚未實作——目前支援 G 系"); return 1 }
        guard let spyIdx = try dev.featureIndex(of: 0x8110) else { return 1 }
        let devName = (try? dev.name()) ?? "unknown"
        print("按下你要改的滑鼠按鍵…（30 秒逾時；⚠️ 左右鍵 G1/G2 不建議改）")
        try dev.buttonSpyStart()
        var captured: Int?
        var prev: UInt16 = 0
        tr.onReport = { p in
            guard p.count >= 5, p[1] == spyIdx, p[2] == 0x00 else { return }
            let mask = UInt16(p[3]) << 8 | UInt16(p[4])
            let newly = mask & ~prev
            prev = mask
            if captured == nil, newly != 0 {
                captured = (0..<16).first { newly & (1 << $0) != 0 }
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while captured == nil && Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.2, true) }
        tr.onReport = nil
        try? dev.buttonSpyStop()
        guard let btn = captured else { print("沒等到按鍵，取消"); return 1 }
        let bName = "G\(btn + 1)"
        if btn <= 1 { print("→ 抓到 \(bName)（左/右鍵）——拒絕改主鍵，防鎖死"); return 1 }
        print("→ 抓到 \(bName)")
        print("動作類型？ [k]快捷鍵 [s]系統動作 [d]還原預設 [x]停用這顆鍵：", terminator: "")
        guard let choice = readLine()?.lowercased().first else { return 1 }
        var action: ButtonAction?
        switch choice {
        case "k":
            print("輸入組合（例 cmd+shift+4 / ctrl+left / f13）：", terminator: "")
            guard let combo = readLine(), parseCombo(combo) != nil else { print("解析失敗"); return 64 }
            action = ButtonAction(type: "keys", keys: combo, action: nil)
        case "s":
            print("選項：\(SystemAction.allCases.map(\.rawValue).joined(separator: " / ")) / app:名稱")
            print("輸入：", terminator: "")
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
        let desc = action.map { $0.type == "keys" ? "keys: \($0.keys ?? "")" : $0.type == "disable" ? "停用" : "system: \($0.action ?? "")" } ?? "還原預設"
        print("✓ \(bName) → \(desc)（已存檔）")
        print("  生效方式：menubar 常駐時自動載入——重開 menubar 或點選單「重新載入改鍵引擎」")
        if action != nil, action?.type != "disable", !axTrusted() {
            print("  ⚠️ 尚未授權「輔助使用」——menubar 啟動引擎時會跳授權視窗")
        }
        return 0
    }
}
