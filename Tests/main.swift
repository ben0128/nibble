// Tests/main.swift — 純邏輯層的回歸測試（檔名必須是 main.swift，Swift 只允許它有頂層語句）
//
// 為什麼是這些測試：涵蓋的都是這個專案實際出過事的地方——設定檔合併弄丟改鍵表、
// 板載 sector 尾端讀取、跨程序 swId 串話、巨集上限、電池 feature 的三種變體。
// 硬體 I/O、TCC 權限、AppKit 版面不在此列：那些只有真裝置和眼睛能驗。
//
// 不用 XCTest：那會帶進 SwiftPM 與一堆建置產物，違背這個專案的零依賴前提。
// `make test` 直接編譯本檔＋Sources（排除 main.swift）成獨立執行檔。
import Foundation

// MARK: - 極簡斷言工具

var failures: [String] = []
var checks = 0

func expect(_ cond: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !cond { failures.append("\(what)  (line \(line))") }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String, line: UInt = #line) {
    checks += 1
    if got != want { failures.append("\(what): got \(got), want \(want)  (line \(line))") }
}

func section(_ name: String) { print("• \(name)") }

// MARK: - 假的 transport：讓協定層可以在沒有滑鼠的情況下被測

final class MockTransport: HIDPPTransport {
    var sent: [[UInt8]] = []
    var queued: [[UInt8]] = []
    var preferLongSeen: [Bool] = []

    func roundTrip(request payload: [UInt8], preferLong: Bool, timeout: TimeInterval,
                   match: ([UInt8]) -> Bool) throws -> [UInt8] {
        sent.append(payload)
        preferLongSeen.append(preferLong)
        if let i = queued.firstIndex(where: match) { return queued.remove(at: i) }
        throw HIDPPError.timeout
    }
}

/// 組一則回應：[裝置索引, featureIndex, fn<<4|swid, params...]
func reply(_ dev: UInt8, _ featIdx: UInt8, fn: UInt8, swid: UInt8, _ params: [UInt8]) -> [UInt8] {
    [dev, featIdx, (fn << 4) | swid] + params
}

// MARK: - 電池電壓換算

section("battery voltage curve")
expectEqual(HIDPP.voltageToPercent(4200), 100, "above the curve clamps to 100")
expectEqual(HIDPP.voltageToPercent(3400), 1, "below the curve clamps to 1")
expectEqual(HIDPP.voltageToPercent(3850), 50, "curve anchor point")
expect(HIDPP.voltageToPercent(3900) > HIDPP.voltageToPercent(3800), "curve is monotonic")
expect((1...100).contains(HIDPP.voltageToPercent(3777)), "interpolated value stays in range")

// MARK: - 組合鍵解析

section("key combination parsing")
expect(parseCombo("cmd+c") != nil, "simple combo parses")
expect(parseCombo("cmd+shift+4") != nil, "multiple modifiers parse")
expect(parseCombo("ctrl+left") != nil, "arrow keys parse")
expect(parseCombo("f13") != nil, "function keys parse")
expect(parseCombo("cmd+nosuchkey") == nil, "unknown key name is rejected")
expect(parseCombo("") == nil, "empty string is rejected")
if let (flags, key) = parseCombo("cmd+shift+c") {
    expect(flags.contains(.maskCommand) && flags.contains(.maskShift), "both modifiers set")
    expectEqual(key, nibbleKeyCodes["c"]!, "key code matches the table")
}

// MARK: - 巨集解析（含上限——打錯的設定不該讓輸入卡死）

section("macro parsing")
expect(parseMacro("cmd+c, 150ms, cmd+v")?.count == 3, "keys and delays both become steps")
expect(parseMacro("cmd+c,1.5s,cmd+v") != nil, "seconds suffix parses")
expect(parseMacro("cmd+c") != nil, "single step is a valid macro")
expect(parseMacro("") == nil, "empty macro is rejected")
expect(parseMacro("cmd+c, wat, cmd+v") == nil, "an unparseable step rejects the whole macro")
expect(parseMacro(Array(repeating: "cmd+c", count: 65).joined(separator: ",")) == nil,
       "65 steps exceeds the 64-step cap")
expect(parseMacro(Array(repeating: "cmd+c", count: 64).joined(separator: ",")) != nil,
       "64 steps is still accepted")
expect(parseMacro("cmd+c, 40s, cmd+v") == nil, "total delay over 30s is rejected")
expect(parseMacro("cmd+c, 29s, cmd+v") != nil, "29s of delay is accepted")

// MARK: - HID++ 請求組裝與回應比對

section("HID++ framing and response matching")
do {
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    tr.queued = [reply(1, 0x00, fn: 1, swid: 0x0A, [4, 2, 0xAA])]
    let ver = try dev.ping()
    expectEqual(ver.major, 4, "ping decodes major version")
    expectEqual(ver.minor, 2, "ping decodes minor version")
    expectEqual(tr.sent.first?[0], 1, "request carries the device index")
    expectEqual(tr.sent.first?[2], (1 << 4) | 0x0A, "request carries fn<<4 | swid")
}

// 這是「跨程序串話」那個 bug 的回歸測試：別的程序用別的 swId，回應不該被我們認領
do {
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    tr.queued = [reply(1, 0x00, fn: 1, swid: 0x0B, [4, 2, 0xAA])]
    var timedOut = false
    do { _ = try dev.ping(timeout: 0.01) } catch { timedOut = true }
    expect(timedOut, "a reply carrying another process's swid is ignored")
}

// 接收器代答的錯誤要變成可讀的錯誤，而不是被當成資料
do {
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    // 1.0 式錯誤回應：[裝置索引, 0x8F, 原 featureIndex, 原 fnsw, 錯誤碼]
    tr.queued = [[1, 0x8F, 0x00, (1 << 4) | 0x0A, 0x09]]
    var offline = false
    do { _ = try dev.ping(timeout: 0.01) } catch HIDPPError.deviceOffline { offline = true } catch {}
    expect(offline, "receiver error 0x09 becomes deviceOffline")
}

do {
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    // 2.0 式錯誤回應：[裝置索引, 0xFF, 原 featureIndex, 原 fnsw, 錯誤碼]
    tr.queued = [[1, 0xFF, 0x00, (1 << 4) | 0x0A, 0x02]]
    var proto = false
    do { _ = try dev.ping(timeout: 0.01) } catch HIDPPError.protocolError { proto = true } catch {}
    expect(proto, "HID++ 2.0 error 0x02 becomes protocolError")
}

// 超過 3 bytes 的參數必須改用 long report
do {
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    tr.queued = [reply(1, 0x05, fn: 0, swid: 0x0A, [0, 0, 0, 0])]
    _ = try? dev.call(featureIndex: 0x05, function: 0, params: [1, 2, 3, 4, 5])
    expectEqual(tr.preferLongSeen.first, true, "params longer than 3 bytes force a long report")
}

// MARK: - 電池：G 系走 0x1001，MX 系走 0x1004

section("battery feature fallback")
do {
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    tr.queued = [
        reply(1, 0x00, fn: 0, swid: 0x0A, [0x06, 0, 0]),          // getFeature(0x1001) → index 6
        reply(1, 0x06, fn: 0, swid: 0x0A, [0x0E, 0xE7, 0x90]),    // 0x0EE7 = 3815 mV，flags 0x90
    ]
    let b = try dev.battery()
    expectEqual(b.source, "0x1001", "G-series battery uses the voltage feature")
    expectEqual(b.millivolts, 3815, "voltage decodes big-endian")
    expect(b.charging, "flags bit 7 means charging")
    expect(b.percent > 0 && b.percent < 100, "percent comes from the curve")
}

do {
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    tr.queued = [
        reply(1, 0x00, fn: 0, swid: 0x0A, [0x00, 0, 0]),          // 0x1001 不支援
        reply(1, 0x00, fn: 0, swid: 0x0A, [0x07, 0, 0]),          // 0x1004 → index 7
        reply(1, 0x07, fn: 1, swid: 0x0A, [55, 0, 1]),            // 55%、充電中
    ]
    let b = try dev.battery()
    expectEqual(b.source, "0x1004", "falls back to the unified battery feature")
    expectEqual(b.percent, 55, "percent read directly")
    expect(b.millivolts == nil, "unified battery reports no voltage")
}

// feature index 查過就該快取，不要每次都重問
do {
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    tr.queued = [reply(1, 0x00, fn: 0, swid: 0x0A, [0x09, 0, 0])]
    _ = try? dev.featureIndex(of: 0x8100)
    _ = try? dev.featureIndex(of: 0x8100)
    expectEqual(tr.sent.count, 1, "feature index is cached after the first lookup")
}

// MARK: - 設定檔：合併行為（曾經整份覆寫，弄丟改鍵表）

section("config encoding")
do {
    let json = """
    {"dpi":1600,"reportRateHz":1000,"rgb":"cycle",
     "buttonMaps":{"G502":{"G7":{"type":"keys","keys":"cmd+c"},
                           "G8":{"type":"macro","keys":"cmd+c, 150ms, cmd+v"}}}}
    """
    let cfg = try JSONDecoder().decode(BMConfig.self, from: Data(json.utf8))
    expectEqual(cfg.dpi, 1600, "dpi decodes")
    expectEqual(cfg.rgb, "cycle", "named lighting effect decodes")
    expectEqual(cfg.buttonMaps?["G502"]?.count, 2, "both mappings decode")
    expectEqual(cfg.buttonMaps?["G502"]?["G8"]?.type, "macro", "macro action decodes")

    // 往返一趟不能掉東西——這正是舊版覆寫式存檔弄丟改鍵表的地方
    let round = try JSONDecoder().decode(BMConfig.self, from: try JSONEncoder().encode(cfg))
    expectEqual(round.buttonMaps?["G502"]?["G8"]?.keys, "cmd+c, 150ms, cmd+v", "macro survives a round trip")
    expectEqual(round.rgb, "cycle", "lighting survives a round trip")
}

do {
    // 舊設定檔沒有 buttonMaps 欄位，也必須能讀
    let cfg = try JSONDecoder().decode(BMConfig.self, from: Data(#"{"dpi":800}"#.utf8))
    expectEqual(cfg.dpi, 800, "legacy config without buttonMaps still decodes")
    expect(cfg.buttonMaps == nil, "missing buttonMaps is nil, not an error")
}

// MARK: - 改鍵表的鍵名解析（G1/G2 必須永遠拒絕）

section("button map key parsing")
do {
    let map: [String: ButtonAction] = [
        "G1": ButtonAction(type: "keys", keys: "cmd+c", action: nil),
        "G2": ButtonAction(type: "keys", keys: "cmd+v", action: nil),
        "G7": ButtonAction(type: "keys", keys: "d", action: nil),
        "G11": ButtonAction(type: "macro", keys: "cmd+c, 50ms, cmd+v", action: nil),
    ]
    let parsed = parseSpyButtonMap(map)
    expect(parsed[0] == nil && parsed[1] == nil, "primary buttons are never remapped")
    expectEqual(parsed[6]?.keys, "d", "G7 maps to zero-based index 6")
    expectEqual(parsed[10]?.type, "macro", "two-digit button names parse")
    expectEqual(parsed.count, 2, "only remappable entries survive")
}

// MARK: - 收尾

print("")
if failures.isEmpty {
    print("✅ \(checks) checks passed")
    exit(0)
} else {
    print("❌ \(failures.count) of \(checks) checks failed\n")
    for f in failures { print("   \(f)") }
    exit(1)
}
