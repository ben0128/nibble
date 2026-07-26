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

        print("BenMouse v\(BENMOUSE_VERSION) ── \(name)")
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
