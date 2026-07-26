// Transport.swift — IOKit 傳輸層（唯一 import IOKit 的地方）
// M0 學到的兩件事都固化在這裡：
//   1. SetReport 的 buffer 要「含」report ID byte（漏掉 = 0xE0005000）
//   2. 送 short 0x10 即可，回應一律 long 0x11
import Foundation
import IOKit.hid

public final class ReceiverTransport: HIDPPTransport {
    // ⚠️ manager 一定要跟裝置活得一樣久：被 ARC 釋放會拆掉 input report 管線
    //（SetReport 卻照常成功——症狀是「送得出去、永遠收不到」）
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let inBuf: UnsafeMutablePointer<UInt8>
    private var inbox: [[UInt8]] = []
    public let productID: Int
    /// 事件旁聽：每一則進來的 report（含裝置主動通知）都會呼叫——改鍵引擎靠這個吃 spy 事件
    public var onReport: (([UInt8]) -> Void)?
    let debug = ProcessInfo.processInfo.environment["NIBBLE_DEBUG"] != nil

    /// 找到第一個羅技 vendor collection（接收器或有線滑鼠）並開啟
    public static func openFirst() throws -> ReceiverTransport {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDVendorIDKey: 0x046D,
            kIOHIDPrimaryUsagePageKey: 0xFF00,
        ] as CFDictionary)
        let mo = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard mo == kIOReturnSuccess else {
            if mo == kIOReturnNotPermitted {
                throw HIDPPError.transport("沒有「輸入監控」權限：系統設定 → 隱私權與安全性 → 輸入監控，打開你的終端機後重跑")
            }
            throw HIDPPError.transport(String(format: "IOHIDManagerOpen 失敗 0x%08X", UInt32(bitPattern: mo)))
        }
        let objs = (IOHIDManagerCopyDevices(mgr) as NSSet?)?.allObjects ?? []
        guard let first = objs.first else {
            throw HIDPPError.transport("找不到羅技接收器（vendor 0x046D / usage page 0xFF00）——接收器有插著嗎？")
        }
        return try ReceiverTransport(manager: mgr, device: first as! IOHIDDevice)
    }

    public init(manager: IOHIDManager, device: IOHIDDevice) throws {
        self.manager = manager
        self.device = device
        self.productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        self.inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        let od = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard od == kIOReturnSuccess else {
            throw HIDPPError.transport(String(format: "IOHIDDeviceOpen 失敗 0x%08X（輸入監控權限？）", UInt32(bitPattern: od)))
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inBuf, 64, ReceiverTransport.reportCB, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        // 長駐模式（menubar）會反覆開關 transport——不清乾淨會累積 kernel 資源
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        inBuf.deallocate()
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
        let id = long ? HIDPP.longReportID : HIDPP.shortReportID
        var buf: [UInt8] = [id] + payload
        let want = long ? HIDPP.longLen : HIDPP.shortLen
        while buf.count < want { buf.append(0) }
        if debug { print("→ id=0x\(String(format: "%02X", id)) [\(hex(Array(buf.dropFirst())))]") }
        let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), &buf, buf.count)
        guard r == kIOReturnSuccess else {
            throw HIDPPError.transport(String(format: "SetReport 失敗 0x%08X", UInt32(bitPattern: r)))
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
