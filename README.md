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

`BENMOUSE_DEBUG=1` 印出 HID++ 原始封包。

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
- [ ] M2 — 寫入組：DPI／回報率／RGB off（runtime，不碰 flash）＋ `apply` 設定檔＋重連重放
- [ ] M3 — Onboard 板載記憶體：唯讀 backup（寫入功能待格式驗證後解凍）
- [ ] M4 — Menu bar 電量（opt-in，AppKit，RAM < 20MB）

## License

MIT
