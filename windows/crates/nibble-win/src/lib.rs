// nibble-win — Windows 平台層。協定知識一律在 nibble-core；這裡只有 OS。
//
// 非 Windows 平台上這個 crate 幾乎是空的（transport 等模組整個 cfg(windows)），
// 但 crate 本身要能編譯——workspace 的 cargo test 在 mac/linux 也會跑到它。
pub const WIN_VERSION: &str = "0.1.0-dev";

/// 與 macOS 相同的 per-process software ID：pid % 15 + 1（0 保留）。
/// 兩個 Nibble 程序同時開著裝置時，各自只認自己的回應——macOS v1.3.0 的教訓。
pub fn software_id() -> u8 {
    (std::process::id() % 15) as u8 + 1
}

/// 設定檔路徑：NIBBLE_CONFIG 覆寫（測試與 CI 靠它），否則 %APPDATA%\nibble\nibble.json。
/// schema 與 macOS 同一份——profiles 可以跨平台帶著走。
pub fn config_path() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("NIBBLE_CONFIG") {
        if !p.is_empty() {
            return p.into();
        }
    }
    let base = std::env::var("APPDATA").unwrap_or_else(|_| ".".into());
    std::path::Path::new(&base)
        .join("nibble")
        .join("nibble.json")
}

#[cfg(windows)]
pub mod transport;

#[cfg(windows)]
pub mod tray_lock;
