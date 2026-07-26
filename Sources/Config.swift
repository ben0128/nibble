// Config.swift — 設定檔的型別與存取（純 Foundation，不碰裝置，方便單獨測試）
import Foundation

struct BMConfig: Codable {
    var dpi: Int? = nil
    var reportRateHz: Int? = nil
    var rgb: String? = nil            // "off" | "keep"
    var wheelMode: String? = nil      // "free" | "ratchet"（MX 系）
    var wheelThreshold: Int? = nil
    // 舊版格式：裝置名稱 → { "G7": {...} }。新版讀進來當成 Default profile（見 activeButtonMaps）
    var buttonMaps: [String: [String: ButtonAction]]? = nil
    // 改鍵組合：profile 名稱 → 裝置名稱 → { "G7": {...} }
    // profile 包住整個裝置層——切到 Gaming 時所有滑鼠一起換，不用逐隻切
    var buttonProfiles: [String: [String: [String: ButtonAction]]]? = nil
    var activeProfile: String? = nil
}

let defaultProfileName = "Default"

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
    var cfg = loadConfig() ?? BMConfig()
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
    var cfg = loadConfig() ?? BMConfig()
    migrateToProfiles(&cfg)
    guard cfg.buttonProfiles?[name] != nil else { throw ProfileError.notFound(name) }
    cfg.activeProfile = name
    try saveConfig(cfg)
}

/// copyFrom 有值就複製當前 profile 的內容，否則建空的
func createProfile(_ name: String, copyFrom source: String? = nil) throws {
    var cfg = loadConfig() ?? BMConfig()
    migrateToProfiles(&cfg)
    var profiles = cfg.buttonProfiles ?? [:]
    guard profiles[name] == nil else { throw ProfileError.exists(name) }
    profiles[name] = source.flatMap { profiles[$0] } ?? [:]
    cfg.buttonProfiles = profiles
    cfg.activeProfile = name
    try saveConfig(cfg)
}

func renameProfile(_ old: String, to new: String) throws {
    var cfg = loadConfig() ?? BMConfig()
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
    var cfg = loadConfig() ?? BMConfig()
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
