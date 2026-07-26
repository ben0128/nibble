// transport.rs — Windows HID transport（正式版；唯一碰 SetupDi/HidD 的檔案）。
//
// 拓撲事實（M0 探針的存在理由）：Windows 上每個 HID top-level collection 是一個
// 獨立的 device interface——接收器的 short(0x10) 與 long(0x11) collection 是兩個
// handle。macOS 的教訓是「送 short、回應常以 long 回來」，所以：
//   一個 WinTransport = 同一實體單位的一組 collection。
//   寫入：依報文長度挑 short/long 的 handle（short 缺席就升級成 long——BLE 的形狀）。
//   讀取：所有 handle 各掛一條讀執行緒，全部餵進同一個 channel。
//
// 分組用 device path 的 "&col" 前綴（vid+pid+mi）。已知限制：兩顆一模一樣的
// 接收器同時插上會被併成一組——macOS 版靠 IOKit 的裝置身分沒這個問題；
// 等真的有人踩到再用 ContainerId 分（需要多一組 DEVPKEY API）。
use nibble_core::hidpp::{Error, Transport};
use std::collections::{HashMap, VecDeque};
use std::mem::{size_of, zeroed};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
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
    INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, ReadFile, WriteFile, FILE_FLAG_OVERLAPPED, FILE_SHARE_READ, FILE_SHARE_WRITE,
    OPEN_EXISTING,
};
use windows_sys::Win32::System::Threading::CreateEventW;
use windows_sys::Win32::System::IO::{GetOverlappedResult, OVERLAPPED};

const VENDOR_LOGITECH: u16 = 0x046D;
const SHORT_ID: u8 = 0x10;
const LONG_ID: u8 = 0x11;

pub type ReportCallback = Box<dyn Fn(&[u8]) + Send>;
type OnReport = Arc<Mutex<Option<ReportCallback>>>;

struct Pipe {
    handle: usize, // HANDLE 是裸指標、not Send——以 usize 攜帶，用時轉回
    out_len: u16,
}

pub struct WinTransport {
    short_w: Option<Pipe>,
    long_w: Option<Pipe>,
    all_handles: Vec<usize>,
    rx: Receiver<Vec<u8>>,
    /// round_trip 期間收到但比對不上的報文（別的 swid、裝置通知）——留給下一輪先掃
    pending: VecDeque<Vec<u8>>,
    pub usage_page: u16,
    product: u16,
    on_report: OnReport,
}

// SAFETY: handles 只以 usize 儲存；所有 Win32 呼叫都以值傳遞 HANDLE。
unsafe impl Send for WinTransport {}

impl WinTransport {
    /// 事件旁聽（v1.x 改鍵引擎的入口；v1.0 沒人掛）
    pub fn set_on_report(&self, cb: Option<ReportCallback>) {
        *self.on_report.lock().unwrap() = cb;
    }
}

impl Transport for WinTransport {
    fn is_direct(&self) -> bool {
        self.usage_page == 0xFF43
    }
    fn long_only(&self) -> bool {
        self.short_w.is_none()
    }
    fn product_id(&self) -> u16 {
        self.product
    }

    fn round_trip(
        &mut self,
        request: &[u8],
        prefer_long: bool,
        timeout: Duration,
        matcher: &dyn Fn(&[u8]) -> bool,
    ) -> Result<Vec<u8>, Error> {
        // 上一輪留下的未匹配報文先掃一遍
        if let Some(i) = self.pending.iter().position(|p| matcher(p)) {
            return Ok(self.pending.remove(i).unwrap());
        }

        let long = prefer_long || self.long_only();
        let pipe = if long {
            self.long_w.as_ref()
        } else {
            self.short_w.as_ref()
        };
        let Some(pipe) = pipe else {
            return Err(Error::Transport(
                "this collection set has no pipe of the required length".into(),
            ));
        };
        let id = if long { LONG_ID } else { SHORT_ID };

        // macOS M0 的第一課，Windows 同款：buffer 含 report-ID byte，
        // 且長度必須「剛好」是該 collection 的 OutputReportByteLength
        let mut buf = vec![0u8; pipe.out_len as usize];
        if request.len() + 1 > buf.len() {
            return Err(Error::Transport(format!(
                "request of {} bytes does not fit the {}-byte pipe",
                request.len() + 1,
                pipe.out_len
            )));
        }
        buf[0] = id;
        buf[1..=request.len()].copy_from_slice(request);
        unsafe { overlapped_write(pipe.handle as HANDLE, &buf)? };

        let deadline = Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(Error::Timeout);
            }
            match self.rx.recv_timeout(remaining) {
                Ok(report) => {
                    if matcher(&report) {
                        return Ok(report);
                    }
                    if self.pending.len() >= 100 {
                        self.pending.pop_front(); // 通知洪水保險——與 macOS inbox 同一個上限
                    }
                    self.pending.push_back(report);
                }
                Err(_) => return Err(Error::Timeout),
            }
        }
    }
}

impl Drop for WinTransport {
    fn drop(&mut self) {
        // 關 handle 會讓讀執行緒的 pending read 以錯誤完成 → 執行緒自行退出
        for &h in &self.all_handles {
            unsafe { CloseHandle(h as HANDLE) };
        }
    }
}

/// 平台入口（對應 macOS 的 openHIDPPTransports）：接收器排前面
pub fn open_all() -> Result<Vec<WinTransport>, Error> {
    let ifaces = unsafe { enumerate_hidpp_interfaces() };
    if ifaces.is_empty() {
        return Err(Error::Transport(
            "no Logitech device found — plug in the USB receiver or connect the mouse over Bluetooth".into(),
        ));
    }

    // 以 path 的 "&col" 前綴分組：同一實體單位的 short/long collection 併成一個 transport
    let mut groups: HashMap<String, Vec<RawIface>> = HashMap::new();
    for f in ifaces {
        let key = match f.path.find("&col") {
            Some(i) => f.path[..i].to_string(),
            None => f.path.clone(),
        };
        groups.entry(key).or_default().push(f);
    }

    let mut out = Vec::new();
    for (_, members) in groups {
        let (tx, rx) = channel::<Vec<u8>>();
        let on_report: OnReport = Arc::new(Mutex::new(None));
        let mut t = WinTransport {
            short_w: None,
            long_w: None,
            all_handles: Vec::new(),
            rx,
            pending: VecDeque::new(),
            usage_page: members[0].usage_page,
            product: members[0].product,
            on_report,
        };
        for m in members {
            t.all_handles.push(m.handle);
            if (7..20).contains(&m.out_len) && t.short_w.is_none() {
                t.short_w = Some(Pipe {
                    handle: m.handle,
                    out_len: m.out_len,
                });
            } else if m.out_len >= 20 && t.long_w.is_none() {
                t.long_w = Some(Pipe {
                    handle: m.handle,
                    out_len: m.out_len,
                });
            }
            spawn_reader(m.handle, m.in_len, tx.clone(), t.on_report.clone());
        }
        if t.short_w.is_some() || t.long_w.is_some() {
            out.push(t);
        }
        // 只有讀不了寫的組（滑鼠/鍵盤 TLC 已在列舉時被排除）直接 Drop——handle 隨之關閉
    }
    if out.is_empty() {
        return Err(Error::Transport(
            "Logitech collections found but none is writable — is another tool holding the device?"
                .into(),
        ));
    }
    out.sort_by_key(|t| t.is_direct()); // 接收器優先，與 macOS 相同
    Ok(out)
}

struct RawIface {
    path: String,
    handle: usize,
    usage_page: u16,
    product: u16,
    out_len: u16,
    in_len: u16,
}

/// 每個 collection 一條讀執行緒：overlapped read → 剝 report-ID → on_report → channel。
/// handle 被 Drop 關閉時 read 以錯誤完成，執行緒退出。
fn spawn_reader(handle: usize, in_len: u16, tx: Sender<Vec<u8>>, cb: OnReport) {
    std::thread::spawn(move || {
        let h = handle as HANDLE;
        let mut buf = vec![0u8; in_len.max(1) as usize];
        loop {
            let n = match unsafe { overlapped_read(h, &mut buf) } {
                Some(n) if n > 0 => n,
                Some(_) => continue,
                None => break,
            };
            let raw = &buf[..n];
            let body: Vec<u8> = if matches!(raw.first(), Some(&SHORT_ID) | Some(&LONG_ID)) {
                raw[1..].to_vec()
            } else {
                raw.to_vec()
            };
            if let Some(f) = cb.lock().unwrap().as_ref() {
                f(&body);
            }
            if tx.send(body).is_err() {
                break; // transport 沒了
            }
        }
    });
}

unsafe fn overlapped_write(h: HANDLE, buf: &[u8]) -> Result<(), Error> {
    let mut ov: OVERLAPPED = zeroed();
    let ev = CreateEventW(std::ptr::null(), 1, 0, std::ptr::null());
    ov.hEvent = ev;
    let ok = WriteFile(
        h,
        buf.as_ptr(),
        buf.len() as u32,
        std::ptr::null_mut(),
        &mut ov,
    );
    let done = if ok == FALSE {
        if GetLastError() != ERROR_IO_PENDING {
            CloseHandle(ev);
            return Err(Error::Transport(format!(
                "WriteFile failed ({})",
                GetLastError()
            )));
        }
        let mut written = 0u32;
        GetOverlappedResult(h, &ov, &mut written, 1) != FALSE
    } else {
        true
    };
    CloseHandle(ev);
    if done {
        Ok(())
    } else {
        Err(Error::Transport(format!(
            "write did not complete ({})",
            GetLastError()
        )))
    }
}

/// 回 Some(n)＝讀到 n bytes；None＝handle 已關（該收工）
unsafe fn overlapped_read(h: HANDLE, buf: &mut [u8]) -> Option<usize> {
    let mut ov: OVERLAPPED = zeroed();
    let ev = CreateEventW(std::ptr::null(), 1, 0, std::ptr::null());
    ov.hEvent = ev;
    let ok = ReadFile(
        h,
        buf.as_mut_ptr(),
        buf.len() as u32,
        std::ptr::null_mut(),
        &mut ov,
    );
    if ok == FALSE && GetLastError() != ERROR_IO_PENDING {
        CloseHandle(ev);
        return None;
    }
    let mut n = 0u32;
    let done = GetOverlappedResult(h, &ov, &mut n, 1) != FALSE; // 阻塞等完成；handle 關閉時以錯誤返回
    CloseHandle(ev);
    if done {
        Some(n as usize)
    } else {
        None
    }
}

/// SetupDi 列舉 → CreateFile → VID 046D + usage page 0xFF00/0xFF43 過濾。
/// 與 M0 探針同一套，差別只在回傳結構帶著 path 供分組。
unsafe fn enumerate_hidpp_interfaces() -> Vec<RawIface> {
    let mut out = Vec::new();
    let devs = SetupDiGetClassDevsW(
        &GUID_DEVINTERFACE_HID,
        std::ptr::null(),
        std::ptr::null_mut(),
        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE,
    );
    if devs == -1 {
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
        let path_ptr = std::ptr::addr_of!((*header).DevicePath) as *const u16;
        let mut len = 0usize;
        while *path_ptr.add(len) != 0 {
            len += 1;
        }
        let path =
            String::from_utf16_lossy(std::slice::from_raw_parts(path_ptr, len)).to_lowercase();

        let handle = CreateFileW(
            path_ptr,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED,
            std::ptr::null_mut(),
        );
        if handle == INVALID_HANDLE_VALUE {
            continue; // 系統保留的滑鼠/鍵盤 TLC——本來就不是我們要的
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
        if status != HIDP_STATUS_SUCCESS || !(caps.UsagePage == 0xFF00 || caps.UsagePage == 0xFF43)
        {
            CloseHandle(handle);
            continue;
        }
        out.push(RawIface {
            path,
            handle: handle as usize,
            usage_page: caps.UsagePage,
            product: attrs.ProductID,
            out_len: caps.OutputReportByteLength,
            in_len: caps.InputReportByteLength,
        });
    }
    SetupDiDestroyDeviceInfoList(devs);
    out
}
