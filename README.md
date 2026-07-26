# BenMouse 🖱️

macOS 原生、單一執行檔、零依賴、預設零常駐的羅技滑鼠控制工具。
Lightweight, native, zero-dependency Logitech mouse control for macOS — no Electron, no daemon, no account, no telemetry.

```
$ benmouse status
BenMouse v0.1.0 ── G502 LIGHTSPEED Wireless Gaming Mouse
──────────────────────────────────────────────────────────
 link      HID++ 4.2 · receiver 046D:C539 · device #1
 battery   [#####.....] 46%  3.83V  charging ⚡  (0x1001)
 dpi       1600
 rate      1000 Hz
 features  onboard-profiles ✓ · rgb ✓ · smartshift ✗
──────────────────────────────────────────────────────────
 0 daemons · query 200 ms · peak RAM 7.2 MB
```

## Build

```
make
./benmouse status
```

首次執行：**系統設定 → 隱私權與安全性 → 輸入監控**，打開你的終端機後重跑。

## 指令

| 指令 | 說明 |
|---|---|
| `benmouse status` | 裝置總覽（連線、電池、DPI、回報率、feature 概況） |
| `benmouse battery` | 只印電池一行（適合腳本） |
| `benmouse dump` | HID++ feature 完整枚舉（診斷用） |
| `benmouse dpi [50–25600]` | 讀／寫 DPI（寫後回讀驗證） |
| `benmouse rate [Hz]` | 讀／寫回報率（onboard 模式會自動切 host） |
| `benmouse rgb off\|show` | 關燈省電（G502 LIGHTSPEED 官方續航 48h→60h）／看燈效槽 |
| `benmouse mode [host\|onboard]` | 板載↔軟體主導（模式旗標，斷電自動回復） |
| `benmouse wheel free\|ratchet` | 滾輪模式（MX 系限定，未實測） |
| `benmouse onboard info\|backup` | 板載記憶體資訊／全 sector 唯讀備份 |
| `benmouse config init\|show` | 以目前狀態建立／檢視 `~/.config/benmouse.json` |
| `benmouse apply` | 套用設定檔（runtime 寫入，不碰 flash） |
| `benmouse replay install` | 登入時自動 `apply`（launchd 一次性，零常駐） |
| `benmouse menubar` | 選單列電量（opt-in 常駐，實測 9.2MB footprint） |

`BENMOUSE_DEBUG=1` 印出 HID++ 原始封包。

**設計原則**：所有寫入都是 runtime（裝置 RAM），persist 一律 0，不碰板載 flash——
滑鼠斷電回到原廠／板載狀態，`replay` 在登入時自動重放你的設定。
板載記憶體只讀不寫（`onboard backup` = 逃生門），寫入功能待格式驗證後解凍。

## 架構

```
Sources/
├── HIDPP.swift      HIDPPCore 純協定層（不 import IOKit：可測試、可移植）
├── Transport.swift  IOKit 傳輸層（IOHIDManager、report 收發）
├── Commands.swift   指令層
└── main.swift       入口與 argv 解析
```

G 系列冷知識：電池不走一般的 0x1000/0x1004，走 **0x1001 BatteryVoltage**（回報電壓），
百分比由內建 LiPo 放電曲線換算——這是多數 MX 系工具不支援 G 系列的原因之一。

## Roadmap

- [x] M0 — HID++ 通道驗證（ping／協定版本／電池電壓）
- [x] M1 — 讀取組：`status` / `battery` / `dump`
- [x] M2 — 寫入組：DPI／回報率／RGB off（runtime，不碰 flash）＋ `config`/`apply` ＋登入重放
- [x] M3 — Onboard 板載記憶體：唯讀 `backup`（16 sectors 實測 OK；寫入凍結待格式驗證）
- [x] M4 — Menu bar 電量（opt-in，AppKit，實測 9.2MB footprint）
- [ ] M5 — 按鍵 divert 改鍵 → per-app profile → 手勢 → 巨集
- [ ] M6 — 英文 README、Homebrew tap

## License

MIT
