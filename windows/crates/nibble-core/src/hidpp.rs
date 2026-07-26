// hidpp.rs — HID++ 2.0 協定核心（Sources/HIDPP.swift 的對應實作）。
// 規則同 Swift 版：這個模組永遠不碰 OS API，協定知識與 transport 完全解耦。
// 封包佈局：[deviceIndex, featureIndex, fn<<4|swid, params...]；
// 錯誤回應：[deviceIndex, 0x8F|0xFF, 原 featureIndex, 原 fnsw, code]。
use std::collections::HashMap;
use std::fmt;
use std::time::Duration;

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Timeout,
    /// 0x8F code 0x08/0x09：索引上沒裝置或裝置睡眠
    DeviceOffline(u8),
    /// 其他 0x8F 錯誤（接收器代答）
    ReceiverError(u8),
    /// 0xFF 形式的 HID++ 2.0 錯誤
    ProtocolError(u8),
    FeatureUnsupported(u16),
    Transport(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Timeout => write!(f, "device did not respond (timeout)"),
            Error::DeviceOffline(c) => write!(f, "no awake device at this index (0x{c:02X})"),
            Error::ReceiverError(c) => write!(f, "receiver error 0x{c:02X}"),
            Error::ProtocolError(c) => write!(f, "HID++ error 0x{c:02X}"),
            Error::FeatureUnsupported(id) => {
                write!(f, "feature 0x{id:04X} not supported by this device")
            }
            Error::Transport(msg) => write!(f, "{msg}"),
        }
    }
}

impl std::error::Error for Error {}

/// 上層需要的全部：一問一答、連線描述、（之後的）事件旁聽。
/// 與 Swift 的 HIDPPTransport 同形——Windows 的 HID 實作、Linux 的 hidraw、
/// 以及測試的 scripted transport 都實作這一個 trait。
pub trait Transport {
    fn round_trip(
        &mut self,
        request: &[u8],
        prefer_long: bool,
        timeout: Duration,
        matcher: &dyn Fn(&[u8]) -> bool,
    ) -> Result<Vec<u8>, Error>;

    /// 直連（藍牙／有線）：device index 用 0xFF，不探測接收器的 1–6
    fn is_direct(&self) -> bool {
        false
    }
    /// 只有 long report collection（BLE 直連）：短請求要升級
    fn long_only(&self) -> bool {
        false
    }
    /// 046D:xxxx——顯示與診斷用
    fn product_id(&self) -> u16 {
        0
    }
}

// discover() 之後要讓多個 Device 輪流用同一個 transport——借用也得是 Transport
impl<T: Transport + ?Sized> Transport for &mut T {
    fn round_trip(
        &mut self,
        request: &[u8],
        prefer_long: bool,
        timeout: Duration,
        matcher: &dyn Fn(&[u8]) -> bool,
    ) -> Result<Vec<u8>, Error> {
        (**self).round_trip(request, prefer_long, timeout, matcher)
    }
    fn is_direct(&self) -> bool {
        (**self).is_direct()
    }
    fn long_only(&self) -> bool {
        (**self).long_only()
    }
    fn product_id(&self) -> u16 {
        (**self).product_id()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Battery {
    pub millivolts: Option<u16>,
    pub percent: u8,
    pub charging: bool,
    pub source: &'static str,
}

pub struct Device<T: Transport> {
    transport: T,
    pub index: u8,
    pub swid: u8,
    feature_cache: HashMap<u16, u8>, // 0 = 已確認不支援（快取「沒有」跟快取「有」一樣重要）
}

impl<T: Transport> Device<T> {
    pub fn new(transport: T, index: u8, swid: u8) -> Self {
        Device {
            transport,
            index,
            swid,
            feature_cache: HashMap::new(),
        }
    }

    pub fn transport(&self) -> &T {
        &self.transport
    }

    pub fn call_index(
        &mut self,
        feature_index: u8,
        function: u8,
        params: &[u8],
    ) -> Result<Vec<u8>, Error> {
        let dev = self.index;
        let fnsw = (function << 4) | self.swid;
        // short report 的 params 上限 3 bytes，超過自動改用 long——與 Swift 同一條門檻
        let need_long = params.len() > 3;
        let mut req = vec![dev, feature_index, fnsw];
        req.extend_from_slice(params);
        let resp = self
            .transport
            .round_trip(&req, need_long, DEFAULT_TIMEOUT, &|p: &[u8]| {
                if p.len() < 5 || p[0] != dev {
                    return false;
                }
                (p[1] == feature_index && p[2] == fnsw)                    // 正常回應
                || (p[1] == 0x8F && p[2] == feature_index && p[3] == fnsw) // 1.0 式錯誤（接收器代答）
                || (p[1] == 0xFF && p[2] == feature_index && p[3] == fnsw) // 2.0 式錯誤
            })?;
        if resp[1] == 0x8F {
            let code = resp[4];
            return Err(if code == 0x08 || code == 0x09 {
                Error::DeviceOffline(code)
            } else {
                Error::ReceiverError(code)
            });
        }
        if resp[1] == 0xFF {
            return Err(Error::ProtocolError(resp[4]));
        }
        Ok(resp[3..].to_vec()) // 只回 params
    }

    /// IRoot.getFeature，帶快取
    pub fn feature_index(&mut self, feature: u16) -> Result<Option<u8>, Error> {
        if let Some(&hit) = self.feature_cache.get(&feature) {
            return Ok(if hit == 0 { None } else { Some(hit) });
        }
        let r = self.call_index(0x00, 0x00, &[(feature >> 8) as u8, (feature & 0xFF) as u8])?;
        self.feature_cache.insert(feature, r[0]);
        Ok(if r[0] == 0 { None } else { Some(r[0]) })
    }

    pub fn call(&mut self, feature: u16, function: u8, params: &[u8]) -> Result<Vec<u8>, Error> {
        match self.feature_index(feature)? {
            Some(fi) => self.call_index(fi, function, params),
            None => Err(Error::FeatureUnsupported(feature)),
        }
    }

    pub fn ping(&mut self) -> Result<(u8, u8), Error> {
        let r = self.call_index(0x00, 0x01, &[0, 0, 0xAA])?;
        Ok((r[0], r[1]))
    }

    pub fn has(&mut self, feature: u16) -> bool {
        matches!(self.feature_index(feature), Ok(Some(_)))
    }

    /// 電池三段 fallback：G 系 0x1001（毫伏＋LiPo 曲線；flags bit7 = 充電）→
    /// 0x1004 unified（直接給百分比；status 1..3 = 充電）→ 0x1000 legacy（非零即充電）。
    pub fn battery(&mut self) -> Result<Battery, Error> {
        if self.feature_index(0x1001)?.is_some() {
            let r = self.call(0x1001, 0, &[])?;
            let mv = (u16::from(r[0]) << 8) | u16::from(r[1]);
            return Ok(Battery {
                millivolts: Some(mv),
                percent: voltage_to_percent(mv),
                charging: r[2] & 0x80 != 0,
                source: "0x1001",
            });
        }
        if self.feature_index(0x1004)?.is_some() {
            let r = self.call(0x1004, 1, &[])?;
            return Ok(Battery {
                millivolts: None,
                percent: r[0],
                charging: matches!(r[2], 1..=3),
                source: "0x1004",
            });
        }
        if self.feature_index(0x1000)?.is_some() {
            let r = self.call(0x1000, 0, &[])?;
            return Ok(Battery {
                millivolts: None,
                percent: r[0],
                charging: r[2] != 0,
                source: "0x1000",
            });
        }
        Err(Error::FeatureUnsupported(0x1001))
    }

    /// AdjustableDPI（0x2201）getSensorDpi：sensor 0，值在 params[1..3]
    pub fn current_dpi(&mut self) -> Result<u16, Error> {
        let r = self.call(0x2201, 2, &[0])?;
        Ok((u16::from(r[1]) << 8) | u16::from(r[2]))
    }
}

/// G502 實測校準的 LiPo 放電曲線——與 Swift 版逐點、逐運算相同
/// （整數除法的截斷行為也一樣；fixtures 釘了 3815 mV → 43% 這個內插點）。
pub fn voltage_to_percent(mv: u16) -> u8 {
    const CURVE: [(i32, i32); 8] = [
        (4180, 100),
        (4050, 85),
        (3950, 70),
        (3850, 50),
        (3750, 30),
        (3650, 15),
        (3550, 5),
        (3500, 2),
    ];
    let mv = i32::from(mv);
    if mv >= CURVE[0].0 {
        return 100;
    }
    if mv <= CURVE[CURVE.len() - 1].0 {
        return 1;
    }
    for i in 0..CURVE.len() - 1 {
        let (v1, p1) = CURVE[i];
        let (v2, p2) = CURVE[i + 1];
        if mv <= v1 && mv >= v2 {
            return (p2 + (mv - v2) * (p1 - p2) / (v1 - v2)) as u8;
        }
    }
    50
}
