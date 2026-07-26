// Engine.swift — G 系改鍵引擎（0x8110 MouseButtonSpy）
// 原理：把有映射的實體鍵在 spy remap 表寫 0（拔掉標準 HID 輸出），startSpy 後
// 按鍵以 HID++ 事件（bitmask）進來，由這裡合成動作。全程 runtime：斷電自動還原。
// MX 系（0x1b04 divert）引擎待 MX Master 3 上線後實作。
import Foundation

final class RemapEngine {
    private let dev: HIDPPDevice
    private let transport: ReceiverTransport
    private let spyIdx: UInt8
    private let mappings: [Int: ButtonAction]   // 0-based 鍵序 → 動作
    private var original: [UInt8] = []          // 進場前的 remap 表（退場還原）
    private var patched: [UInt8] = []           // 我們寫入的表（重連重掛用）
    private var prevMask: UInt16 = 0
    private(set) var active = false

    init?(transport: ReceiverTransport, dev: HIDPPDevice, mappings: [Int: ButtonAction]) {
        // try? 把 UInt8?? 攤平成 UInt8?：nil = 查詢失敗或不支援
        guard !mappings.isEmpty, let spy = try? dev.featureIndex(of: 0x8110) else { return nil }
        self.transport = transport
        self.dev = dev
        self.spyIdx = spy
        self.mappings = mappings
    }

    var mappingCount: Int { mappings.count }

    func start() throws {
        original = try dev.buttonSpyRemappingFull()
        patched = original
        for (i, _) in mappings where i < 16 { patched[i] = 0 }
        try dev.buttonSpySetRemapping(patched)
        try dev.buttonSpyStart()
        transport.onReport = { [weak self] p in self?.handle(p) }
        active = true
    }

    func stop() {
        guard active else { return }
        transport.onReport = nil
        try? dev.buttonSpyStop()
        try? dev.buttonSpySetRemapping(original)
        active = false
    }

    /// 滑鼠睡醒／斷電重連（0x41 通知）後，remap 表已被裝置重置——重掛
    private func reapply() {
        guard active else { return }
        try? dev.buttonSpySetRemapping(patched)
        try? dev.buttonSpyStart()
        prevMask = 0
    }

    private func handle(_ p: [UInt8]) {
        guard p.count >= 5, p[0] == dev.index else { return }
        // 連線通知：link 建立 → 延遲重掛（讓裝置先站穩）
        if p[1] == 0x41 {
            if p[3] & 0x40 == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reapply() }
            }
            return
        }
        // spy 事件：featIdx == 0x8110 的 index、fnsw == 0x00（事件 0、swid 0）
        guard p[1] == spyIdx, p[2] == 0x00 else { return }
        let mask = UInt16(p[3]) << 8 | UInt16(p[4])
        let newly = mask & ~prevMask
        prevMask = mask
        guard newly != 0 else { return }
        for bit in 0..<16 where newly & (1 << bit) != 0 {
            if let a = mappings[bit] { performButtonAction(a) }
        }
    }
}
