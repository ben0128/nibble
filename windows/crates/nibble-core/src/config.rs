// config.rs — 設定檔語意（Sources/Config.swift 的對應實作）。
//
// 這裡的規則是 macOS v1.7.1 用一次真實的資料損失換來的，逐條照搬：
//   1. 檔案存在但解不開 → 拒絕寫入、原檔一個 byte 都不動（loadConfig ?? 空設定 = 全滅）
//   2. 寫入一律原子（tempfile + rename）——寫壞的檔案會餵回規則 1 的拒絕路徑
//   3. rename 是「換檔」，會殺掉 symlink——先解析到真目標再寫（dotfiles 使用者）
//   4. 永遠合併，沒有任何路徑從零重寫整份檔案
//   5. 範圍外的值在寫入端就夾住，不是只靠讀取端遮掩
// 一致性由 docs/fixtures/config-merge.json 裁定（Swift 側跑同一組向量）。
//
// 與 Swift 版的兩個已知差異（皆屬改善、fixtures 不驗）：
//   - save 會替目標建立父目錄（%APPDATA%\nibble 首次寫入時不存在是常態）
//   - migrate 的 .bak 備份屬檔案層，這裡的純函式版不寫備份——呼叫端負責
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

pub const DEFAULT_PROFILE: &str = "Default";
pub const DEFAULT_LOW_BATTERY_PERCENT: i64 = 15;
/// 上限 50：再高就不是「低電量」而是每天都在響；下限 5 是還來得及充的餘裕
pub const LOW_BATTERY_RANGE: std::ops::RangeInclusive<i64> = 5..=50;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ButtonAction {
    /// "keys" | "system" | "macro" | "disable"
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keys: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
}

type DeviceMap = HashMap<String, HashMap<String, ButtonAction>>;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BMConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dpi: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub report_rate_hz: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rgb: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wheel_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wheel_threshold: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub low_battery_notify: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub low_battery_percent: Option<i64>,
    /// 舊版格式：裝置名稱 → { "G7": {...} }；讀進來當成 Default profile
    #[serde(skip_serializing_if = "Option::is_none")]
    pub button_maps: Option<DeviceMap>,
    /// profile 名稱 → 裝置名稱 → { "G7": {...} }
    #[serde(skip_serializing_if = "Option::is_none")]
    pub button_profiles: Option<HashMap<String, DeviceMap>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_profile: Option<String>,
}

#[derive(Debug)]
pub enum ConfigError {
    /// 檔案在、但解不開——絕不覆蓋
    Unreadable {
        path: PathBuf,
        why: String,
    },
    Io(std::io::Error),
    ProfileNotFound(String),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            // 句式與 Swift 版一字不差——使用者在兩個平台看到同一種誠實
            ConfigError::Unreadable { path, why } => write!(
                f,
                "{} exists but could not be read — refusing to overwrite it. \
                 Fix the file (or move it aside) and retry. Details: {}",
                path.display(),
                why
            ),
            ConfigError::Io(e) => write!(f, "{e}"),
            ConfigError::ProfileNotFound(n) => write!(f, "no profile named {n}"),
        }
    }
}

impl std::error::Error for ConfigError {}

/// 讀取用：檔案不存在或解不開都回 None（呼叫端只想知道「現在的有效設定」）
pub fn load_config(path: &Path) -> Option<BMConfig> {
    let data = fs::read(path).ok()?;
    serde_json::from_slice(&data).ok()
}

/// 寫入前一定走這條，不能用 `load_config(...).unwrap_or_default()`——
/// 那會把「解不開」當成「不存在」，然後用一份空設定覆蓋掉使用者的檔案。
pub fn load_config_for_write(path: &Path) -> Result<BMConfig, ConfigError> {
    let data = match fs::read(path) {
        Ok(d) => d,
        Err(_) => return Ok(BMConfig::default()), // 真的沒有 → 從空的開始
    };
    serde_json::from_slice(&data).map_err(|e| ConfigError::Unreadable {
        path: path.to_path_buf(),
        why: e.to_string(),
    })
}

pub fn save_config(path: &Path, cfg: &BMConfig) -> Result<(), ConfigError> {
    // symlink 要寫穿過去：原子寫是「換檔」，直接對連結 rename 會把它換成普通檔案
    let target = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(ConfigError::Io)?;
    }
    let mut json = serde_json::to_vec_pretty(cfg).expect("BMConfig always serializes");
    json.push(b'\n');
    let tmp = target.with_extension(format!("tmp{}", std::process::id()));
    fs::write(&tmp, &json).map_err(ConfigError::Io)?;
    // std::fs::rename 在兩個平台都會取代既有檔案（Windows 走 MOVEFILE_REPLACE_EXISTING）
    fs::rename(&tmp, &target).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        ConfigError::Io(e)
    })
}

/// 低電量門檻。None = 使用者關掉了通知。設定檔可能被手改成任何數字——夾住，不照用。
pub fn low_battery_threshold(cfg: Option<&BMConfig>) -> Option<i64> {
    if let Some(c) = cfg {
        if c.low_battery_notify == Some(false) {
            return None;
        }
        if let Some(p) = c.low_battery_percent {
            return Some(clamp_percent(p));
        }
    }
    Some(DEFAULT_LOW_BATTERY_PERCENT)
}

pub fn clamp_percent(p: i64) -> i64 {
    p.clamp(*LOW_BATTERY_RANGE.start(), *LOW_BATTERY_RANGE.end())
}

pub fn update_low_battery_notify(
    path: &Path,
    enabled: bool,
    percent: i64,
) -> Result<(), ConfigError> {
    let mut cfg = load_config_for_write(path)?;
    cfg.low_battery_notify = Some(enabled);
    cfg.low_battery_percent = Some(clamp_percent(percent)); // 寫入端就夾，讀取端的夾值只是第二道
    save_config(path, &cfg)
}

/// 首次接觸 profile 時把舊的 buttonMaps 搬成 Default（冪等；已遷移的不動）
pub fn migrate_to_profiles(cfg: &mut BMConfig) {
    if cfg.button_profiles.is_some() {
        return;
    }
    let maps = cfg.button_maps.take().unwrap_or_default();
    cfg.button_profiles = Some(HashMap::from([(DEFAULT_PROFILE.to_string(), maps)]));
    if cfg.active_profile.is_none() {
        cfg.active_profile = Some(DEFAULT_PROFILE.to_string());
    }
}

pub fn switch_profile(path: &Path, name: &str) -> Result<(), ConfigError> {
    let mut cfg = load_config_for_write(path)?;
    migrate_to_profiles(&mut cfg);
    let known = cfg
        .button_profiles
        .as_ref()
        .is_some_and(|p| p.contains_key(name));
    if !known {
        return Err(ConfigError::ProfileNotFound(name.to_string())); // 不碰檔案
    }
    cfg.active_profile = Some(name.to_string());
    save_config(path, &cfg)
}

/// 「一次充放電只提醒一次」的閂鎖——與 Swift 的 LowBatteryLatch 同一個狀態機：
/// 充電重置、門檻改變重新武裝、關掉再開重新武裝。
#[derive(Debug, Default)]
pub struct LowBatteryLatch {
    fired: bool,
    last_limit: Option<i64>,
}

impl LowBatteryLatch {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn should_fire(&mut self, percent: i64, charging: bool, limit: Option<i64>) -> bool {
        let Some(limit) = limit else {
            self.fired = false; // 通知關閉
            return false;
        };
        if self.last_limit != Some(limit) {
            self.fired = false; // 門檻剛被調過：這一輪放電就要按新值生效，不是等下一輪
            self.last_limit = Some(limit);
        }
        if charging || percent > limit {
            self.fired = false;
            return false;
        }
        if self.fired {
            return false;
        }
        self.fired = true;
        true
    }
}

// 閂鎖是 fixtures 蓋不到的純狀態機（向量是一問一答，閂鎖是跨次呼叫的記憶）——
// 用單元測試釘住與 Swift 版相同的四條規則。
#[cfg(test)]
mod latch_tests {
    use super::LowBatteryLatch;

    #[test]
    fn fires_once_per_discharge_cycle() {
        let mut l = LowBatteryLatch::new();
        assert!(l.should_fire(10, false, Some(15)));
        assert!(!l.should_fire(9, false, Some(15)));
        assert!(!l.should_fire(80, true, Some(15))); // 充電中不響
        assert!(l.should_fire(10, false, Some(15))); // 充電過後重新武裝
    }

    #[test]
    fn raised_threshold_takes_effect_this_cycle() {
        let mut l = LowBatteryLatch::new();
        assert!(l.should_fire(10, false, Some(15)));
        assert!(l.should_fire(25, false, Some(30))); // 15 → 30 而電量已 25%：這一輪就要響
        assert!(!l.should_fire(24, false, Some(30)));
    }

    #[test]
    fn disabling_and_reenabling_rearms() {
        let mut l = LowBatteryLatch::new();
        assert!(l.should_fire(10, false, Some(15)));
        assert!(!l.should_fire(10, false, None)); // 關閉時永不響
        assert!(l.should_fire(10, false, Some(15)));
    }

    #[test]
    fn boundary_fires_and_above_stays_quiet() {
        let mut fresh = LowBatteryLatch::new();
        assert!(!fresh.should_fire(16, false, Some(15))); // 全新閂鎖：門檻之上永不響
        assert!(fresh.should_fire(15, false, Some(15))); // 邊界本身要響
    }
}

#[cfg(all(test, unix))]
mod symlink_tests {
    use super::*;

    // dotfiles 使用者的規則：寫入要穿過 symlink，不能把連結換成普通檔案。
    // macOS v1.7.1 的回歸正是這一條；Windows 上建 symlink 需要特權，所以 unix-only
    // （CI 的 ubuntu/macos job 會跑到；語意本身平台無關）。
    #[test]
    fn save_writes_through_a_symlink() {
        let dir = std::env::temp_dir().join(format!("nibble-symlink-rs-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let real = dir.join("real.json");
        let link = dir.join("link.json");
        save_config(
            &real,
            &BMConfig {
                dpi: Some(800),
                ..Default::default()
            },
        )
        .unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();

        update_low_battery_notify(&link, true, 30).unwrap();

        let meta = fs::symlink_metadata(&link).unwrap();
        assert!(
            meta.file_type().is_symlink(),
            "the symlink survives the write"
        );
        let behind = load_config(&real).expect("real file parses");
        assert_eq!(
            behind.low_battery_percent,
            Some(30),
            "the real file received the write"
        );
        assert_eq!(
            behind.dpi,
            Some(800),
            "without losing what was already there"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
