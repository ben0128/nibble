// m0-probe — Windows HID++ 管線驗證（拋棄式；不進 nibble-win，學到的東西才進）。
//
// 要回答的三個問題：
//   1. USB passthrough 之下，接收器的 vendor collection（usage page 0xFF00）開不開得起來？
//   2. 送 short 0x10 ping，回應會回到哪個介面？（macOS 一個 IOHIDDevice 蓋整頁；
//      Windows 每個 top-level collection 是獨立介面——short/long 很可能是兩個 handle，
//      回應若以 long 0x11 到達，會落在另一個介面上。這個觀察決定 M2 的 transport 形狀。）
//   3. 連續 20 次 ping 是否全數有回應、電池電壓是否落在 3300–4300 mV？——GO/NO-GO。
//
// 執行（VM 內）：cargo run --release -p m0-probe
// 退出碼：0 = GO、1 = NO-GO、2 = 環境問題（沒找到裝置／開不起來）。

#[cfg(not(windows))]
fn main() {
    eprintln!("m0-probe only means anything on Windows.");
    eprintln!("(macOS 上只用 cargo check --target x86_64-pc-windows-msvc 驗型別)");
    std::process::exit(2);
}

#[cfg(windows)]
fn main() {
    std::process::exit(probe::run());
}

#[cfg(windows)]
mod probe {
    use std::mem::{size_of, zeroed};
    use windows_sys::Win32::Devices::DeviceAndDriverInstallation::{
        SetupDiDestroyDeviceInfoList, SetupDiEnumDeviceInterfaces, SetupDiGetClassDevsW,
        SetupDiGetDeviceInterfaceDetailW, DIGCF_DEVICEINTERFACE, DIGCF_PRESENT,
        SP_DEVICE_INTERFACE_DATA, SP_DEVICE_INTERFACE_DETAIL_DATA_W,
    };
    use windows_sys::Win32::Devices::HumanInterfaceDevice::{
        HidD_FreePreparsedData, HidD_GetAttributes, HidD_GetPreparsedData, HidP_GetCaps,
        GUID_DEVINTERFACE_HID, HIDD_ATTRIBUTES, HIDP_CAPS, HIDP_STATUS_SUCCESS,
    };
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_IO_PENDING, FALSE, GENERIC_READ, GENERIC_WRITE, HANDLE,
        INVALID_HANDLE_VALUE, WAIT_OBJECT_0, WAIT_TIMEOUT,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, ReadFile, WriteFile, FILE_FLAG_OVERLAPPED, FILE_SHARE_READ, FILE_SHARE_WRITE,
        OPEN_EXISTING,
    };
    use windows_sys::Win32::System::Threading::{CreateEventW, WaitForMultipleObjects};
    use windows_sys::Win32::System::IO::{GetOverlappedResult, OVERLAPPED};

    const VENDOR_LOGITECH: u16 = 0x046D;
    const SWID: u8 = 0x0A; // 探針是單一程序，寫死即可（正式版是 pid 衍生）
    const PING_ROUNDS: u32 = 20;
    const MV_RANGE: std::ops::RangeInclusive<u16> = 3300..=4300;

    /// 一個開起來的 HID++ collection：short 與 long 在 Windows 上常是兩個獨立介面，
    /// 全部一起監聽——回應到哪裡是 M0 要回答的問題，不是要假設的前提。
    struct Iface {
        handle: HANDLE,
        event: HANDLE,
        overlapped: Box<OVERLAPPED>,
        buf: Vec<u8>,
        usage_page: u16,
        usage: u16,
        out_len: u16,
        in_len: u16,
        replies_seen: u32,
    }

    impl Iface {
        /// 掛一筆 overlapped 讀（常駐；完成後要重掛）
        unsafe fn arm_read(&mut self) {
            self.overlapped.hEvent = self.event;
            let ok = ReadFile(
                self.handle,
                self.buf.as_mut_ptr(),
                self.buf.len() as u32,
                std::ptr::null_mut(),
                &mut *self.overlapped,
            );
            if ok == FALSE && GetLastError() != ERROR_IO_PENDING {
                eprintln!(
                    "  (read arm failed on usage 0x{:04X}: {})",
                    self.usage,
                    GetLastError()
                );
            }
        }
    }

    pub fn run() -> i32 {
        println!("m0-probe — HID++ over Windows HID, passthrough verification");
        println!("============================================================");

        let mut ifaces = unsafe { open_logitech_hidpp_interfaces() };
        if ifaces.is_empty() {
            println!("NO-GO(env): no Logitech HID++ collection opened.");
            println!(
                "  → 檢查 VM 是否真的拿到接收器（裝置管理員應出現 Logitech USB Input Device），"
            );
            println!("    以及 G HUB / OMM 沒有在 VM 裡同時抓著裝置。");
            return 2;
        }
        for f in &ifaces {
            println!(
                "  opened: usage_page=0x{:04X} usage=0x{:04X} out_len={} in_len={}",
                f.usage_page, f.usage, f.out_len, f.in_len
            );
        }

        // 寫入走哪個介面：優先 short（out_len 7），沒有就用 long（BLE 直連的形狀）
        let writer = match ifaces
            .iter()
            .position(|f| f.out_len as usize >= 7 && f.out_len < 20)
            .or_else(|| ifaces.iter().position(|f| f.out_len as usize >= 20))
        {
            Some(i) => i,
            None => {
                println!("NO-GO(env): no writable collection (out_len 7/20) — topology surprise, record it.");
                return 2;
            }
        };
        let long_writer = ifaces[writer].out_len as usize >= 20;
        println!(
            "  writer: usage 0x{:04X} ({})",
            ifaces[writer].usage,
            if long_writer {
                "long 0x11"
            } else {
                "short 0x10"
            }
        );

        unsafe {
            for f in ifaces.iter_mut() {
                f.arm_read();
            }
        }

        // ── 1. 找醒著的裝置：接收器下掛 1–6，全空補問直連 0xFF ──────────────
        let mut awake: Option<u8> = None;
        for idx in [1u8, 2, 3, 4, 5, 6, 0xFF] {
            if let Some(reply) = unsafe { ping(&mut ifaces, writer, long_writer, idx, 800) } {
                match reply {
                    PingReply::Version(maj, min) => {
                        println!("  device #{idx}: HID++ {maj}.{min} — awake");
                        awake = Some(idx);
                        break;
                    }
                    PingReply::Error(code) => {
                        // 0x08/0x09 = 空槽或睡眠——接收器有回話，管線本身是通的
                        println!(
                            "  device #{idx}: receiver error 0x{code:02X} (slot empty/asleep)"
                        );
                    }
                }
            } else {
                println!("  device #{idx}: no reply");
            }
        }
        let Some(idx) = awake else {
            println!("NO-GO: receiver reachable but no awake device — move the mouse and rerun.");
            return 1;
        };

        // ── 2. 20 連發 ping：GO 判準第一條 ─────────────────────────────────
        let mut ok_pings = 0u32;
        for round in 1..=PING_ROUNDS {
            if matches!(
                unsafe { ping(&mut ifaces, writer, long_writer, idx, 500) },
                Some(PingReply::Version(..))
            ) {
                ok_pings += 1;
            } else {
                println!("  ping {round}/{PING_ROUNDS}: MISS");
            }
        }
        println!("  pings: {ok_pings}/{PING_ROUNDS}");

        // ── 3. 電池（0x1001 BatteryVoltage）：GO 判準第二條 ──────────────────
        let mv = unsafe { battery_mv(&mut ifaces, writer, long_writer, idx) };
        match mv {
            Some(mv) => println!(
                "  battery: {mv} mV ({})",
                if MV_RANGE.contains(&mv) {
                    "in range"
                } else {
                    "OUT OF RANGE"
                }
            ),
            None => println!("  battery: no reading"),
        }

        // ── 拓撲觀察：M2 transport 的設計輸入 ────────────────────────────────
        println!("  reply topology:");
        for f in &ifaces {
            println!(
                "    usage 0x{:04X}: {} replies landed here",
                f.usage, f.replies_seen
            );
        }

        let go = ok_pings == PING_ROUNDS && mv.is_some_and(|v| MV_RANGE.contains(&v));
        println!("============================================================");
        println!(
            "{}",
            if go {
                "GO — proceed to M2"
            } else {
                "NO-GO — record what you saw above in the spec §8 risk table"
            }
        );

        unsafe {
            for f in &ifaces {
                CloseHandle(f.event);
                CloseHandle(f.handle);
            }
        }
        if go {
            0
        } else {
            1
        }
    }

    enum PingReply {
        Version(u8, u8),
        Error(u8),
    }

    /// 送一次 HID++ ping（IRoot fn1），在「所有」介面上等回應——回應常落在別的 collection。
    unsafe fn ping(
        ifaces: &mut [Iface],
        writer: usize,
        long: bool,
        idx: u8,
        timeout_ms: u32,
    ) -> Option<PingReply> {
        let fnsw = (1u8 << 4) | SWID;
        send(ifaces, writer, long, &[idx, 0x00, fnsw, 0x00, 0x00, 0xAA])?;
        wait_reply(ifaces, timeout_ms, |p| {
            if p.len() < 5 || p[0] != idx {
                return None;
            }
            if p[1] == 0x00 && p[2] == fnsw {
                return Some(PingReply::Version(p[3], p[4]));
            }
            if p[1] == 0x8F && p[2] == 0x00 && p[3] == fnsw {
                return Some(PingReply::Error(p[4]));
            }
            None
        })
    }

    /// getFeature(0x1001) → 讀電壓。任何一步沒回應就回 None。
    unsafe fn battery_mv(ifaces: &mut [Iface], writer: usize, long: bool, idx: u8) -> Option<u16> {
        let fnsw0 = SWID; // fn 0
        send(ifaces, writer, long, &[idx, 0x00, fnsw0, 0x10, 0x01])?;
        let fi = wait_reply(ifaces, 800, |p| {
            (p.len() >= 4 && p[0] == idx && p[1] == 0x00 && p[2] == fnsw0).then(|| p[3])
        })?;
        if fi == 0 {
            println!("  battery: device reports no 0x1001 (not a G-series?)");
            return None;
        }
        send(ifaces, writer, long, &[idx, fi, fnsw0])?;
        wait_reply(ifaces, 800, |p| {
            (p.len() >= 5 && p[0] == idx && p[1] == fi && p[2] == fnsw0)
                .then(|| (u16::from(p[3]) << 8) | u16::from(p[4]))
        })
    }

    /// 組出正確長度的 report 寫下去。M0 的第一課直接繼承 macOS：buffer 含 report-ID byte，
    /// 而且在 Windows 上必須「剛好」是該 collection 的 OutputReportByteLength。
    unsafe fn send(ifaces: &mut [Iface], writer: usize, long: bool, payload: &[u8]) -> Option<()> {
        let f = &mut ifaces[writer];
        let (id, want) = if long {
            (0x11u8, 20usize)
        } else {
            (0x10u8, 7usize)
        };
        let mut buf = vec![0u8; f.out_len as usize];
        buf[0] = id;
        buf[1..1 + payload.len()].copy_from_slice(payload);
        debug_assert!(payload.len() < want);

        let mut ov: OVERLAPPED = zeroed();
        let ev = CreateEventW(std::ptr::null(), 1, 0, std::ptr::null());
        ov.hEvent = ev;
        let ok = WriteFile(
            f.handle,
            buf.as_ptr(),
            buf.len() as u32,
            std::ptr::null_mut(),
            &mut ov,
        );
        let done = if ok == FALSE {
            if GetLastError() != ERROR_IO_PENDING {
                eprintln!("  write failed: {}", GetLastError());
                CloseHandle(ev);
                return None;
            }
            let mut written = 0u32;
            GetOverlappedResult(f.handle, &ov, &mut written, 1) != FALSE
        } else {
            true
        };
        CloseHandle(ev);
        done.then_some(())
    }

    /// 同時等所有介面的 pending read；一有完成就解析、重掛，直到 decode 認得或超時。
    unsafe fn wait_reply<T>(
        ifaces: &mut [Iface],
        timeout_ms: u32,
        decode: impl Fn(&[u8]) -> Option<T>,
    ) -> Option<T> {
        let deadline =
            std::time::Instant::now() + std::time::Duration::from_millis(u64::from(timeout_ms));
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return None;
            }
            let events: Vec<HANDLE> = ifaces.iter().map(|f| f.event).collect();
            let w = WaitForMultipleObjects(
                events.len() as u32,
                events.as_ptr(),
                FALSE,
                remaining.as_millis() as u32,
            );
            if w == WAIT_TIMEOUT {
                return None;
            }
            let i = (w - WAIT_OBJECT_0) as usize;
            if i >= ifaces.len() {
                return None; // WAIT_FAILED 等等——放棄這一輪
            }
            let mut n = 0u32;
            let got =
                GetOverlappedResult(ifaces[i].handle, &*ifaces[i].overlapped, &mut n, 0) != FALSE;
            let mut decoded = None;
            if got && n > 0 {
                ifaces[i].replies_seen += 1;
                let raw = &ifaces[i].buf[..n as usize];
                // 第一個 byte 是 report id（0x10/0x11）——剝掉再交給協定層視角的 decode
                let body = if raw.first().is_some_and(|&b| b == 0x10 || b == 0x11) {
                    &raw[1..]
                } else {
                    raw
                };
                decoded = decode(body);
            }
            ifaces[i].arm_read();
            if decoded.is_some() {
                return decoded;
            }
        }
    }

    /// SetupDi 列舉 → CreateFile → HidD 過濾：VID 046D、usage page 0xFF00/0xFF43
    unsafe fn open_logitech_hidpp_interfaces() -> Vec<Iface> {
        let mut out = Vec::new();
        let devs = SetupDiGetClassDevsW(
            &GUID_DEVINTERFACE_HID,
            std::ptr::null(),
            std::ptr::null_mut(),
            DIGCF_PRESENT | DIGCF_DEVICEINTERFACE,
        );
        if devs == -1 {
            // HDEVINFO 是 isize，INVALID_HANDLE_VALUE 的值就是 -1
            return out;
        }

        let mut index = 0u32;
        loop {
            let mut ifdata: SP_DEVICE_INTERFACE_DATA = zeroed();
            ifdata.cbSize = size_of::<SP_DEVICE_INTERFACE_DATA>() as u32;
            if SetupDiEnumDeviceInterfaces(
                devs,
                std::ptr::null(),
                &GUID_DEVINTERFACE_HID,
                index,
                &mut ifdata,
            ) == FALSE
            {
                break;
            }
            index += 1;

            // 兩段式取 device path
            let mut required = 0u32;
            SetupDiGetDeviceInterfaceDetailW(
                devs,
                &ifdata,
                std::ptr::null_mut(),
                0,
                &mut required,
                std::ptr::null_mut(),
            );
            if required == 0 {
                continue;
            }
            let mut detail = vec![0u8; required as usize];
            let header = detail.as_mut_ptr() as *mut SP_DEVICE_INTERFACE_DETAIL_DATA_W;
            (*header).cbSize = size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() as u32;
            if SetupDiGetDeviceInterfaceDetailW(
                devs,
                &ifdata,
                header,
                required,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            ) == FALSE
            {
                continue;
            }
            let path = std::ptr::addr_of!((*header).DevicePath) as *const u16;

            let handle = CreateFileW(
                path,
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED,
                std::ptr::null_mut(),
            );
            if handle == INVALID_HANDLE_VALUE {
                continue; // 鍵盤/滑鼠 TLC 系統保留開不起來——本來就不是我們要的
            }

            let mut attrs: HIDD_ATTRIBUTES = zeroed();
            attrs.Size = size_of::<HIDD_ATTRIBUTES>() as u32;
            if !HidD_GetAttributes(handle, &mut attrs) || attrs.VendorID != VENDOR_LOGITECH {
                CloseHandle(handle);
                continue;
            }

            let mut preparsed = 0isize;
            if !HidD_GetPreparsedData(handle, &mut preparsed) {
                CloseHandle(handle);
                continue;
            }
            let mut caps: HIDP_CAPS = zeroed();
            let status = HidP_GetCaps(preparsed, &mut caps);
            HidD_FreePreparsedData(preparsed);
            if status != HIDP_STATUS_SUCCESS
                || !(caps.UsagePage == 0xFF00 || caps.UsagePage == 0xFF43)
            {
                CloseHandle(handle);
                continue;
            }

            let event = CreateEventW(std::ptr::null(), 1, 0, std::ptr::null());
            let in_len = caps.InputReportByteLength.max(1);
            out.push(Iface {
                handle,
                event,
                overlapped: Box::new(zeroed()),
                buf: vec![0u8; in_len as usize],
                usage_page: caps.UsagePage,
                usage: caps.Usage,
                out_len: caps.OutputReportByteLength,
                in_len,
                replies_seen: 0,
            });
        }
        SetupDiDestroyDeviceInfoList(devs);
        out
    }
}
