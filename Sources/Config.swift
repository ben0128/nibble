// Config.swift — 設定檔的型別與存取（純 Foundation，不碰裝置，方便單獨測試）
import Foundation

struct BMConfig: Codable {
    var dpi: Int? = nil
    var reportRateHz: Int? = nil
    var rgb: String? = nil            // "off" | "keep"
    var wheelMode: String? = nil      // "free" | "ratchet"（MX 系）
    var wheelThreshold: Int? = nil
    // 低電量通知：兩個欄位而不是「0 = 關閉」——這個檔案是人會手改的，魔術數字讀不出意圖
    var lowBatteryNotify: Bool? = nil    // nil = 開啟（預設行為不必寫進檔案）
    var lowBatteryPercent: Int? = nil    // nil = defaultLowBatteryPercent
    // 舊版格式：裝置名稱 → { "G7": {...} }。新版讀進來當成 Default profile（見 activeButtonMaps）
    var buttonMaps: [String: [String: ButtonAction]]? = nil
    // 改鍵組合：profile 名稱 → 裝置名稱 → { "G7": {...} }
    // profile 包住整個裝置層——切到 Gaming 時所有滑鼠一起換，不用逐隻切
    var buttonProfiles: [String: [String: [String: ButtonAction]]]? = nil
    var activeProfile: String? = nil
}

let defaultProfileName = "Default"

let defaultLowBatteryPercent = 15
/// 上限 50：再高就不是「低電量」而是每天都在響；下限 5 是還來得及充的餘裕
let lowBatteryRange = 5...50

/// 低電量通知的門檻。回傳 nil 代表使用者關掉了通知。
/// 設定檔可能被手改成任何數字，所以夾在合理範圍內而不是照用。
func lowBatteryThreshold(_ cfg: BMConfig?) -> Int? {
    if cfg?.lowBatteryNotify == false { return nil }
    guard let p = cfg?.lowBatteryPercent else { return defaultLowBatteryPercent }
    return min(max(p, lowBatteryRange.lowerBound), lowBatteryRange.upperBound)
}

/// 「一次充放電只提醒一次」的閂鎖。抽成純結構是為了能測——
/// 這是這一輪最容易寫錯的狀態機：充電要重置、門檻改了要重新武裝、
/// 關掉再打開也要重新武裝，而這三件事都只會在真實使用中才踩到。
struct LowBatteryLatch {
    private var fired = false
    private var lastLimit: Int?

    /// true = 現在該發通知
    mutating func shouldFire(percent: Int, charging: Bool, limit: Int?) -> Bool {
        guard let limit else { fired = false; return false }   // 通知關閉
        // 門檻剛被調過就重新武裝：把 15 改成 30 而電量已經 25%，
        // 否則這一輪放電永遠不會提醒——使用者剛設的值要等下次充放電才生效
        if limit != lastLimit { fired = false; lastLimit = limit }
        if charging || percent > limit { fired = false; return false }
        if fired { return false }
        fired = true
        return true
    }
}

func updateLowBatteryNotify(enabled: Bool, percent: Int) throws {
    var cfg = try loadConfigForWrite()
    cfg.lowBatteryNotify = enabled
    cfg.lowBatteryPercent = min(max(percent, lowBatteryRange.lowerBound), lowBatteryRange.upperBound)
    try saveConfig(cfg)
}

/// 目前生效的改鍵表。舊設定檔沒有 profiles 時，把 buttonMaps 當成 Default——
/// 使用者不必手動搬家，現有映射照常運作。
func activeButtonMaps(_ cfg: BMConfig?) -> [String: [String: ButtonAction]] {
    guard let cfg else { return [:] }
    guard let profiles = cfg.buttonProfiles, !profiles.isEmpty else { return cfg.buttonMaps ?? [:] }
    // activeProfile 指向不存在的名字時退回 Default，不要讓一個壞名字清空所有映射
    return profiles[cfg.activeProfile ?? defaultProfileName] ?? profiles[defaultProfileName] ?? [:]
}

func profileNames(_ cfg: BMConfig?) -> [String] {
    guard let profiles = cfg?.buttonProfiles, !profiles.isEmpty else { return [defaultProfileName] }
    return profiles.keys.sorted { a, b in
        if a == defaultProfileName { return true }      // Default 永遠排第一
        if b == defaultProfileName { return false }
        return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }
}

func currentProfileName(_ cfg: BMConfig?) -> String {
    let names = profileNames(cfg)
    let active = cfg?.activeProfile ?? defaultProfileName
    return names.contains(active) ? active : defaultProfileName
}

/// 首次寫入 profile 時把舊的 buttonMaps 搬成 Default，並留一份備份
func migrateToProfiles(_ cfg: inout BMConfig) {
    guard cfg.buttonProfiles == nil else { return }
    if let legacy = cfg.buttonMaps, !legacy.isEmpty {
        let backup = bmConfigURL.deletingPathExtension().appendingPathExtension("json.bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: bmConfigURL, to: backup)
    }
    cfg.buttonProfiles = [defaultProfileName: cfg.buttonMaps ?? [:]]
    cfg.buttonMaps = nil
    if cfg.activeProfile == nil { cfg.activeProfile = defaultProfileName }
}

/// 對當前 profile 的裝置映射做一次修改後存檔
func updateActiveButtonMap(device: String, _ mutate: (inout [String: ButtonAction]) -> Void) throws {
    var cfg = try loadConfigForWrite()
    migrateToProfiles(&cfg)
    let name = currentProfileName(cfg)
    var profiles = cfg.buttonProfiles ?? [:]
    var devMap = profiles[name]?[device] ?? [:]
    mutate(&devMap)
    var forProfile = profiles[name] ?? [:]
    if devMap.isEmpty { forProfile.removeValue(forKey: device) } else { forProfile[device] = devMap }
    profiles[name] = forProfile
    cfg.buttonProfiles = profiles
    cfg.activeProfile = name
    try saveConfig(cfg)
}

enum ProfileError: Error, CustomStringConvertible {
    case notFound(String), exists(String), cannotDeleteDefault

    var description: String {
        switch self {
        case .notFound(let n): return "no profile named \(n)"
        case .exists(let n): return "a profile named \(n) already exists"
        case .cannotDeleteDefault: return "the Default profile can't be deleted"
        }
    }
}

func switchProfile(to name: String) throws {
    var cfg = try loadConfigForWrite()
    migrateToProfiles(&cfg)
    guard cfg.buttonProfiles?[name] != nil else { throw ProfileError.notFound(name) }
    cfg.activeProfile = name
    try saveConfig(cfg)
}

/// copyFrom 有值就複製當前 profile 的內容，否則建空的
func createProfile(_ name: String, copyFrom source: String? = nil) throws {
    var cfg = try loadConfigForWrite()
    migrateToProfiles(&cfg)
    var profiles = cfg.buttonProfiles ?? [:]
    guard profiles[name] == nil else { throw ProfileError.exists(name) }
    profiles[name] = source.flatMap { profiles[$0] } ?? [:]
    cfg.buttonProfiles = profiles
    cfg.activeProfile = name
    try saveConfig(cfg)
}

func renameProfile(_ old: String, to new: String) throws {
    var cfg = try loadConfigForWrite()
    migrateToProfiles(&cfg)
    var profiles = cfg.buttonProfiles ?? [:]
    guard let content = profiles[old] else { throw ProfileError.notFound(old) }
    guard profiles[new] == nil else { throw ProfileError.exists(new) }
    profiles.removeValue(forKey: old)
    profiles[new] = content
    cfg.buttonProfiles = profiles
    if cfg.activeProfile == old { cfg.activeProfile = new }   // 改名要跟著搬，否則 active 懸空
    try saveConfig(cfg)
}

func deleteProfile(_ name: String) throws {
    guard name != defaultProfileName else { throw ProfileError.cannotDeleteDefault }
    var cfg = try loadConfigForWrite()
    migrateToProfiles(&cfg)
    var profiles = cfg.buttonProfiles ?? [:]
    guard profiles.removeValue(forKey: name) != nil else { throw ProfileError.notFound(name) }
    if profiles.isEmpty { profiles[defaultProfileName] = [:] }   // 刪到一個不剩就重建空的 Default
    cfg.buttonProfiles = profiles
    if cfg.activeProfile == name { cfg.activeProfile = defaultProfileName }
    try saveConfig(cfg)
}

func loadConfig() -> BMConfig? {
    (try? Data(contentsOf: bmConfigURL)).flatMap { try? JSONDecoder().decode(BMConfig.self, from: $0) }
}

/// 寫入前一定要走這條，不能用 `loadConfig() ?? BMConfig()`。
///
/// loadConfig() 兩種情況都回 nil——「檔案不存在」和「檔案在、但解不開」——
/// 於是 `?? BMConfig()` 會把後者當成前者，用一份空設定覆蓋掉整個檔案。
/// 這個檔案是文件明確邀請使用者手改的，而 Codable 的 decodeIfPresent 對
/// 型別不符是 throw 而不是回 nil：把 `"lowBatteryPercent": 20.5` 打成小數，
/// 就足以讓下一次寫入清空所有 buttonProfiles。
func loadConfigForWrite() throws -> BMConfig {
    guard let data = try? Data(contentsOf: bmConfigURL) else { return BMConfig() }
    do { return try JSONDecoder().decode(BMConfig.self, from: data) }
    catch { throw ConfigError.unreadable("\(error)") }
}

enum ConfigError: Error, CustomStringConvertible {
    case unreadable(String)

    var description: String {
        // 訊息要能直接指路：使用者手改壞了，就該知道去哪裡看、以及原檔還在
        switch self {
        case .unreadable(let why):
            return "\(bmConfigURL.path) exists but could not be read — refusing to overwrite it. "
                 + "Fix the file (or move it aside) and retry. Details: \(why)"
        }
    }
}

func saveConfig(_ c: BMConfig) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    // .atomic：中途失敗（斷電、磁碟滿）留下的是原檔，而不是一個半截、解不開的檔案。
    // 沒有這個旗標，一次失敗的寫入就會把設定檔推進 loadConfigForWrite 的拒絕路徑。
    // watchConfig() 已經監看 .rename/.delete，所以換檔式寫入照樣會觸發重載。
    try (try enc.encode(c)).write(to: bmConfigURL, options: .atomic)
}

/// 正式執行時是 ~/.config/nibble.json。可用 NIBBLE_CONFIG 覆寫——
/// 測試靠它把寫入路徑導去暫存目錄，才有可能測到「寫入不能弄丟既有內容」。
var bmConfigURL: URL = {
    if let p = ProcessInfo.processInfo.environment["NIBBLE_CONFIG"], !p.isEmpty {
        return URL(fileURLWithPath: p)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/nibble.json")
}()

/// 燈效無法回讀，但設定檔記著我們最後套用的值——開機時用它當已知狀態
let nibbleRGBKinds = ["off", "cycle", "breathing"]
func lastKnownRGB() -> String? {
    guard let v = loadConfig()?.rgb, nibbleRGBKinds.contains(v) else { return nil }
    return v
}
