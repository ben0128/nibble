// Transport.swift — IOKit 傳輸層（唯一 import IOKit 的地方）
// M0 學到的兩件事都固化在這裡：
//   1. SetReport 的 buffer 要「含」report ID byte（漏掉 = 0xE0005000）
//   2. 送 short 0x10 即可，回應一律 long 0x11
// HID++ collection 的地圖（參考 OpenLogi crates/openlogi-hid/src/transport.rs）：
//   0xFF00        — USB 接收器（Bolt/Unifying/Lightspeed）與藍牙 classic 直連，長短報告皆有
//   0xFF43/0x0202 — BLE 直連（MX Master 藍牙配對走這裡），只有 long report → short 要升級
//   0xFF43/0x0602 — 有線 G 系鍵盤
// 直連裝置的 device index 固定 0xFF；接收器下掛才需要探測 1–6。
import Foundation
import IOKit.hid

/// 輸入監控授權，不必真的去開裝置就能問（等 openAll() 失敗才知道太晚，而且有副作用）
func inputMonitoringGranted() -> Bool {
    IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
}

/// 多個 transport 共用同一個 IOHIDManager：manager 必須活得比所有 device 久
/// （被釋放會拆掉 input 管線），由最後一個 transport 的 deinit 帶著它一起關。
public final class HIDManagerHolder {
    public let manager: IOHIDManager
    public init(_ manager: IOHIDManager) { self.manager = manager }
    deinit { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
}

public final class ReceiverTransport: HIDPPTransport {
    // ⚠️ manager 一定要跟裝置活得一樣久：被 ARC 釋放會拆掉 input report 管線
    //（SetReport 卻照常成功——症狀是「送得出去、永遠收不到」）
    private let managerRef: HIDManagerHolder
    private let device: IOHIDDevice
    /// 直連（藍牙/BLE，不經接收器）：device index 用 0xFF，不探測 1–6
    public let isDirect: Bool
    /// BLE 直連只有 long report collection：短封包由 send() 自動升級
    public let longOnly: Bool
    public let transportKind: String
    private let inBuf: UnsafeMutablePointer<UInt8>
    private var inbox: [[UInt8]] = []
    public let productID: Int
    /// 事件旁聽：每一則進來的 report（含裝置主動通知）都會呼叫——改鍵引擎靠這個吃 spy 事件
    public var onReport: (([UInt8]) -> Void)?
    /// 裝置消失（藍牙斷線、接收器拔除）——直連路徑沒有接收器的 0x41 通知可用，
    /// 引擎宿主靠這個拆掉引擎，否則引擎看似在跑、實際永遠收不到事件
    public var onRemoval: (() -> Void)?
    let debug = ProcessInfo.processInfo.environment["NIBBLE_DEBUG"] != nil

    /// 開啟所有羅技 HID++ collection——接收器與藍牙直連裝置都在內，接收器排前面
    public static func openAll() throws -> [ReceiverTransport] {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(mgr, [
            [kIOHIDVendorIDKey: 0x046D, kIOHIDPrimaryUsagePageKey: 0xFF00],
            [kIOHIDVendorIDKey: 0x046D, kIOHIDPrimaryUsagePageKey: 0xFF43],
        ] as CFArray)
        let mo = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard mo == kIOReturnSuccess else {
            if mo == kIOReturnNotPermitted {
                throw HIDPPError.transport("Input Monitoring permission required: System Settings > Privacy & Security > Input Monitoring, enable this app, then rerun")
            }
            throw HIDPPError.transport(String(format: "IOHIDManagerOpen failed 0x%08X", UInt32(bitPattern: mo)))
        }
        let holder = HIDManagerHolder(mgr)
        let objs = (IOHIDManagerCopyDevices(mgr) as NSSet?)?.allObjects ?? []
        var out: [ReceiverTransport] = []
        var firstError: Error?
        for o in objs {
            let device = o as! IOHIDDevice
            guard isHIDPPCollection(device) else { continue }   // 非 HID++ collection 不算錯
            do { out.append(try ReceiverTransport(managerRef: holder, device: device)) }
            catch { if firstError == nil { firstError = error } }
        }
        guard !out.isEmpty else {
            // 有 HID++ collection 但全開失敗（多半是 Input Monitoring）要報真正原因，
            // 別誤導使用者去插接收器——doctor 的權限診斷也靠這則訊息辨識
            throw firstError ?? HIDPPError.transport("no Logitech device found — plug in the USB receiver or connect the mouse over Bluetooth")
        }
        out.sort { !$0.isDirect && $1.isDirect }   // 接收器優先：既有（G502）行為不變
        return out
    }

    /// 0xFF43 頁上只有 0x0202（BLE 直連）與 0x0602（有線 G 鍵盤）是 HID++，其他略過
    public static func isHIDPPCollection(_ device: IOHIDDevice) -> Bool {
        let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
        return page == 0xFF00 || (page == 0xFF43 && (usage == 0x0202 || usage == 0x0602))
    }

    public init(managerRef: HIDManagerHolder, device: IOHIDDevice) throws {
        guard Self.isHIDPPCollection(device) else {
            throw HIDPPError.transport("not a HID++ collection")
        }
        let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
        self.managerRef = managerRef
        self.device = device
        self.transportKind = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? "?"
        self.isDirect = page == 0xFF43 || transportKind.localizedCaseInsensitiveCompare("Bluetooth") == .orderedSame
        self.longOnly = (page == 0xFF43 && usage == 0x0202)
        self.productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let od = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard od == kIOReturnSuccess else {
            throw HIDPPError.transport(String(format: "IOHIDDeviceOpen failed 0x%08X (Input Monitoring permission?)", UInt32(bitPattern: od)))
        }
        // init 拋錯時 Swift 不會呼叫 deinit——buffer 要等所有會失敗的步驟過了才配置
        self.inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inBuf, 64, ReceiverTransport.reportCB, ctx)
        IOHIDDeviceRegisterRemovalCallback(device, ReceiverTransport.removalCB, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        // 長駐模式（menubar）會反覆開關 transport——不清乾淨會累積 kernel 資源
        // （manager 由 HIDManagerHolder 在最後一個 transport 釋放時一起關）
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        inBuf.deallocate()
    }

    private static let removalCB: IOHIDCallback = { ctx, _, _ in
        guard let ctx = ctx else { return }
        Unmanaged<ReceiverTransport>.fromOpaque(ctx).takeUnretainedValue().onRemoval?()
    }

    private static let reportCB: IOHIDReportCallback = { ctx, _, _, _, reportID, ptr, len in
        guard let ctx = ctx else { return }
        let me = Unmanaged<ReceiverTransport>.fromOpaque(ctx).takeUnretainedValue()
        var p = Array(UnsafeBufferPointer(start: ptr, count: len))
        if let f = p.first, (f == HIDPP.shortReportID || f == HIDPP.longReportID), UInt32(f) == reportID {
            p.removeFirst()   // 有些路徑 buffer 會含 report ID，統一剝掉
        }
        if me.debug { print("← id=0x\(String(format: "%02X", reportID)) [\(me.hex(p))]") }
        me.inbox.append(p)
        if me.inbox.count > 100 { me.inbox.removeFirst(me.inbox.count - 100) }   // 通知洪水保險
        me.onReport?(p)
    }

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

    public func send(_ payload: [UInt8], long: Bool) throws {
        // BLE 直連沒有 short collection：短封包一律升級成 long（payload 部分補零即可）
        let long = long || longOnly
        let id = long ? HIDPP.longReportID : HIDPP.shortReportID
        var buf: [UInt8] = [id] + payload
        let want = long ? HIDPP.longLen : HIDPP.shortLen
        while buf.count < want { buf.append(0) }
        if debug { print("→ id=0x\(String(format: "%02X", id)) [\(hex(Array(buf.dropFirst())))]") }
        let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), &buf, buf.count)
        guard r == kIOReturnSuccess else {
            throw HIDPPError.transport(String(format: "SetReport failed 0x%08X", UInt32(bitPattern: r)))
        }
    }

    public func roundTrip(request payload: [UInt8], preferLong: Bool, timeout: TimeInterval,
                          match: ([UInt8]) -> Bool) throws -> [UInt8] {
        try send(payload, long: preferLong)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
            if let i = inbox.firstIndex(where: match) {
                return inbox.remove(at: i)
            }
        }
        throw HIDPPError.timeout
    }
}
