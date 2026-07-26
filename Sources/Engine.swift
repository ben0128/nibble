// Engine.swift — 改鍵引擎（雙路徑，由 makeRemapEngine 依裝置能力選路）
//   G 系 RemapEngine   : 0x8110 spy remap 表寫 0 拔標準輸出，事件為 bitmask
//   MX 系 MXRemapEngine: 0x1b04 逐 CID divert，事件為「目前按住的 CID 清單」
// 兩者皆 runtime：斷電、退場都會還原；0x41 重連通知後自動重掛。
import Foundation

/// 引擎狀態寫到檔案：跨程序可讀，讓 `nibble doctor` 能診斷「引擎為什麼沒動」
enum EngineState {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/nibble/engine.json")

    static func write(_ fields: [String: Any]) {
        var payload = read()
        for (k, v) in fields { payload[k] = v }
        payload["updated"] = ISO8601DateFormatter().string(from: Date())
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: payload,
                                               options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url)
        }
    }

    static func read() -> [String: Any] {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
}

/// 兩條路徑（G 系 spy／MX 系 divert）對宿主的統一介面
protocol RemapEngineProtocol: AnyObject {
    var mappingCount: Int { get }
    var active: Bool { get }
    func start() throws
    func stop()
}

/// 依裝置能力自動選路建引擎；config 的鍵名（"G7" 或 CID 名稱）在這裡解析成各自的索引
func makeRemapEngine(transport: ReceiverTransport, dev: HIDPPDevice,
                     savedMap: [String: ButtonAction]) -> RemapEngineProtocol? {
    guard !savedMap.isEmpty else { return nil }
    if dev.has(0x8110) {
        var m: [Int: ButtonAction] = [:]
        for (key, action) in savedMap where key.hasPrefix("G") {
            if let n = Int(key.dropFirst()), n >= 3 { m[n - 1] = action }   // G1/G2 永不接管
        }
        return RemapEngine(transport: transport, dev: dev, mappings: m)
    }
    if dev.has(0x1b04), let controls = try? dev.controls() {
        var m: [UInt16: ButtonAction] = [:]
        for c in controls where c.divertable {
            let name = HIDPP.cidNames[c.cid] ?? String(format: "CID 0x%04X", c.cid)
            if let action = savedMap[name] { m[c.cid] = action }
        }
        return MXRemapEngine(transport: transport, dev: dev, mappings: m)
    }
    return nil
}

/// MX 系引擎（0x1b04 ReprogControlsV4）
/// 差異：divert 是逐 CID 設定；事件（fn0 divertedButtonsEvent）回傳「目前按住的 CID 清單」，
/// 最多 4 個 16-bit CID，放開時該 CID 從清單消失。
final class MXRemapEngine: RemapEngineProtocol {
    private let dev: HIDPPDevice
    private let transport: ReceiverTransport
    private let featIdx: UInt8
    private let mappings: [UInt16: ButtonAction]   // CID → 動作
    private var pressed: Set<UInt16> = []
    private(set) var active = false

    init?(transport: ReceiverTransport, dev: HIDPPDevice, mappings: [UInt16: ButtonAction]) {
        guard !mappings.isEmpty, let fi = try? dev.featureIndex(of: 0x1b04) else { return nil }
        self.transport = transport
        self.dev = dev
        self.featIdx = fi
        self.mappings = mappings
    }

    var mappingCount: Int { mappings.count }

    func start() throws {
        for cid in mappings.keys { try dev.setDivert(cid: cid, on: true) }
        transport.onReport = { [weak self] p in self?.handle(p) }
        active = true
    }

    func stop() {
        guard active else { return }
        transport.onReport = nil
        for cid in mappings.keys { try? dev.setDivert(cid: cid, on: false) }
        active = false
    }

    private func reapply() {
        guard active else { return }
        for cid in mappings.keys { try? dev.setDivert(cid: cid, on: true) }
        pressed.removeAll()
    }

    private func handle(_ p: [UInt8]) {
        guard p.count >= 5, p[0] == dev.index else { return }
        if p[1] == 0x41 {
            if p[3] & 0x40 == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reapply() }
            }
            return
        }
        guard p[1] == featIdx, p[2] == 0x00 else { return }   // divertedButtonsEvent
        var now: Set<UInt16> = []
        var i = 3
        while i + 1 < p.count && i < 11 {
            let cid = UInt16(p[i]) << 8 | UInt16(p[i + 1])
            if cid != 0 { now.insert(cid) }
            i += 2
        }
        for cid in now.subtracting(pressed) {   // 新按下的才觸發
            if let a = mappings[cid] { performButtonAction(a) }
        }
        pressed = now
    }
}

final class RemapEngine: RemapEngineProtocol {
    private let dev: HIDPPDevice
    private let transport: ReceiverTransport
    private let spyIdx: UInt8
    private let mappings: [Int: ButtonAction]   // 0-based 鍵序 → 動作
    private var original: [UInt8] = []          // 進場前的 remap 表（退場還原）
    private var patched: [UInt8] = []           // 我們寫入的表（重連重掛用）
    private var prevMask: UInt16 = 0
    private var lastLog = Date.distantPast
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
            let mapped = mappings[bit]
            if let a = mapped { performButtonAction(a) }
            if Date().timeIntervalSince(lastLog) > 1 {
                lastLog = Date()
                EngineState.write([
                    "lastEventMask": String(format: "0x%04X", mask),
                    "lastEventBit": bit,
                    "lastEventButton": "G\(bit + 1)",
                    "lastEventMapped": mapped != nil,
                    "lastEventAction": mapped.map { $0.type == "keys" ? ($0.keys ?? "") : ($0.action ?? $0.type) } as Any,
                ])
            }
        }
    }
}
