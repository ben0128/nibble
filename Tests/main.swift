// Tests/main.swift — 純邏輯層的回歸測試（檔名必須是 main.swift，Swift 只允許它有頂層語句）
//
// 為什麼是這些測試：涵蓋的都是這個專案實際出過事的地方——設定檔合併弄丟改鍵表、
// 跨程序 swId 串話、巨集上限、電池 feature 的三種變體、設定檔寫入弄丟不相關的鍵。
// 硬體 I/O、TCC 權限、AppKit 版面不在此列：那些只有真裝置和眼睛能驗。
//
// 沒涵蓋而且值得知道的一項：板載 backup 的「重疊讀」位移算術（sectorSize 不是 16 的
// 倍數時，最後一塊從 sectorSize-16 讀起再丟掉重複的前段）。那段算術目前寫在
// cmdOnboard 的迴圈裡，跟裝置 I/O 和寫檔混在一起，抽不出來就測不到。算錯的後果是
// 備份檔靜靜地壞掉——等到要還原才發現。要測就得先把位移計算抽成純函式。
//
// 不用 XCTest：那會帶進 SwiftPM 與一堆建置產物，違背這個專案的零依賴前提。
// `make test` 直接編譯本檔＋Sources（排除 main.swift）成獨立執行檔。
//
// 這份清單經過突變測試篩過一遍：把實作逐一改壞（76 種單點改動），看哪些斷言會叫。
// 叫不出來的就不是在保護任何東西，已經刪掉——共三類：
//   1. 測 Codable／JSONEncoder 而不是我們的程式（「缺少的欄位會是 nil」、
//      encode 完再 decode 值還在——那是標準庫的對稱性，不是這個專案的性質）
//   2. 測測試自己的佈置（「測試打得開鎖檔」）
//   3. 被同一個區塊裡更強的斷言完全覆蓋的
// 還修了一個「名字寫得像在保護、其實沒有」的：邊界斷言接在已經響過的閂鎖後面問，
// 擋住它的是 fired 旗標而不是門檻比較，所以把門檻放寬的改動照樣活著。
//
// 每個會 throw 的區塊都包了 catch：一個回歸不該讓整個程序 trap——那樣它後面的區塊
// 全部不會跑，而且看不出是哪一項壞了。（突變測試就是這樣先被蒙住四個斷言的。）
//
// 已知測不到的：saveConfig 的 .atomic。單一程序的功能測試觀察不到「寫入中途斷電
// 會留下原檔」，那個旗標是手動驗證的。刻意留著這個缺口，而不是假裝有守住。
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
    // 協定要求實作這兩個 hook（刻意沒有預設值：安靜吞掉事件的預設會讓測試假通過）
    var onReport: (([UInt8]) -> Void)?
    var onRemoval: (() -> Void)?
    /// 直連（藍牙／有線）：discover 應該只問 0xFF，不探測 1–6
    var directFlag = false
    var isDirect: Bool { directFlag }

    /// 讓測試模擬「裝置主動送來一則 report」——改鍵引擎的事件流入口
    func deliver(_ report: [UInt8]) { onReport?(report) }

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

// MARK: - 裝置探測（先前綁死 IOKit 型別，測不到；解耦後才能用 MockTransport 驅動）

section("device discovery")
do {
    let tr = MockTransport()
    tr.queued = [reply(1, 0x00, fn: 1, swid: HIDPP.softwareID, [4, 2, 0xAA])]
    let found = discover(tr, maxIndex: 3)
    expectEqual(found.count, 1, "discover finds the one awake index")
    expectEqual(found.first?.idx, 1, "…and reports which index answered")
    expectEqual(found.first?.ver.major, 4, "…with the HID++ version it reported")
}

do {
    // 有線滑鼠（G502 插著充電線）掛在 0xFF00 頁上，但只回應直連索引 0xFF——
    // 接收器的 1–6 全部沒人時要補問一次，這條 fallback 先前沒有任何測試
    let tr = MockTransport()
    tr.queued = [reply(0xFF, 0x00, fn: 1, swid: HIDPP.softwareID, [4, 5, 0xAA])]
    let found = discover(tr, maxIndex: 3)
    expectEqual(found.count, 1, "an empty receiver falls back to the direct index")
    expectEqual(found.first?.idx, 0xFF, "…and reports it as 0xFF")
}

do {
    let tr = MockTransport()   // 什麼都不回應
    expect(discover(tr, maxIndex: 3).isEmpty, "nothing awake means no devices")
    expectEqual(tr.sent.count, 4, "probes indexes 1–3, then the direct index once")
}

do {
    let tr = MockTransport()
    tr.directFlag = true
    tr.queued = [reply(0xFF, 0x00, fn: 1, swid: HIDPP.softwareID, [4, 2, 0xAA])]
    let found = discover(tr, maxIndex: 6)
    expectEqual(found.count, 1, "a direct transport yields its single device")
    expectEqual(tr.sent.count, 1, "…without probing receiver indexes 1–6")
}

// MARK: - 引擎選路（同樣是解耦後才測得到）

section("remap engine selection")
do {
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    expect(makeRemapEngine(transport: tr, dev: dev, savedMap: [:]) == nil, "no mappings means no engine")
    expectEqual(tr.sent.count, 0, "…decided without touching the device")
}

do {
    // 有映射但裝置兩種按鍵 feature 都沒有 → 不能硬撐出一個引擎
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    tr.queued = [
        reply(1, 0x00, fn: 0, swid: 0x0A, [0x00, 0, 0]),   // 0x8110 不支援
        reply(1, 0x00, fn: 0, swid: 0x0A, [0x00, 0, 0]),   // 0x1b04 也不支援
    ]
    let map = ["G7": ButtonAction(type: "keys", keys: "d", action: nil)]
    expect(makeRemapEngine(transport: tr, dev: dev, savedMap: map) == nil,
           "a device with neither button feature gets no engine")
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
    do {
        let ver = try dev.ping()
        expectEqual(ver.major, 4, "ping decodes major version")
        expectEqual(ver.minor, 2, "ping decodes minor version")
        expectEqual(tr.sent.first?[0], 1, "request carries the device index")
        expectEqual(tr.sent.first?[2], (1 << 4) | 0x0A, "request carries fn<<4 | swid")
    } catch { expect(false, "ping round trip threw: \(error)") }
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
    do {
        let b = try dev.battery()
        expectEqual(b.source, "0x1001", "G-series battery uses the voltage feature")
        expectEqual(b.millivolts, 3815, "voltage decodes big-endian")
        expect(b.charging, "flags bit 7 means charging")
        expect(b.percent > 0 && b.percent < 100, "percent comes from the curve")
    } catch { expect(false, "0x1001 battery read threw: \(error)") }
}

do {
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    tr.queued = [
        reply(1, 0x00, fn: 0, swid: 0x0A, [0x00, 0, 0]),          // 0x1001 不支援
        reply(1, 0x00, fn: 0, swid: 0x0A, [0x07, 0, 0]),          // 0x1004 → index 7
        reply(1, 0x07, fn: 1, swid: 0x0A, [55, 0, 1]),            // 55%、充電中
    ]
    do {
        let b = try dev.battery()
        expectEqual(b.source, "0x1004", "falls back to the unified battery feature")
        expectEqual(b.percent, 55, "percent read directly")
        expect(b.millivolts == nil, "unified battery reports no voltage")
    } catch { expect(false, "0x1004 battery fallback threw: \(error)") }
}

do {
    let tr = MockTransport()
    let dev = HIDPPDevice(transport: tr, index: 1, swid: 0x0A)
    tr.queued = [
        reply(1, 0x00, fn: 0, swid: 0x0A, [0x00, 0, 0]),          // 0x1001 不支援
        reply(1, 0x00, fn: 0, swid: 0x0A, [0x00, 0, 0]),          // 0x1004 也不支援
        reply(1, 0x00, fn: 0, swid: 0x0A, [0x08, 0, 0]),          // 0x1000 → index 8
        reply(1, 0x08, fn: 0, swid: 0x0A, [72, 0, 1]),            // 72%、status 非 0 = 充電
    ]
    do {
        let b = try dev.battery()
        expectEqual(b.source, "0x1000", "the oldest battery feature is the last resort")
        expectEqual(b.percent, 72, "level byte is the percentage")
        expect(b.charging, "a non-zero status byte means charging")
    } catch { expect(false, "0x1000 battery fallback threw: \(error)") }
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
  } catch { expect(false, "config decode threw: \(error)") }
}

do {
    // 舊設定檔沒有 buttonMaps 欄位，也必須能讀
    do {
        let cfg = try JSONDecoder().decode(BMConfig.self, from: Data(#"{"dpi":800}"#.utf8))
        expectEqual(cfg.dpi, 800, "legacy config without buttonMaps still decodes")
    } catch { expect(false, "legacy config decode threw: \(error)") }
}

// MARK: - 低電量通知門檻（設定檔是人會手改的，所以不信任裡面的數字）

section("low-battery threshold")
do {
    expectEqual(lowBatteryThreshold(nil), defaultLowBatteryPercent, "no config → default threshold")
    expectEqual(lowBatteryThreshold(BMConfig()), defaultLowBatteryPercent, "unset fields → default threshold")

    var cfg = BMConfig()
    cfg.lowBatteryPercent = 30
    expectEqual(lowBatteryThreshold(cfg), 30, "configured threshold is used")

    // 關掉通知後，門檻值留在檔案裡也不能讓它復活
    cfg.lowBatteryNotify = false
    expect(lowBatteryThreshold(cfg) == nil, "notify=false disables alerts regardless of the percent")

    cfg.lowBatteryNotify = true
    cfg.lowBatteryPercent = 99
    expectEqual(lowBatteryThreshold(cfg), lowBatteryRange.upperBound, "an out-of-range high value clamps down")
    cfg.lowBatteryPercent = 0
    expectEqual(lowBatteryThreshold(cfg), lowBatteryRange.lowerBound, "zero clamps up instead of silencing alerts")
    cfg.lowBatteryPercent = -5
    expectEqual(lowBatteryThreshold(cfg), lowBatteryRange.lowerBound, "a negative value clamps up")
    cfg.lowBatteryPercent = lowBatteryRange.lowerBound
    expectEqual(lowBatteryThreshold(cfg), lowBatteryRange.lowerBound, "the lower bound itself is accepted")
    cfg.lowBatteryPercent = lowBatteryRange.upperBound
    expectEqual(lowBatteryThreshold(cfg), lowBatteryRange.upperBound, "the upper bound itself is accepted")
}

// MARK: - 低電量閂鎖：一次充放電只響一次，但改門檻／充電／開關都要重新武裝

section("low-battery latch")
do {
    var l = LowBatteryLatch()
    expect(l.shouldFire(percent: 10, charging: false, limit: 15), "fires below the threshold")
    expect(!l.shouldFire(percent: 9, charging: false, limit: 15), "only once per discharge cycle")
    _ = l.shouldFire(percent: 80, charging: true, limit: 15)
    expect(l.shouldFire(percent: 10, charging: false, limit: 15), "charging re-arms it")
}

do {
    // 這是「調高門檻要當下生效」的回歸測試：15 → 30 而電量已經 25%
    var l = LowBatteryLatch()
    expect(l.shouldFire(percent: 10, charging: false, limit: 15), "fires at the old threshold")
    expect(l.shouldFire(percent: 25, charging: false, limit: 30), "a raised threshold fires this cycle, not the next")
    expect(!l.shouldFire(percent: 24, charging: false, limit: 30), "then it goes quiet again")
}

do {
    var l = LowBatteryLatch()
    expect(l.shouldFire(percent: 10, charging: false, limit: 15), "fires once")
    expect(!l.shouldFire(percent: 10, charging: false, limit: nil), "disabled never fires")
    expect(l.shouldFire(percent: 10, charging: false, limit: 15), "turning alerts off and on re-arms")
    expect(!l.shouldFire(percent: 15, charging: false, limit: 15), "same cycle, already fired — still quiet")
}

do {
    var l = LowBatteryLatch()
    expect(l.shouldFire(percent: 15, charging: false, limit: 15), "the boundary itself fires")
}

do {
    // 一定要用全新的閂鎖：接在「已經響過」後面問這件事，是 fired 旗標在擋，
    // 不是門檻比較在擋——把門檻放寬成 limit + 5 的變異體就這樣活了下來
    var l = LowBatteryLatch()
    expect(!l.shouldFire(percent: 16, charging: false, limit: 15), "one above the threshold never fires")
    expect(!l.shouldFire(percent: 20, charging: false, limit: 15), "well above it stays quiet too")
    expect(l.shouldFire(percent: 15, charging: false, limit: 15), "…and it is still armed when it does drop")
}

// MARK: - 設定檔寫入：絕不能弄丟不相關的鍵（這個專案最嚴重的失敗模式）

section("config write paths")
do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nibble-write-test-\(getpid()).json")
    let realConfig = bmConfigURL
    bmConfigURL = tmp                       // 絕不碰使用者真正的設定檔
    defer {
        bmConfigURL = realConfig
        try? FileManager.default.removeItem(at: tmp)
    }

  do {
    var cfg = BMConfig()
    cfg.dpi = 1600
    cfg.buttonProfiles = ["Gaming": ["G502": ["G7": ButtonAction(type: "keys", keys: "cmd+c", action: nil)]]]
    cfg.activeProfile = "Gaming"
    try saveConfig(cfg)

    try updateLowBatteryNotify(enabled: true, percent: 25)
    let merged = loadConfig()
    expectEqual(merged?.buttonProfiles?["Gaming"]?["G502"]?.count, 1, "a notify write keeps the button mappings")
    expectEqual(merged?.activeProfile, "Gaming", "a notify write keeps the active profile")
    expectEqual(merged?.dpi, 1600, "a notify write keeps the device settings")
    expectEqual(merged?.lowBatteryPercent, 25, "…and stores the new threshold")

    // 手改壞掉的設定檔：寧可報錯，也不能拿一份空的覆蓋過去
    let broken = #"{"lowBatteryPercent": 20.5, "buttonProfiles": {"Gaming": {}}}"#
    try Data(broken.utf8).write(to: tmp)
    var threw = false
    do { try updateLowBatteryNotify(enabled: true, percent: 30) } catch { threw = true }
    expect(threw, "a config that cannot be decoded makes the write fail loudly")
    expectEqual(try String(contentsOf: tmp, encoding: .utf8), broken, "the undecodable file is left byte-for-byte intact")

    // profile 操作走同一條保護
    threw = false
    do { try createProfile("Work") } catch { threw = true }
    expect(threw, "profile writes refuse an undecodable config too")
    expectEqual(try String(contentsOf: tmp, encoding: .utf8), broken, "…and still don't touch it")

    // 檔案根本不存在時，寫入要正常成功——保護不能變成「第一次也寫不了」。
    // 包在 do/catch 裡：讓 throw 變成一筆失敗紀錄，而不是把整個測試程序 trap 掉
    // （那樣看不出是哪一項壞了）
    try? FileManager.default.removeItem(at: tmp)
    do {
        try updateLowBatteryNotify(enabled: false, percent: 20)
        expect(loadConfig()?.lowBatteryNotify == false, "a missing config is created rather than treated as corrupt")
        expect(lowBatteryThreshold(loadConfig()) == nil, "…and the stored disable takes effect")
    } catch {
        expect(false, "a missing config is created rather than treated as corrupt (threw: \(error))")
    }

    // 寫入端也要夾範圍。只測讀取端會漏：讀取端的夾值會把寫入端的缺失遮起來
    do {
        try updateLowBatteryNotify(enabled: true, percent: 99)
        expectEqual(loadConfig()?.lowBatteryPercent, lowBatteryRange.upperBound,
                    "the write path clamps too, not just the read path")
    } catch {
        expect(false, "clamped write succeeds (threw: \(error))")
    }

    // symlink：~/.config/nibble.json 常被接到 dotfiles repo。
    // .atomic 是換檔寫入，天真地做會把連結換成普通檔案，使用者的真檔案就此被孤立
    do {
        let realFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nibble-real-\(getpid()).json")
        let link = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nibble-link-\(getpid()).json")
        defer {
            try? FileManager.default.removeItem(at: realFile)
            try? FileManager.default.removeItem(at: link)
        }
        var linked = BMConfig()
        linked.dpi = 800
        bmConfigURL = realFile
        try saveConfig(linked)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

        bmConfigURL = link
        try updateLowBatteryNotify(enabled: true, percent: 30)

        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        expect((attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
               "writing through a symlinked config keeps the symlink")
        bmConfigURL = realFile
        expectEqual(loadConfig()?.lowBatteryPercent, 30, "…and the real file behind it receives the write")
        expectEqual(loadConfig()?.dpi, 800, "…without losing what was already there")
    } catch {
        expect(false, "symlinked config write (threw: \(error))")
    }
  } catch { expect(false, "config write path threw unexpectedly: \(error)") }
}

// MARK: - 選單列存活探測（跨程序判斷，靠 flock 而不是比對程序名）

section("menu bar liveness probe")
do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nibble-lock-test-\(getpid()).lock")
    let realLock = menuBarLockURL
    menuBarLockURL = tmp
    defer {
        menuBarLockURL = realLock
        try? FileManager.default.removeItem(at: tmp)
    }

    expect(!menuBarRunning(), "no lock file at all means nothing is running")

    FileManager.default.createFile(atPath: tmp.path, contents: nil)
    expect(!menuBarRunning(), "an unlocked leftover lock file doesn't count as running")

    // flock 綁在 open file description 上，所以同程序另開一個 fd 也會衝突——
    // 這正是設定視窗（選單列的子程序）能正確偵測到父程序的原因
    // 這兩行是佈置，不是斷言：失敗的話下一個 expect 自己會報，不需要替測試自己記一筆
    let held = open(tmp.path, O_WRONLY)
    flock(held, LOCK_EX | LOCK_NB)
    expect(menuBarRunning(), "a held lock reads as running, even from the holding process")
    flock(held, LOCK_UN)
    close(held)
    expect(!menuBarRunning(), "releasing the lock makes it not running again")
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

// MARK: - 改鍵組合（profile）解析與邊界

section("button profiles")
do {
    func decode(_ json: String) -> BMConfig {
        try! JSONDecoder().decode(BMConfig.self, from: Data(json.utf8))
    }
    let act = #"{"type":"keys","keys":"d"}"#

    // 舊設定檔（只有 buttonMaps）必須照常運作，不能因為導入 profile 就變空
    let legacy = decode(#"{"buttonMaps":{"G502":{"G7":\#(act)}}}"#)
    expectEqual(activeButtonMaps(legacy)["G502"]?.count, 1, "legacy buttonMaps still resolve")
    expectEqual(profileNames(legacy), ["Default"], "legacy config lists one profile")

    let two = decode("""
    {"buttonProfiles":{"Default":{"G502":{"G7":\(act)}},
                       "Gaming":{"G502":{"G7":\(act),"G8":\(act)}}},
     "activeProfile":"Gaming"}
    """)
    expectEqual(activeButtonMaps(two)["G502"]?.count, 2, "the active profile's map is the one used")
    expectEqual(currentProfileName(two), "Gaming", "active profile is reported")
    expectEqual(profileNames(two).count, 2, "both profiles are listed")

    // 「Default 永遠排第一」是一條規則，不是字母順序的巧合。用 {Default, Gaming} 測不出來——
    // D 本來就在 G 前面，把規則整條刪掉也照樣通過。要一個字母序排在 Default 之前的名字。
    let sorted3 = decode(#"{"buttonProfiles":{"Gaming":{},"Aim":{},"Default":{}}}"#)
    expectEqual(profileNames(sorted3), ["Default", "Aim", "Gaming"], "Default sorts first, then alphabetical")

    // 懸空的 activeProfile 不該讓所有映射消失
    let dangling = decode("""
    {"buttonProfiles":{"Default":{"G502":{"G7":\(act)}}},"activeProfile":"Deleted"}
    """)
    expectEqual(activeButtonMaps(dangling)["G502"]?.count, 1, "an unknown active profile falls back to Default")
    expectEqual(currentProfileName(dangling), "Default", "and reports Default, not the missing name")

    // profiles 存在但活躍的那個是空的 → 空表，不要回退到別的 profile
    let emptyActive = decode("""
    {"buttonProfiles":{"Default":{"G502":{"G7":\(act)}},"Empty":{}},"activeProfile":"Empty"}
    """)
    expect(activeButtonMaps(emptyActive).isEmpty, "an empty active profile resolves to no mappings")

    // 遷移：舊格式進來，出去要變成 Default profile 且保留內容
    var migrating = legacy
    migrateToProfiles(&migrating)
    expectEqual(migrating.buttonProfiles?["Default"]?["G502"]?.count, 1, "migration moves buttonMaps into Default")
    expect(migrating.buttonMaps == nil, "migration clears the legacy field")
    expectEqual(migrating.activeProfile, "Default", "migration sets the active profile")

    // 已經是新格式就不要再動它
    var already = two
    migrateToProfiles(&already)
    expectEqual(already.activeProfile, "Gaming", "migration leaves an already-migrated config alone")
    expectEqual(already.buttonProfiles?.count, 2, "and keeps every profile")
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
