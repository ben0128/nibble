// FixtureTests.swift — docs/fixtures/*.json 的重播器。
//
// 這些向量是 Swift 與 Rust（windows/crates/nibble-core）兩份實作的共同裁判：
// 同一組 bytes、同一組期望值，兩邊各自重播。Swift 側跑它有兩個目的——
// 驗證匯出本身正確（向量原本就從這份測試搬出去），以及讓「改了 Swift 忘了改向量」
// 立刻爆炸，而不是等 Rust 那邊默默漂移。
//
// 比原本的 inline 測試更嚴的一點：FixtureTransport 連「送出去的 request bytes」
// 都逐一比對。欄位順序、fnsw 組裝、參數內容——以前只驗頭兩個 byte，現在全驗。
import Foundation

/// 照劇本走的 transport：每次 roundTrip 消耗一則 exchange，
/// 比對 request 與 preferLong，回應存在且 match 得上才回傳，否則 timeout。
final class FixtureTransport: HIDPPTransport {
    var onReport: (([UInt8]) -> Void)?
    var onRemoval: (() -> Void)?

    private let caseName: String
    private var exchanges: [[String: Any]]
    private(set) var consumed = 0

    init(caseName: String, exchanges: [[String: Any]]) {
        self.caseName = caseName
        self.exchanges = exchanges
    }

    var fullyConsumed: Bool { consumed == exchanges.count }

    func roundTrip(request payload: [UInt8], preferLong: Bool, timeout: TimeInterval,
                   match: ([UInt8]) -> Bool) throws -> [UInt8] {
        guard consumed < exchanges.count else {
            expect(false, "\(caseName): unexpected extra request \(payload)")
            throw HIDPPError.timeout
        }
        let ex = exchanges[consumed]
        consumed += 1
        expectEqual(payload, bytes(ex["request"]), "\(caseName): request bytes")
        expectEqual(preferLong, ex["prefer_long"] as? Bool ?? false, "\(caseName): prefer_long")
        guard let resp = ex["response"] else { throw HIDPPError.timeout }
        let r = bytes(resp)
        if match(r) { return r }
        throw HIDPPError.timeout   // 回應在、但比對不認（例如別人的 swid）→ 跟真實世界一樣是等到超時
    }
}

private func bytes(_ any: Any?) -> [UInt8] {
    ((any as? [Any]) ?? []).map { UInt8(($0 as! NSNumber).intValue) }
}

/// 兩份實作都從 repo 根目錄的 docs/fixtures 讀——路徑錨在本檔案位置，
/// 不依賴工作目錄（make test 和 mutate.py 的工作目錄不同）。
private let fixturesDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("docs/fixtures")

private func loadCases(_ file: String) -> [[String: Any]]? {
    guard let data = try? Data(contentsOf: fixturesDir.appendingPathComponent(file)),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cases = root["cases"] as? [[String: Any]] else { return nil }
    return cases
}

// MARK: - 協定向量

func runProtocolFixtures(_ file: String) {
    guard let cases = loadCases(file) else {
        expect(false, "cannot load fixture file \(file) — the shared vectors are part of the suite")
        return
    }
    for c in cases {
        let name = c["name"] as? String ?? "?"
        let swid = UInt8((c["swid"] as! NSNumber).intValue)
        let index = UInt8((c["device"] as! NSNumber).intValue)
        let op = c["op"] as? [String: Any] ?? [:]
        let expectVal = c["expect"] as? [String: Any] ?? [:]
        let tr = FixtureTransport(caseName: name, exchanges: c["exchanges"] as? [[String: Any]] ?? [])
        let dev = HIDPPDevice(transport: tr, index: index, swid: swid)

        var thrown: Error?
        do {
            switch op["kind"] as? String {
            case "ping":
                let v = try dev.ping()
                if let want = expectVal["ping"] as? [String: Any] {
                    expectEqual(v.major, (want["major"] as! NSNumber).intValue, "\(name): major")
                    expectEqual(v.minor, (want["minor"] as! NSNumber).intValue, "\(name): minor")
                }
            case "battery":
                let b = try dev.battery()
                if let want = expectVal["battery"] as? [String: Any] {
                    expectEqual(b.source, want["source"] as? String ?? "?", "\(name): source")
                    expectEqual(b.percent, (want["percent"] as! NSNumber).intValue, "\(name): percent")
                    expectEqual(b.charging, want["charging"] as? Bool ?? false, "\(name): charging")
                    let wantMv = want["millivolts"] as? NSNumber   // JSON null → NSNull → nil
                    expectEqual(b.millivolts, wantMv?.intValue, "\(name): millivolts")
                }
            case "dpi_get":
                let dpi = try dev.currentDPI()
                expectEqual(dpi, (expectVal["dpi"] as! NSNumber).intValue, "\(name): dpi")
            case "raw_call":
                _ = try dev.call(featureIndex: UInt8((op["feature_index"] as! NSNumber).intValue),
                                 function: UInt8((op["function"] as! NSNumber).intValue),
                                 params: bytes(op["params"]))
            case "feature_index_twice":
                let feature = UInt16((op["feature"] as! NSNumber).intValue)
                _ = try dev.featureIndex(of: feature)
                _ = try dev.featureIndex(of: feature)
            default:
                expect(false, "\(name): unknown op kind")
            }
        } catch { thrown = error }

        if let wantError = expectVal["error"] as? String {
            switch (wantError, thrown) {
            case ("timeout", .some(HIDPPError.timeout)),
                 ("deviceOffline", .some(HIDPPError.deviceOffline)),
                 ("protocolError", .some(HIDPPError.protocolError)):
                break
            default:
                expect(false, "\(name): wanted \(wantError), got \(thrown.map { "\($0)" } ?? "success")")
            }
        } else if let thrown {
            expect(false, "\(name): threw unexpectedly: \(thrown)")
        }
        expect(tr.fullyConsumed, "\(name): every scripted exchange was consumed")
    }
}

// MARK: - 設定檔語意向量

func runConfigFixtures(_ file: String) {
    guard let cases = loadCases(file) else {
        expect(false, "cannot load fixture file \(file) — the shared vectors are part of the suite")
        return
    }
    let realConfig = bmConfigURL
    defer { bmConfigURL = realConfig }

    for (i, c) in cases.enumerated() {
        let name = c["name"] as? String ?? "?"
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nibble-fixture-\(getpid())-\(i).json")
        bmConfigURL = tmp
        defer { try? FileManager.default.removeItem(at: tmp) }

        if let raw = c["existing_raw"] as? String {
            try? Data(raw.utf8).write(to: tmp)
        } else if let obj = c["existing"] as? [String: Any] {
            try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: tmp)
        }
        let before = try? String(contentsOf: tmp, encoding: .utf8)

        var thrown: Error?
        do {
            let op = c["op"] as? [String: Any] ?? [:]
            switch op["kind"] as? String {
            case "update_low_battery_notify":
                try updateLowBatteryNotify(enabled: op["enabled"] as? Bool ?? false,
                                           percent: (op["percent"] as! NSNumber).intValue)
            case "switch_profile":
                try switchProfile(to: op["to"] as? String ?? "")
            default:
                expect(false, "\(name): unknown op kind")
            }
        } catch { thrown = error }

        let expectVal = c["expect"] as? [String: Any] ?? [:]
        if let wantError = expectVal["error"] as? String {
            switch (wantError, thrown) {
            case ("unreadable", .some(is ConfigError)), ("notFound", .some(is ProfileError)):
                break
            default:
                expect(false, "\(name): wanted error \(wantError), got \(thrown.map { "\($0)" } ?? "success")")
            }
        } else if let thrown {
            expect(false, "\(name): threw unexpectedly: \(thrown)")
        }

        if expectVal["file_unchanged"] as? Bool == true {
            expectEqual(try? String(contentsOf: tmp, encoding: .utf8), before, "\(name): file untouched")
        }
        if let preserved = expectVal["keys_preserved"] as? [String] {
            let after = (try? Data(contentsOf: tmp))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            for key in preserved {
                expect(after[key] != nil, "\(name): key \(key) preserved")
            }
        }
        if let values = expectVal["values"] as? [String: Any] {
            let after = (try? Data(contentsOf: tmp))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            for (key, want) in values {
                expect((after[key] as? NSNumber) == (want as? NSNumber), "\(name): \(key) == \(want)")
            }
        }
        if expectVal.keys.contains("threshold_resolves"), expectVal["threshold_resolves"] is NSNull {
            expect(lowBatteryThreshold(loadConfig()) == nil, "\(name): threshold resolves to off")
        }
    }
}
