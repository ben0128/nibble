// Config.swift — 設定檔的型別與存取（純 Foundation，不碰裝置，方便單獨測試）
import Foundation

struct BMConfig: Codable {
    var dpi: Int? = nil
    var reportRateHz: Int? = nil
    var rgb: String? = nil            // "off" | "keep"
    var wheelMode: String? = nil      // "free" | "ratchet"（MX 系）
    var wheelThreshold: Int? = nil
    // per-device 改鍵表：裝置名稱 → { "G7": {type,keys,action} }（ButtonAction 定義在 Actions.swift）
    var buttonMaps: [String: [String: ButtonAction]]? = nil
}

func loadConfig() -> BMConfig? {
    (try? Data(contentsOf: bmConfigURL)).flatMap { try? JSONDecoder().decode(BMConfig.self, from: $0) }
}

func saveConfig(_ c: BMConfig) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try (try enc.encode(c)).write(to: bmConfigURL)
}

let bmConfigURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/nibble.json")

/// 燈效無法回讀，但設定檔記著我們最後套用的值——開機時用它當已知狀態
let nibbleRGBKinds = ["off", "cycle", "breathing"]
func lastKnownRGB() -> String? {
    guard let v = loadConfig()?.rgb, nibbleRGBKinds.contains(v) else { return nil }
    return v
}
