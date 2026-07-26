// HIDPP.swift — HIDPPCore 純協定層
// 規則：這個檔案永遠不 import IOKit——協定知識與 transport 完全解耦（可測試、可移植）。
import Foundation

public enum HIDPP {
    public static let shortReportID: UInt8 = 0x10   // 7 bytes 全長（含 report ID）
    public static let longReportID: UInt8 = 0x11    // 20 bytes 全長
    public static let shortLen = 7
    public static let longLen = 20

    public static let featureNames: [UInt16: String] = [
        0x0000: "IRoot",
        0x0001: "IFeatureSet",
        0x0003: "DeviceInformation",
        0x0005: "DeviceNameType",
        0x0007: "DeviceFriendlyName",
        0x0020: "ConfigChange",
        0x00C2: "DFUControl",
        0x1000: "BatteryUnifiedLevel",
        0x1001: "BatteryVoltage",
        0x1004: "UnifiedBattery",
        0x1814: "ChangeHost",
        0x1B04: "ReprogControlsV4",
        0x1D4B: "WirelessDeviceStatus",
        0x1E00: "EnableHiddenFeatures",
        0x2110: "SmartShift",
        0x2111: "SmartShiftEnhanced",
        0x2121: "HiResWheel",
        0x2201: "AdjustableDPI",
        0x8060: "ReportRate",
        0x8070: "ColorLEDEffects",
        0x8071: "RGBEffects",
        0x8100: "OnboardProfiles",
        0x8110: "MouseButtonSpy",
    ]

    /// Logitech 官方 CID（控制 ID）名稱表——只收錄有把握的；未知 CID 顯示 hex，
    /// 靠 press-to-identify 定位（M5c）。G 系列實測到的 CID 陸續補進來。
    public static let cidNames: [UInt16: String] = [
        0x0050: "Left Button",
        0x0051: "Right Button",
        0x0052: "Middle Button",
        0x0053: "Back Button",
        0x0054: "Back",
        0x0056: "Forward Button",
        0x0057: "Forward",
        0x005B: "Scroll Left",
        0x005D: "Scroll Right",
        0x00C3: "Gesture Button",
        0x00C4: "Smart Shift",
        0x00D7: "Smart Shift Enhanced",
    ]

    /// G 系列（0x1001）回報電壓不回報 %，用 LiPo 放電曲線粗估
    public static func voltageToPercent(_ mv: Int) -> Int {
        let curve = [(4180, 100), (4050, 85), (3950, 70), (3850, 50), (3750, 30), (3650, 15), (3550, 5), (3500, 2)]
        if mv >= curve[0].0 { return 100 }
        if mv <= curve[curve.count - 1].0 { return 1 }
        for i in 0..<(curve.count - 1) {
            let (v1, p1) = curve[i], (v2, p2) = curve[i + 1]
            if mv <= v1 && mv >= v2 { return p2 + (mv - v2) * (p1 - p2) / (v1 - v2) }
        }
        return 50
    }
}

public enum HIDPPError: Error, CustomStringConvertible {
    case timeout
    case deviceOffline(UInt8)       // 0x8F err 0x08/0x09：索引沒裝置或裝置睡眠
    case receiverError(UInt8)       // 其他 0x8F 錯誤
    case protocolError(UInt8)       // HID++ 2.0 錯誤（featureIndex 0xFF）
    case featureUnsupported(UInt16)
    case transport(String)

    public var description: String {
        switch self {
        case .timeout: return "device did not respond (timeout)"
        case .deviceOffline(let c): return "device offline or asleep (err 0x\(String(format: "%02X", c))) — move the mouse and retry"
        case .receiverError(let c): return "receiver error 0x\(String(format: "%02X", c))"
        case .protocolError(let c): return "HID++ protocol error 0x\(String(format: "%02X", c))"
        case .featureUnsupported(let f): return "device does not support feature 0x\(String(format: "%04X", f))"
        case .transport(let m): return m
        }
    }
}

/// Transport 抽象：送一則 HID++ 封包（payload 不含 report ID），等符合 match 的回應。
/// 回傳值同樣不含 report ID：[devIdx, featIdx, fnsw, params...]
public protocol HIDPPTransport: AnyObject {
    func roundTrip(request payload: [UInt8], preferLong: Bool, timeout: TimeInterval,
                   match: ([UInt8]) -> Bool) throws -> [UInt8]
}

public final class HIDPPDevice {
    public let transport: HIDPPTransport
    public let index: UInt8            // 接收器下掛 1–6；BT/USB 直連 0xFF
    public let swid: UInt8
    private var featureCache: [UInt16: UInt8] = [:]   // 0 = 已確認不支援

    public init(transport: HIDPPTransport, index: UInt8, swid: UInt8 = 0x0A) {
        self.transport = transport
        self.index = index
        self.swid = swid
    }

    // MARK: 低階呼叫

    public func call(featureIndex fi: UInt8, function fn: UInt8, params: [UInt8] = [],
                     timeout: TimeInterval = 1.0) throws -> [UInt8] {
        let fnsw = (fn << 4) | swid
        let dev = index
        // short report 的 params 上限 3 bytes，超過自動改用 long
        let needLong = params.count > 3
        let resp = try transport.roundTrip(request: [dev, fi, fnsw] + params,
                                           preferLong: needLong, timeout: timeout) { p in
            guard p.count >= 5, p[0] == dev else { return false }
            if p[1] == fi && p[2] == fnsw { return true }                    // 正常回應
            if p[1] == 0x8F && p[2] == fi && p[3] == fnsw { return true }    // 1.0 式錯誤（接收器代答）
            if p[1] == 0xFF && p[2] == fi && p[3] == fnsw { return true }    // 2.0 式錯誤
            return false
        }
        if resp[1] == 0x8F {
            let code = resp[4]
            if code == 0x08 || code == 0x09 { throw HIDPPError.deviceOffline(code) }
            throw HIDPPError.receiverError(code)
        }
        if resp[1] == 0xFF { throw HIDPPError.protocolError(resp[4]) }
        return Array(resp.dropFirst(3))   // 只回 params
    }

    public func call(feature: UInt16, function fn: UInt8, params: [UInt8] = []) throws -> [UInt8] {
        guard let fi = try featureIndex(of: feature) else { throw HIDPPError.featureUnsupported(feature) }
        return try call(featureIndex: fi, function: fn, params: params)
    }

    /// IRoot.getFeature，帶快取
    public func featureIndex(of feature: UInt16) throws -> UInt8? {
        if let hit = featureCache[feature] { return hit == 0 ? nil : hit }
        let r = try call(featureIndex: 0x00, function: 0x00,
                         params: [UInt8(feature >> 8), UInt8(feature & 0xFF)])
        featureCache[feature] = r[0]
        return r[0] == 0 ? nil : r[0]
    }

    public func has(_ feature: UInt16) -> Bool {
        // try? 會把 UInt8?? 攤平成 UInt8?：nil = 查詢失敗「或」不支援，語意上都算沒有
        (try? featureIndex(of: feature)) != nil
    }

    // MARK: 高階 API（M1 讀取組）

    public func ping(timeout: TimeInterval = 1.0) throws -> (major: Int, minor: Int) {
        let r = try call(featureIndex: 0x00, function: 0x01, params: [0, 0, 0xAA], timeout: timeout)
        return (Int(r[0]), Int(r[1]))
    }

    public func name() throws -> String {
        let count = Int(try call(feature: 0x0005, function: 0)[0])
        guard count > 0 else { return "?" }
        var bytes: [UInt8] = []
        while bytes.count < count {
            let chunk = try call(feature: 0x0005, function: 1, params: [UInt8(bytes.count)])
            bytes.append(contentsOf: chunk.prefix(min(16, count - bytes.count)))
        }
        return String(bytes: bytes.filter { $0 >= 32 && $0 < 127 }, encoding: .ascii) ?? "?"
    }

    public struct Battery {
        public let millivolts: Int?
        public let percent: Int
        public let charging: Bool
        public let source: String
    }

    /// G 系列優先走 0x1001 電壓；MX 系走 0x1004／0x1000
    public func battery() throws -> Battery {
        if try featureIndex(of: 0x1001) != nil {
            let r = try call(feature: 0x1001, function: 0)
            let mv = Int(r[0]) << 8 | Int(r[1])
            return Battery(millivolts: mv, percent: HIDPP.voltageToPercent(mv),
                           charging: (r[2] & 0x80) != 0, source: "0x1001")
        }
        if try featureIndex(of: 0x1004) != nil {
            let r = try call(feature: 0x1004, function: 1)
            return Battery(millivolts: nil, percent: Int(r[0]),
                           charging: r[2] == 1 || r[2] == 2 || r[2] == 3, source: "0x1004")
        }
        if try featureIndex(of: 0x1000) != nil {
            let r = try call(feature: 0x1000, function: 0)
            return Battery(millivolts: nil, percent: Int(r[0]), charging: r[2] != 0, source: "0x1000")
        }
        throw HIDPPError.featureUnsupported(0x1001)
    }

    public func currentDPI() throws -> Int {
        let r = try call(feature: 0x2201, function: 2, params: [0])   // getSensorDpi(sensor 0)
        return Int(r[1]) << 8 | Int(r[2])
    }

    public func reportRateHz() throws -> Int {
        let r = try call(feature: 0x8060, function: 1)                // getReportRate → 間隔 ms
        let ms = Int(r[0])
        return ms > 0 ? 1000 / ms : 0
    }

    public struct FeatureEntry {
        public let index: UInt8
        public let id: UInt16
        public let flags: UInt8   // bit7 obsolete, bit6 hidden, bit5 engineering
    }

    public func featureList() throws -> [FeatureEntry] {
        guard let fs = try featureIndex(of: 0x0001) else { return [] }
        let count = Int(try call(featureIndex: fs, function: 0)[0])
        var out = [FeatureEntry(index: 0, id: 0x0000, flags: 0)]
        guard count >= 1 else { return out }
        for i in 1...count {
            let r = try call(featureIndex: fs, function: 1, params: [UInt8(i)])
            out.append(FeatureEntry(index: UInt8(i), id: UInt16(r[0]) << 8 | UInt16(r[1]), flags: r[2]))
        }
        return out
    }

    // MARK: 按鍵控制（0x1b04 ReprogControlsV4）—— M5a 唯讀列舉

    public struct ControlInfo {
        public let cid: UInt16     // 控制 ID（按鍵身分）
        public let tid: UInt16     // 任務 ID（出廠預設功能）
        public let flags: UInt8
        public let pos: UInt8      // 遊戲滑鼠會回報實體位置編號（G1..Gn；0 = 無資料）
        public let group: UInt8
        public let groupMask: UInt8
        public let additional: UInt8

        public var isMouseButton: Bool { flags & 0x01 != 0 }
        public var isFKey: Bool { flags & 0x02 != 0 }
        public var isHotkey: Bool { flags & 0x04 != 0 }
        public var reprogrammable: Bool { flags & 0x10 != 0 }
        public var divertable: Bool { flags & 0x20 != 0 }
        public var persistentlyDivertable: Bool { flags & 0x40 != 0 }
        public var virtualControl: Bool { flags & 0x80 != 0 }
        public var rawXY: Bool { additional & 0x01 != 0 }
    }

    /// 逐鍵設定 divert：把該 CID 的事件改由軟體接管（runtime，斷電還原）
    /// fn3 setCidReporting：[cid_hi, cid_lo, flags, ...]，flags bit0=divert、bit1=divert 有效位
    public func setDivert(cid: UInt16, on: Bool) throws {
        let flags: UInt8 = on ? 0x03 : 0x02   // 一律帶「有效位」，off 就只送 valid 不送 divert
        _ = try call(feature: 0x1b04, function: 3,
                     params: [UInt8(cid >> 8), UInt8(cid & 0xFF), flags, 0, 0, 0, 0])
    }

    /// 列舉裝置上所有可程式化控制——改鍵 UI 的資料來源，換滑鼠自動適配
    public func controls() throws -> [ControlInfo] {
        guard let fi = try featureIndex(of: 0x1b04) else { throw HIDPPError.featureUnsupported(0x1b04) }
        let count = Int(try call(featureIndex: fi, function: 0)[0])
        var out: [ControlInfo] = []
        guard count >= 1 else { return out }
        for i in 0..<count {
            let r = try call(featureIndex: fi, function: 1, params: [UInt8(i)])   // getCidInfo(index)
            out.append(ControlInfo(cid: UInt16(r[0]) << 8 | UInt16(r[1]),
                                   tid: UInt16(r[2]) << 8 | UInt16(r[3]),
                                   flags: r[4], pos: r[5], group: r[6], groupMask: r[7], additional: r[8]))
        }
        return out
    }

    // MARK: 按鍵控制路線二（0x8110 MouseButtonSpy）—— G 系滑鼠沒有 0x1b04，按鍵層走這裡

    public func buttonSpyCount() throws -> Int {
        Int(try call(feature: 0x8110, function: 0)[0])   // getNbOfButtons
    }

    /// 現行 spy 層 remap 表（每顆實體鍵一 byte，值 = 映射目標鍵號 1-based）——M5a 唯讀
    public func buttonSpyRemapping(count: Int) throws -> [UInt8] {
        let r = try call(feature: 0x8110, function: 3)   // getRemapping
        return Array(r.prefix(count))
    }

    public func buttonSpyRemappingFull() throws -> [UInt8] {
        Array(try call(feature: 0x8110, function: 3).prefix(16))
    }

    /// 開始 spy：按鍵事件以 HID++ 通知送達（feature index + fnsw 0x00 + bitmask）
    public func buttonSpyStart() throws { _ = try call(feature: 0x8110, function: 1) }
    public func buttonSpyStop() throws { _ = try call(feature: 0x8110, function: 2) }

    /// 寫 spy 層 remap 表（runtime、斷電還原）。值 0 = 拔掉該鍵的標準 HID 輸出，
    /// 事件只走 spy 流——這就是 G 系的「divert」。
    public func buttonSpySetRemapping(_ table: [UInt8]) throws {
        var t = Array(table.prefix(16))
        while t.count < 16 { t.append(0) }
        _ = try call(feature: 0x8110, function: 4, params: t)
    }

    // MARK: 高階 API（M2 寫入組 — 全部 runtime 寫入，persist 一律 0，不碰 flash）

    /// 寫 DPI 後回讀驗證，回傳裝置實際生效值
    @discardableResult
    public func setDPI(_ dpi: Int, sensor: UInt8 = 0) throws -> Int {
        _ = try call(feature: 0x2201, function: 3,
                     params: [sensor, UInt8((dpi >> 8) & 0xFF), UInt8(dpi & 0xFF)])
        return try currentDPI()
    }

    /// 0x8060 fn0：支援的回報率（bitfield，bit n = 間隔 n+1 ms）
    public func supportedReportRatesHz() throws -> [Int] {
        let r = try call(feature: 0x8060, function: 0)
        var out: [Int] = []
        for bit in 0..<8 where r[0] & (1 << bit) != 0 { out.append(1000 / (bit + 1)) }
        return out
    }

    @discardableResult
    public func setReportRateHz(_ hz: Int) throws -> Int {
        let ms = UInt8(max(1, min(8, 1000 / max(hz, 125))))
        _ = try call(feature: 0x8060, function: 2, params: [ms])
        return try reportRateHz()
    }

    // MARK: Onboard（0x8100）——安全路線：模式旗標 + 唯讀

    public enum OnboardMode: UInt8, CustomStringConvertible {
        case onboard = 1, host = 2
        public var description: String { self == .onboard ? "onboard (device profile in charge)" : "host (software runtime in charge)" }
    }

    public func onboardMode() throws -> OnboardMode {
        let r = try call(feature: 0x8100, function: 2)
        return OnboardMode(rawValue: r[0]) ?? .onboard
    }

    /// 模式旗標呼叫，非 sector 寫入；斷電即回復 onboard
    public func setOnboardMode(_ m: OnboardMode) throws {
        _ = try call(feature: 0x8100, function: 1, params: [m.rawValue])
    }

    public struct OnboardInfo {
        public let memoryModel: UInt8, profileFormat: UInt8, macroFormat: UInt8
        public let profileCount: Int, profileCountOOB: Int, buttonCount: Int
        public let sectorCount: Int, sectorSize: Int
    }

    public func onboardInfo() throws -> OnboardInfo {
        let r = try call(feature: 0x8100, function: 0)
        return OnboardInfo(memoryModel: r[0], profileFormat: r[1], macroFormat: r[2],
                           profileCount: Int(r[3]), profileCountOOB: Int(r[4]), buttonCount: Int(r[5]),
                           sectorCount: Int(r[6]), sectorSize: Int(r[7]) << 8 | Int(r[8]))
    }

    /// 唯讀 memory read：一次 16 bytes（寫入功能凍結中，見計畫 §8）
    public func onboardRead(sector: UInt16, offset: UInt16) throws -> [UInt8] {
        try call(feature: 0x8100, function: 5,
                 params: [UInt8(sector >> 8), UInt8(sector & 0xFF),
                          UInt8(offset >> 8), UInt8(offset & 0xFF)])
    }

    // MARK: RGB（0x8070 ColorLEDEffects / 0x8071 RGBEffects）

    public func rgbFeatureID() throws -> UInt16 {
        if try featureIndex(of: 0x8071) != nil { return 0x8071 }
        if try featureIndex(of: 0x8070) != nil { return 0x8070 }
        throw HIDPPError.featureUnsupported(0x8070)
    }

    public func rgbZoneCount() throws -> Int {
        Int(try call(feature: rgbFeatureID(), function: 0)[0])
    }

    public struct RGBEffectSlot { public let slot: UInt8; public let effectID: UInt16 }

    /// 列出 zone 的效果槽（slot → effect ID；0x0000=off、0x0001=fixed…）
    public func rgbZoneEffects(zone: UInt8, maxSlots: Int = 16) -> [RGBEffectSlot] {
        guard let feat = try? rgbFeatureID() else { return [] }
        var out: [RGBEffectSlot] = []
        for s in 0..<maxSlots {
            guard let r = try? call(feature: feat, function: 2, params: [zone, UInt8(s)]) else { break }
            out.append(RGBEffectSlot(slot: UInt8(s), effectID: UInt16(r[2]) << 8 | UInt16(r[3])))
        }
        return out
    }

    /// 設定 zone 效果。params 補滿 16 bytes，最後的 persist byte 固定 0（只寫 RAM）
    public func rgbSetZone(zone: UInt8, slot: UInt8, effectParams: [UInt8] = []) throws {
        var p: [UInt8] = [zone, slot] + effectParams
        while p.count < 16 { p.append(0) }
        _ = try call(feature: rgbFeatureID(), function: 3, params: p)
    }

    /// 關燈：每個 zone 找 off 效果（ID 0x0000），沒有就用 fixed（0x0001）調成黑色
    public func rgbOff() throws -> [String] {
        var log: [String] = []
        let zones = try rgbZoneCount()
        for z in 0..<zones {
            let effects = rgbZoneEffects(zone: UInt8(z))
            if let off = effects.first(where: { $0.effectID == 0x0000 }) {
                try rgbSetZone(zone: UInt8(z), slot: off.slot)
                log.append("zone \(z): off (slot \(off.slot))")
            } else if let fixed = effects.first(where: { $0.effectID == 0x0001 }) {
                try rgbSetZone(zone: UInt8(z), slot: fixed.slot, effectParams: [0, 0, 0])
                log.append("zone \(z): fixed black (slot \(fixed.slot))")
            } else {
                log.append("zone \(z): no off/fixed effect, skipped (\(effects.count) slots)")
            }
        }
        return log
    }

    // MARK: SmartShift（0x2110/0x2111，MX 系；G502 無此 feature，未實測）

    @discardableResult
    public func setWheel(freespin: Bool, threshold: Int? = nil) throws -> [UInt8] {
        let feat: UInt16 = (try featureIndex(of: 0x2110) != nil) ? 0x2110 : 0x2111
        let mode: UInt8 = freespin ? 1 : 2
        let auto = UInt8(max(0, min(255, threshold ?? 0)))   // 0 = 不變更
        return try call(feature: feat, function: 1, params: [mode, auto, 0])
    }
}
