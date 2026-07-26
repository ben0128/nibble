# Nibble Windows 版 — 設計

日期：2026-07-27 · 狀態：設計已口頭核准，spec 待 Ben 審閱
範圍：第一個可發佈的 Windows 版本（win-v0.1.0）＋它所需的 macOS 端前置工作

## 0. 已拍板的決定

| 決定 | 結論 | 備註 |
|---|---|---|
| 驗證環境 | **Mac 上開 VM**（Windows 11 ARM）+ USB passthrough | passthrough 本身未驗證 → M0 閘門 |
| 語言 | **Rust + `windows-sys`**（UI 走裸 Win32） | 不用 GUI 框架；體積目標：每個 exe 幾百 KB |
| 協定層 | **(A) 兩份實作 + 共用測試向量** | Swift 那份完全不動；防漂移靠 `docs/fixtures/*.json` |
| v1 範圍 | **分兩階**：v1.0 監控+控制，v1.x 改鍵 | 改鍵（0x8110 + SendInput）不進首發，但架構第一天留位 |
| exe 結構 | **兩個 exe**：`nibble.exe`（console）+ `nibble-tray.exe`（windows subsystem） | PE subsystem 烙死在檔頭，單一 exe 的 hack 不可靠 |
| 設定檔 | **`%APPDATA%\nibble\nibble.json`**，schema 與 macOS 同一份 | `NIBBLE_CONFIG` 覆寫照搬（測試靠它） |
| fixtures + CI | **第一天就架** | 「第一天」= M0 閘門通過後、任何正式 Rust 碼之前（M1 的第一件事）；M0 是拋棄式探針，NO-GO 時不留任何前置投資 |
| 版本流 | **獨立**：`win-v0.x` tag，不共用 macOS 的 `v1.7.x` | 避免「空升級」；Scoop autoupdate 對 win-v tag |
| 發佈 | **Scoop bucket**（`ben0128/scoop-nibble`）、可攜式 zip、**不簽章** | x64 + ARM64 兩份；winget 等有簽章再說 |

## 1. 目標與非目標

**目標**：Windows 上的 Logitech HID++ 工具，與 macOS 版同一套價值：零依賴、無常駐（托盤是 opt-in）、錯誤附帶修法、`--json` 給 script/agent、體積以 KB 計。

**v1.0 明確不做**：改鍵、macros、profiles UI、設定視窗、板載寫入（與 macOS 同樣凍結）、開機自啟（registry Run key，v1.x 隨改鍵一起）、per-app profiles、winget、韌體、RGB 圖樣編輯、鍵盤。

## 2. Repo 佈局

```
nibble/
  Sources/  Tests/  Makefile        ← macOS 完全不動（Homebrew formula 在根目錄跑 make）
  windows/
    Cargo.toml                      ← workspace
    crates/nibble-core/             ← 協定 + 設定檔邏輯；零 Win32 依賴，任何平台可 cargo test
    crates/nibble-win/              ← 所有碰 Win32 的東西；兩個 [[bin]]
    spike/                          ← M0 探針（拋棄式，對應當年的 spike/m0.swift）
  docs/fixtures/*.json              ← 兩份實作的共同裁判（來源：Swift 測試向量）
  docs/superpowers/specs/           ← 本文件
```

兩個 crate、不是四個：`nibble-core` 日後換 transport 就能蓋 Linux；`nibble-win` 隔離全部平台碼。

## 3. 架構

### 3.1 對應表（Swift → Rust）

| macOS | Windows | 要點 |
|---|---|---|
| `HIDPP.swift` | `nibble-core::hidpp` | trait `Transport` 鏡射 `HIDPPTransport`：`round_trip()` + `is_direct`/`long_only`/`product_id` + `on_report`。framing、swId 匹配、錯誤解碼（0x8F/0xFF）、feature 快取、電池三段 fallback（0x1001 電壓曲線 → 0x1004 → 0x1000）、DPI/rate/RGB 全在這 |
| `Config.swift` | `nibble-core::config` | serde 對同一份 JSON schema；**同一套保護語意**：解不開就拒絕不覆蓋（錯誤訊息沿用原句式）、原子寫入（tempfile+rename，先解析 symlink）、merge-only、寫入端夾值 |
| `Transport.swift` | `nibble-win::transport` | `SetupDiGetClassDevs(GUID_DEVINTERFACE_HID)` 列舉 → `HidD_GetAttributes` 過濾 VID 0x046D → usage page 0xFF00/0xFF43 過濾 collection → overlapped `ReadFile` 讀執行緒餵 `on_report`；`WriteFile` 送出。**M0 教訓直接繼承：buffer 含 report-ID byte**；short 0x10 / long 0x11 同一套 |
| `MenuBar.swift` | `nibble-win::tray` | `Shell_NotifyIcon` + `TrackPopupMenu`（跳選單前 `SetForegroundWindow`，退出時 `NIM_DELETE`）；**單一實例 = named mutex**（`flock` 的對應物；CLI 的 tray-running 探測 = `OpenMutex`） |
| `Commands.swift` | `nibble-win::cli` | `status/battery/dump/dpi/rate/rgb/doctor/config/apply/version`，全 `--json`，exit codes 同 macOS（0/1/2/64） |
| `LoginItem.swift` | （v1.x）registry Run key | 隨改鍵引擎一起，v1.0 不做 |

### 3.2 v1.0 托盤

選單：裝置名 + 電量標題列（唯讀）、DPI 級距、回報率、燈效、Quit。電量顯示 = 圖示 tooltip + 選單標題；把數字畫進圖示（macOS 那招）列 stretch。**不做設定檔監看**（那是改鍵引擎的需求；v1.0 選單開啟時現讀）。訊息視窗用 `HWND_MESSAGE` 子視窗（不可見、不進工作列）。

### 3.3 資料流

CLI：開 transport → 探測（接收器 1–6，全空補問 0xFF；直連只問 0xFF——與 macOS `discover()` 同邏輯，fixtures 有向量）→ 呼叫 → 回讀驗證 → 退出。托盤：計時器輪詢電量（沿用 macOS 的 300s + 開選單即刷新）。

## 4. 錯誤處理

原封搬 macOS 哲學：每個錯誤附修法；`doctor` 是第一站。Windows 版 doctor 檢查：列舉層有沒有裝置（與「開啟失敗」分開報）、G HUB 是否同時在跑（HID 共享開啟通常可行，但要報出來）、config 解析（沿用「exists but could not be read — refusing to overwrite it」語意與句式）、tray 活著沒（mutex 探測）。設定檔保護是 v1.7.1 用資料損失換來的，Rust 端第一天就有，且 **fixtures 涵蓋**。

## 5. 里程碑

```
M0  VM（Parallels/VMware/UTM 擇一）+ 接收器 passthrough + 拋棄式探針：
    HID++ ping（IRoot fn1）+ 電池（0x1001）在 G502 上讀到合理值。
    GO 判準（要可判定，不是感覺）：連續 20 次 ping 全數有回應，
    且電池電壓落在 3300–4300 mV。任一不成立或 passthrough 搶不到
    裝置 → NO-GO，計畫停在這裡。
M1  nibble-core 全綠：fixtures 從 Tests/main.swift 匯出、Swift 側改吃 fixtures
    （匯出正確性由此驗證）、CI 上線（mac runner 跑 make test；windows runner
    建置雙 exe + 跑 core 測試）。
M2  transport + CLI，VM 內對 G502 實測全部讀寫指令；cargo-mutants 引入。
M3  tray + Scoop bucket + win-v0.1.0 首發（x64 + ARM64 zip）。
```

實務註記：接收器指派給 VM 期間 Mac 沒有滑鼠——先把 BT 的 MX Master 3 或 Magic Mouse 配好再開工。

實作計畫切法：第一份 plan 只涵蓋 M0 + macOS 前置 + M1（M0 放最前，NO-GO 即中止）；M2/M3 過閘後另開 plan——在一個可能被 M0 殺掉的計畫裡預先細排 M3 是浪費。

## 6. 測試

**fixtures 格式**（`docs/fixtures/`，按功能分檔）：

```json
// hidpp-battery.json 之類：協定向量。swid 必須寫死在 fixture 裡——
// 兩邊的 softwareID 都是 pid 衍生的，測試時要能注入固定值，否則向量無法重放。
{ "name": "g-series battery via 0x1001",
  "swid": 10,
  "exchanges": [
    { "request": [1, 0, 10, 16, 1],  "prefer_long": false,
      "response": [1, 0, 10, 6, 0, 0],
      "note": "IRoot.getFeature(0x1001) → featureIndex 6" },
    { "request": [1, 6, 10],         "prefer_long": false,
      "response": [1, 6, 10, 14, 231, 144],
      "note": "0x0EE7 = 3815 mV, flags 0x90 = charging" } ],
  "expect": { "source": "0x1001", "millivolts": 3815, "charging": true } }

// config-merge.json：設定檔語意向量
{ "name": "notify write keeps buttonProfiles",
  "existing": { "dpi": 1600, "buttonProfiles": { "Gaming": {} }, "activeProfile": "Gaming" },
  "op": "updateLowBatteryNotify(true, 25)",
  "expect_keys_preserved": ["buttonProfiles", "activeProfile", "dpi"] }
```

（實際 byte 一律從 `Tests/main.swift` 既有向量匯出，不重新手打；上例即該檔電池段的忠實轉寫。）Swift 與 Rust 各自的既有／新增突變測試照舊——fixtures 管「兩邊一致」，mutation 管「測試真的會叫」。

## 7. 發佈

Scoop manifest 用 `checkver`/`autoupdate` 盯 `win-v*` release；zip 內容 = 兩個 exe + README 節錄。SmartScreen 策略：Scoop / 原始碼建置為主要路徑，zip 直接下載的使用者在 README 教「解除封鎖」；**不在任何程式或腳本裡代使用者清 Zone.Identifier**。

## 8. 風險與未驗證清單

| 風險 | 處置 |
|---|---|
| VM passthrough 對 HID 裝置不穩 | M0 閘門的存在理由；NO-GO 就停 |
| `windows-sys` API 版本漂移 | 鎖定 crate 版本；簽章以官方 samples 為準 |
| G HUB／OMM 同時在跑時的裝置存取衝突 | doctor 檢查 + 實測；HID 共享開啟預期可行但未驗 |
| Win11 ARM 的 x64 模擬跑我們的 x64 zip | M3 前在 VM 驗一次 x64 版 |
| 「幾百 KB」是估計 | M1 第一次建置就量（`opt-level="z"` + lto + strip + 靜態 CRT），數字進 README 才准寫 |
| 競品：Windows 已有 openlogi-net、Mouser、官方 OMM | 差異化押在 v1.x 的 G 系改鍵 + `--json`；v1.0 自知只是立足點 |

## 9. macOS 端前置工作（進入 M1 前）

1. `Tests/main.swift` 的協定向量匯出成 `docs/fixtures/*.json`，Swift 測試改為讀檔。
2. GitHub Actions：mac runner 跑 `make test`（macOS 側目前沒有 CI，一併補上）。
3. 其餘 macOS 程式碼零改動。
