// nibble-core — HID++ 協定與設定檔語意的 Rust 實作（平台中立，零 Win32 依賴）。
//
// 這是設計文件（docs/superpowers/specs/2026-07-27-windows-port-design.md）選項 (A) 的
// 那份「第二實作」：Swift 版完全不動，兩邊的一致性由 docs/fixtures/*.json 裁定——
// 同一組 bytes、同一組期望值，各自重播。改了這裡忘了改向量（或反過來），測試會爆。
//
// M1 範圍 = fixtures 蓋到的部分：framing、錯誤解碼、feature 快取、電池三段 fallback、
// DPI 讀取、設定檔合併語意。rate / rgb / set_dpi 等其餘指令面屬於 M2（transport + CLI），
// 到時對著 Swift 原檔逐 byte 移植並補向量——不先寫沒有裁判的程式碼。
pub mod config;
pub mod hidpp;

pub use hidpp::{Battery, Device, Error, Transport};
