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
        case .timeout: return "等不到裝置回應（timeout）"
        case .deviceOffline(let c): return "裝置離線或睡眠中（err 0x\(String(format: "%02X", c))）——晃兩下滑鼠再試"
        case .receiverError(let c): return "接收器錯誤 0x\(String(format: "%02X", c))"
        case .protocolError(let c): return "HID++ 協定錯誤 0x\(String(format: "%02X", c))"
        case .featureUnsupported(let f): return "裝置不支援 feature 0x\(String(format: "%04X", f))"
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
        let resp = try transport.roundTrip(request: [dev, fi, fnsw] + params,
                                           preferLong: false, timeout: timeout) { p in
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
}
