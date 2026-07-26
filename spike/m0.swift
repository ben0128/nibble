// m0.swift — BenMouse M0 spike
// 目的：驗證從 macOS 直接用 HID++ 2.0 跟 G502 溝通這條路是通的。
// 流程：找 Lightspeed 接收器 (046D:C539) 的 vendor collection (page 0xFF00)
//       → ping 裝置索引 1 → 讀協定版本 → 讀電池 (0x1004，退回 0x1000)。
// 編譯：swiftc -O -swift-version 5 m0.swift -o m0
import Foundation
import IOKit.hid

// ---------- helpers ----------
func hexStr(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func ioErr(_ r: IOReturn) -> String { String(format: "0x%08X", UInt32(bitPattern: r)) }

// ---------- HID++ 常數 ----------
let SWID: UInt8 = 0x0A        // software id（1–15 任選，用來認回應是不是給我們的）
let DEV: UInt8 = 0x01         // 接收器下第一個配對裝置 = G502

enum Stage { case ping, featB1004, statB1004, featB1000, statB1000, featB1001, statB1001, featName, nameRead, done }
var stage: Stage = .ping
var pingOK = false
var batFeatIdx: UInt8 = 0
var nameFeatIdx: UInt8 = 0
var theDevice: IOHIDDevice!

// G 系列用電壓回報電池（0x1001）；用 LiPo 放電曲線粗估 %
func voltToPercent(_ mv: Int) -> Int {
    let curve = [(4180, 100), (4050, 85), (3950, 70), (3850, 50), (3750, 30), (3650, 15), (3550, 5), (3500, 2)]
    if mv >= curve[0].0 { return 100 }
    if mv <= curve[curve.count - 1].0 { return 1 }
    for i in 0..<(curve.count - 1) {
        let (v1, p1) = curve[i], (v2, p2) = curve[i + 1]
        if mv <= v1 && mv >= v2 { return p2 + (mv - v2) * (p1 - p2) / (v1 - v2) }
    }
    return 50
}

// macOS 的 SetReport：numbered reports 的 buffer 要「含」report ID byte（同 hidapi 慣例）
// short 0x10 = 7B 全長、long 0x11 = 20B 全長
func send(_ payload: [UInt8], id: UInt8) {
    var buf: [UInt8] = [id] + payload
    let want = (id == 0x10) ? 7 : 20
    while buf.count < want { buf.append(0) }
    let r = IOHIDDeviceSetReport(theDevice, kIOHIDReportTypeOutput, CFIndex(id), &buf, buf.count)
    print("→ id=0x\(String(format: "%02X", id)) [\(hexStr(buf))] \(r == kIOReturnSuccess ? "" : "❌ setReport 失敗 \(ioErr(r))")")
}

func sendPing(id: UInt8) { send([DEV, 0x00, 0x10 | SWID, 0x00, 0x00, 0xAA], id: id) }                  // IRoot.ping
func sendGetFeature(_ feat: UInt16, id: UInt8) {                                                        // IRoot.getFeature
    send([DEV, 0x00, 0x00 | SWID, UInt8(feat >> 8), UInt8(feat & 0xFF), 0x00], id: id)
}

var lastReportID: UInt8 = 0x10  // 記住有效的 report 長度路徑

func handle(_ p: [UInt8]) {
    guard p.count >= 5 else { return }
    // HID++ 1.0 式錯誤回報（接收器代答）：[devIdx, 0x8F, subId, addr, errCode]
    if p[1] == 0x8F {
        let code = p[4]
        let hint: String
        switch code {
        case 0x07: hint = "busy — 裝置忙碌"
        case 0x08: hint = "unknown device — 這個索引沒有配對裝置"
        case 0x09: hint = "resource error — 滑鼠離線或睡眠中，晃兩下滑鼠再試"
        default:   hint = "錯誤碼 0x" + String(format: "%02X", code)
        }
        print("   ↳ ⚠️ 接收器回報錯誤：\(hint)")
        return
    }
    // 連線狀態通知（0x41）：滑鼠醒了/睡了會主動送
    if p[1] == 0x41 {
        let linkDown = (p[3] & 0x40) != 0
        print("   ↳ 🔔 連線通知：滑鼠\(linkDown ? "離線" : "上線")")
        if !linkDown && !pingOK { sendPing(id: lastReportID) }
        return
    }
    guard p[0] == DEV else { return }
    let fnsw = p[2]

    switch stage {
    case .ping where p[1] == 0x00 && fnsw == (0x10 | SWID):
        if p.count >= 6 && p[5] == 0xAA {
            pingOK = true
            print("   ↳ ✅ PING 成功！HID++ 協定版本 \(p[3]).\(p[4])（≥2.0，feature 架構可用）")
            stage = .featB1004
            sendGetFeature(0x1004, id: lastReportID)   // UnifiedBattery
        }
    case .featB1004 where p[1] == 0x00 && fnsw == (0x00 | SWID):
        batFeatIdx = p[3]
        if batFeatIdx == 0 {
            print("   ↳ 裝置不支援 0x1004，改試 0x1000")
            stage = .featB1000
            sendGetFeature(0x1000, id: lastReportID)
        } else {
            print("   ↳ UnifiedBattery(0x1004) 在 feature index \(batFeatIdx)")
            stage = .statB1004
            send([DEV, batFeatIdx, 0x10 | SWID, 0, 0, 0], id: lastReportID)   // fn1 get_status
        }
    case .statB1004 where p[1] == batFeatIdx && fnsw == (0x10 | SWID):
        let soc = p[3], chg = p[5]
        let st: String
        switch chg {
        case 0: st = "放電中"
        case 1, 2: st = "充電中 ⚡"
        case 3: st = "已充飽"
        default: st = "狀態碼 \(chg)"
        }
        print("   ↳ 🔋 電池 \(soc)%（\(st)）")
        stage = .done
    case .featB1000 where p[1] == 0x00 && fnsw == (0x00 | SWID):
        batFeatIdx = p[3]
        if batFeatIdx == 0 {
            print("   ↳ 0x1000 也不支援 → G 系列走電壓路線，試 0x1001")
            stage = .featB1001
            sendGetFeature(0x1001, id: lastReportID)                          // BatteryVoltage
            return
        }
        print("   ↳ BatteryStatus(0x1000) 在 feature index \(batFeatIdx)")
        stage = .statB1000
        send([DEV, batFeatIdx, 0x00 | SWID, 0, 0, 0], id: lastReportID)       // fn0 GetBatteryLevelStatus
    case .statB1000 where p[1] == batFeatIdx && fnsw == (0x00 | SWID):
        print("   ↳ 🔋 電池 \(p[3])%（status raw=\(p[5])）")
        stage = .featName
        sendGetFeature(0x0005, id: lastReportID)
    case .featB1001 where p[1] == 0x00 && fnsw == (0x00 | SWID):
        batFeatIdx = p[3]
        if batFeatIdx == 0 {
            print("   ↳ 0x1001 也不支援，電池先跳過")
            stage = .featName; sendGetFeature(0x0005, id: lastReportID); return
        }
        print("   ↳ BatteryVoltage(0x1001) 在 feature index \(batFeatIdx) ← G 系列限定")
        stage = .statB1001
        send([DEV, batFeatIdx, 0x00 | SWID, 0, 0, 0], id: lastReportID)       // fn0 get_battery_voltage
    case .statB1001 where p[1] == batFeatIdx && fnsw == (0x00 | SWID):
        let mv = Int(p[3]) << 8 | Int(p[4])
        let flags = p[5]
        let chg = (flags & 0x80) != 0 ? " ⚡看起來在充電" : ""
        print("   ↳ 🔋 電池電壓 \(String(format: "%.2f", Double(mv) / 1000))V ≈ \(voltToPercent(mv))%\(chg)（flags=0x\(String(format: "%02X", flags))）")
        stage = .featName
        sendGetFeature(0x0005, id: lastReportID)                              // DeviceNameType
    case .featName where p[1] == 0x00 && fnsw == (0x00 | SWID):
        nameFeatIdx = p[3]
        if nameFeatIdx == 0 { stage = .done; return }
        stage = .nameRead
        send([DEV, nameFeatIdx, 0x10 | SWID, 0x00, 0, 0], id: lastReportID)   // fn1 getDeviceName(0)
    case .nameRead where p[1] == nameFeatIdx && fnsw == (0x10 | SWID):
        let chars = p.dropFirst(3).prefix(16).filter { $0 >= 32 && $0 < 127 }
        print("   ↳ 🖱 裝置自報名稱：「\(String(bytes: chars, encoding: .ascii) ?? "?")…」")
        stage = .done
    default:
        break
    }
}

let reportCB: IOHIDReportCallback = { _, _, _, _, reportID, ptr, len in
    var p = Array(UnsafeBufferPointer(start: ptr, count: len))
    print("← id=0x\(String(format: "%02X", reportID)) [\(hexStr(p))]")
    if let f = p.first, (f == 0x10 || f == 0x11), UInt32(f) == reportID { p.removeFirst() }
    handle(p)
}

// ---------- main ----------
print("BenMouse M0 — HID++ spike\n")
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x046D, kIOHIDProductIDKey: 0xC539] as CFDictionary)
let mo = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
guard mo == kIOReturnSuccess else {
    print("❌ IOHIDManagerOpen 失敗 \(ioErr(mo))")
    print("   若是 0xE00002E2：系統設定 → 隱私權與安全性 → 輸入監控，把你的終端機打開後重跑")
    exit(2)
}
let objs = (IOHIDManagerCopyDevices(mgr) as NSSet?)?.allObjects ?? []
print("接收器上的 HID collections（\(objs.count) 個）：")
var vendor: IOHIDDevice?
for o in objs {
    let d = o as! IOHIDDevice
    let page = (IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
    let usage = (IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
    let maxOut = (IOHIDDeviceGetProperty(d, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? -1
    print(String(format: "  - page=0x%04X usage=%-3d maxOutputReport=%dB", page, usage, maxOut))
    if page == 0xFF00 { vendor = d }
}
guard let dev = vendor else { print("\n❌ 沒找到 vendor page 0xFF00 的 collection"); exit(3) }
theDevice = dev
let od = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
guard od == kIOReturnSuccess else {
    print("❌ IOHIDDeviceOpen 失敗 \(ioErr(od)) — 大概率是輸入監控權限，見上面路徑")
    exit(2)
}
print("✅ vendor collection 已開啟，開始 ping 裝置索引 \(DEV)…\n")

let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
IOHIDDeviceRegisterInputReportCallback(dev, inBuf, 64, reportCB, nil)
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

sendPing(id: 0x10)
var ticks = 0
while stage != .done && ticks < 20 {
    CFRunLoopRunInMode(.defaultMode, 0.7, false)
    ticks += 1
    if !pingOK && stage == .ping && ticks % 2 == 0 {
        lastReportID = (ticks >= 6) ? 0x11 : 0x10   // short 沒人理就改試 long
        sendPing(id: lastReportID)
    }
}
print(pingOK ? "\n🎉 M0 通過：macOS → HID++ → G502 這條路是通的！"
             : "\n😴 沒收到 ping 回應：滑鼠可能在睡（充電板上會睡）。晃兩下滑鼠，馬上重跑一次。")
exit(pingOK ? 0 : 1)
