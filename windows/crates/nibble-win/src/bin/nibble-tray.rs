// nibble-tray.rs — 通知區常駐（windows subsystem：雙擊啟動不閃黑窗）。
// v1.0 範圍（設計 §3.2）：電量 tooltip + 選單（DPI 級距／回報率／燈效／Quit）。
// 不做設定檔監看、不做改鍵——那是 v1.x 引擎的事，架構位置已留（transport 的 on_report）。
//
// 操作模型：每次動作「開 transport → 做 → 關」——零常駐 HID handle，
// 接收器重插不需要任何重連邏輯。選單開啟時現讀現值打勾。
#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(not(windows))]
fn main() {
    eprintln!("nibble-tray.exe is Windows-only.");
    std::process::exit(2);
}

#[cfg(windows)]
fn main() {
    tray::run();
}

#[cfg(windows)]
mod tray {
    use nibble_core::hidpp::{apply_rgb, with_host_fallback, Device, Transport};
    use nibble_win::transport::{open_all, WinTransport};
    use nibble_win::{software_id, tray_lock};
    use std::mem::{size_of, zeroed};
    use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, WPARAM};
    use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows_sys::Win32::UI::Shell::{
        Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NIM_MODIFY,
        NOTIFYICONDATAW,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu,
        DispatchMessageW, GetCursorPos, GetMessageW, LoadIconW, PostQuitMessage, RegisterClassW,
        SetForegroundWindow, SetTimer, TrackPopupMenu, HWND_MESSAGE, IDI_APPLICATION, MF_CHECKED,
        MF_DISABLED, MF_GRAYED, MF_SEPARATOR, MF_STRING, MSG, TPM_NONOTIFY, TPM_RETURNCMD,
        TPM_RIGHTBUTTON, WM_APP, WM_LBUTTONUP, WM_RBUTTONUP, WM_TIMER, WNDCLASSW,
    };

    const TRAY_CB: u32 = WM_APP + 1;
    const POLL_TIMER_ID: usize = 1;
    const POLL_MS: u32 = 300_000; // 與 macOS 選單列同一個節奏

    const DPI_PRESETS: [u16; 8] = [400, 800, 1200, 1600, 2000, 2400, 2800, 3200];
    const RATES: [u16; 4] = [1000, 500, 250, 125];
    const ID_DPI_BASE: usize = 100;
    const ID_RATE_BASE: usize = 120;
    const ID_RGB_BASE: usize = 130; // off / cycle / breathing
    const ID_REFRESH: usize = 140;
    const ID_QUIT: usize = 141;

    fn w(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    // 全部 UI 操作都在訊息迴圈那條執行緒上——thread_local 是這裡「安全的全域」
    thread_local! {
        static NID: std::cell::RefCell<Option<NOTIFYICONDATAW>> = const { std::cell::RefCell::new(None) };
    }

    pub fn run() {
        // 單一實例：第二份直接安靜退出（重複托盤圖示比黑窗更糟）
        let Some(_lock) = tray_lock::acquire() else {
            return;
        };

        unsafe {
            let instance = GetModuleHandleW(std::ptr::null());
            let class_name = w("nibble.tray");
            let mut wc: WNDCLASSW = zeroed();
            wc.hInstance = instance;
            wc.lpszClassName = class_name.as_ptr();
            wc.lpfnWndProc = Some(wndproc);
            RegisterClassW(&wc);

            // HWND_MESSAGE 子視窗：只收訊息、不可見、不進工作列——托盤要的只是一個信箱
            let hwnd = CreateWindowExW(
                0,
                class_name.as_ptr(),
                w("nibble").as_ptr(),
                0,
                0,
                0,
                0,
                0,
                HWND_MESSAGE,
                std::ptr::null_mut(),
                instance,
                std::ptr::null(),
            );

            let mut nid: NOTIFYICONDATAW = zeroed();
            nid.cbSize = size_of::<NOTIFYICONDATAW>() as u32;
            nid.hWnd = hwnd;
            nid.uID = 1;
            nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
            nid.uCallbackMessage = TRAY_CB;
            nid.hIcon = LoadIconW(std::ptr::null_mut(), IDI_APPLICATION);
            set_tip(&mut nid, "Nibble — polling…");
            Shell_NotifyIconW(NIM_ADD, &nid);
            NID.with_borrow_mut(|slot| *slot = Some(nid));

            poll_battery(); // 啟動先讀一次，不等第一個 5 分鐘
            SetTimer(hwnd, POLL_TIMER_ID, POLL_MS, None);

            let mut msg: MSG = zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) != 0 {
                DispatchMessageW(&msg);
            }

            // 不刪的話死圖示會留在托盤上，直到有人把滑鼠移過去
            NID.with_borrow(|slot| {
                if let Some(nid) = slot.as_ref() {
                    Shell_NotifyIconW(NIM_DELETE, nid);
                }
            });
        }
    }

    unsafe fn set_tip(nid: &mut NOTIFYICONDATAW, tip: &str) {
        let text = w(tip);
        let n = text.len().min(nid.szTip.len() - 1);
        nid.szTip[..n].copy_from_slice(&text[..n]);
        nid.szTip[n] = 0;
    }

    /// 每 5 分鐘＋每次動作後：讀電量進 tooltip。開不到裝置就照實說。
    unsafe fn poll_battery() {
        let tip = read_battery_tip().unwrap_or_else(|| "Nibble — mouse offline or asleep".into());
        NID.with_borrow_mut(|slot| {
            if let Some(nid) = slot.as_mut() {
                set_tip(nid, &tip);
                Shell_NotifyIconW(NIM_MODIFY, nid);
            }
        });
    }

    fn read_battery_tip() -> Option<String> {
        let mut trs = open_all().ok()?;
        for tr in trs.iter_mut() {
            if let Some((idx, _)) = first_awake(tr) {
                let mut dev = Device::new(&mut *tr, idx, software_id());
                let name = dev.name().unwrap_or_else(|_| "Logitech".into());
                let b = dev.battery().ok()?;
                return Some(format!(
                    "{name} — {}% {}",
                    b.percent,
                    if b.charging {
                        "charging"
                    } else {
                        "discharging"
                    }
                ));
            }
        }
        None
    }

    fn first_awake(tr: &mut WinTransport) -> Option<(u8, (u8, u8))> {
        let swid = software_id();
        if tr.is_direct() {
            return Device::new(&mut *tr, 0xFF, swid)
                .ping()
                .ok()
                .map(|v| (0xFF, v));
        }
        for idx in 1..=6u8 {
            if let Ok(v) = Device::new(&mut *tr, idx, swid).ping() {
                return Some((idx, v));
            }
        }
        Device::new(&mut *tr, 0xFF, swid)
            .ping()
            .ok()
            .map(|v| (0xFF, v))
    }

    /// 選單：開啟當下現讀現值（title 列 + 打勾），關掉選單就沒有任何殘留狀態
    unsafe fn show_menu(hwnd: HWND) {
        let menu = CreatePopupMenu();

        let state = read_menu_state();
        match &state {
            Some((title, dpi, rate)) => {
                AppendMenuW(
                    menu,
                    MF_STRING | MF_GRAYED | MF_DISABLED,
                    0,
                    w(title).as_ptr(),
                );
                AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
                for (i, v) in DPI_PRESETS.iter().enumerate() {
                    let checked = if Some(*v) == *dpi { MF_CHECKED } else { 0 };
                    AppendMenuW(
                        menu,
                        MF_STRING | checked,
                        ID_DPI_BASE + i,
                        w(&format!("DPI {v}")).as_ptr(),
                    );
                }
                AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
                for (i, v) in RATES.iter().enumerate() {
                    let checked = if Some(*v) == *rate { MF_CHECKED } else { 0 };
                    AppendMenuW(
                        menu,
                        MF_STRING | checked,
                        ID_RATE_BASE + i,
                        w(&format!("{v} Hz")).as_ptr(),
                    );
                }
                AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
                for (i, name) in ["Lighting off", "Lighting cycle", "Lighting breathing"]
                    .iter()
                    .enumerate()
                {
                    AppendMenuW(menu, MF_STRING, ID_RGB_BASE + i, w(name).as_ptr());
                }
            }
            None => {
                AppendMenuW(
                    menu,
                    MF_STRING | MF_GRAYED | MF_DISABLED,
                    0,
                    w("Mouse offline or asleep — move it").as_ptr(),
                );
            }
        }
        AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
        AppendMenuW(menu, MF_STRING, ID_REFRESH, w("Refresh now").as_ptr());
        AppendMenuW(
            menu,
            MF_STRING,
            ID_QUIT,
            w("Quit (mouse keeps working)").as_ptr(),
        );

        let mut pt: POINT = zeroed();
        GetCursorPos(&mut pt);
        SetForegroundWindow(hwnd); // 少了這行，選單點外面關不掉——經典 Win32 陷阱
        let cmd = TrackPopupMenu(
            menu,
            TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY,
            pt.x,
            pt.y,
            0,
            hwnd,
            std::ptr::null(),
        );
        DestroyMenu(menu);
        dispatch(cmd as usize);
    }

    fn read_menu_state() -> Option<(String, Option<u16>, Option<u16>)> {
        let mut trs = open_all().ok()?;
        for tr in trs.iter_mut() {
            if let Some((idx, _)) = first_awake(tr) {
                let mut dev = Device::new(&mut *tr, idx, software_id());
                let name = dev.name().unwrap_or_else(|_| "Logitech".into());
                let battery = dev.battery().ok();
                let title = match battery {
                    Some(b) => format!(
                        "{name} — {}% {}",
                        b.percent,
                        if b.charging {
                            "charging"
                        } else {
                            "discharging"
                        }
                    ),
                    None => name,
                };
                return Some((title, dev.current_dpi().ok(), dev.report_rate_hz().ok()));
            }
        }
        None
    }

    unsafe fn dispatch(cmd: usize) {
        match cmd {
            0 => {}
            ID_QUIT => PostQuitMessage(0),
            ID_REFRESH => poll_battery(),
            c if (ID_DPI_BASE..ID_DPI_BASE + DPI_PRESETS.len()).contains(&c) => {
                act(|dev| {
                    let _ = dev.set_dpi(DPI_PRESETS[c - ID_DPI_BASE]);
                });
            }
            c if (ID_RATE_BASE..ID_RATE_BASE + RATES.len()).contains(&c) => {
                act(|dev| {
                    let _ =
                        with_host_fallback(dev, |d| d.set_report_rate_hz(RATES[c - ID_RATE_BASE]));
                });
            }
            c if (ID_RGB_BASE..ID_RGB_BASE + 3).contains(&c) => {
                let kind = ["off", "cycle", "breathing"][c - ID_RGB_BASE];
                act(|dev| {
                    let _ = apply_rgb(dev, kind);
                });
            }
            _ => {}
        }
    }

    /// 開 → 做 → 關，動作完順手更新 tooltip
    unsafe fn act(f: impl Fn(&mut Device<&mut WinTransport>)) {
        if let Ok(mut trs) = open_all() {
            for tr in trs.iter_mut() {
                if let Some((idx, _)) = first_awake(tr) {
                    let mut dev = Device::new(&mut *tr, idx, software_id());
                    f(&mut dev);
                    break;
                }
            }
        }
        poll_battery();
    }

    unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
        match msg {
            TRAY_CB => {
                let event = lp as u32;
                if event == WM_RBUTTONUP || event == WM_LBUTTONUP {
                    show_menu(hwnd);
                }
                0
            }
            WM_TIMER => {
                poll_battery();
                0
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}
