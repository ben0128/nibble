// tray_lock.rs — 單一實例＋跨程序存活探測（macOS flock 的 Windows 對應物：named mutex）。
// Local\ 命名空間＝per-session，托盤本來就是 session 級的東西。
use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HANDLE};
use windows_sys::Win32::System::Threading::{CreateMutexW, OpenMutexW};

const SYNCHRONIZE: u32 = 0x0010_0000; // generic access right（windows-sys 放在別的 feature，值是穩定的 Win32 常數）

const NAME: &[u16] = &[
    // "Local\\nibble-tray" 的 UTF-16（手寫避免 build script）
    76, 111, 99, 97, 108, 92, 110, 105, 98, 98, 108, 101, 45, 116, 114, 97, 121, 0,
];

/// 托盤啟動時取得；拿不到代表已經有一個在跑。握著 handle 直到程序結束（不 Close）。
pub struct TrayLock(#[allow(dead_code)] HANDLE);

// SAFETY: mutex handle 只在本程序內持有到結束，Win32 handle 可跨執行緒使用
unsafe impl Send for TrayLock {}

pub fn acquire() -> Option<TrayLock> {
    unsafe {
        let h = CreateMutexW(std::ptr::null(), 0, NAME.as_ptr());
        if h.is_null() {
            return None; // 建不出 mutex——寧可不擋（macOS acquireMenuBarLock 的同一個偏向）
        }
        if GetLastError() == ERROR_ALREADY_EXISTS {
            CloseHandle(h);
            return None;
        }
        Some(TrayLock(h))
    }
}

/// 別的程序（CLI 的 doctor）問「托盤活著沒」。
/// 只有「開得到那顆 mutex」能證明有人握著——與 macOS menuBarRunning 的誠實原則一致。
pub fn tray_running() -> bool {
    unsafe {
        let h = OpenMutexW(SYNCHRONIZE, 0, NAME.as_ptr());
        if h.is_null() {
            return false;
        }
        CloseHandle(h);
        true
    }
}
