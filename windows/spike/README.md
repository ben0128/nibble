# M0 探針 — 執行手冊

這一步是整個 Windows 計畫的 GO/NO-GO 閘門（spec §5）。它回答一件事：
**USB passthrough 之下，HID++ 一問一答可不可靠。** 不過就不做。

## 0. 前置

- 把 **MX Master 3 或 Magic Mouse 用藍牙連上 Mac**——接收器交給 VM 之後 Mac 就沒滑鼠了。
- G502 醒著（別在充電板上睡著）。

## 1. VM（三選一）

| 選項 | 備註 |
|---|---|
| **Parallels Desktop** | passthrough 體驗最順：Devices → USB → 勾 Logitech USB Input Device |
| **VMware Fusion**（免費） | VM 選單 → USB & Bluetooth → Connect Logitech receiver |
| **UTM**（免費） | VM 設定先加 USB 裝置；QEMU 的 passthrough 偶爾要重插 |

裝 **Windows 11 ARM**（VM 軟體會自己抓 ISO）。接收器插 Mac 後在 VM 軟體裡把
`Logitech USB Input Device`（046D:C539）指派給 VM——**指派瞬間 Mac 端滑鼠會斷**，正常。

驗收：VM 裡裝置管理員 → 人性化介面裝置，出現多個 Logitech 項目。

## 2. 拿探針（免工具鏈）

GitHub → nibble repo → **Actions** → 最新一次綠色的 `ci` run → Artifacts →
下載 **m0-probe-x64**，解壓得 `m0-probe.exe`。

（x64 exe 在 Win11 ARM 的模擬層執行——這順便驗掉 spec §8 的一條風險。
被 SmartScreen 攔就右鍵 → 內容 → 解除封鎖；這是你自己編譯的東西。）

想從原始碼跑也可以：VM 裡 `winget install Rustlang.Rustup`＋VS Build Tools（C++），
然後 `cargo run --release -p m0-probe`——但沒必要。

## 3. 跑

```powershell
.\m0-probe.exe
```

**先確認 VM 裡沒有 G HUB / Onboard Memory Manager 在跑**（全新 VM 不會有）。

## 4. 判讀

```
GO — proceed to M2        ← 20/20 ping + 電壓 3300–4300 mV，回來說一聲，開工 M2
NO-GO                     ← 把整份輸出貼回來，特別是：
                             - opened: 那幾行（開到哪些 collection）
                             - reply topology:（回應落在哪個 usage 上——這決定 M2 transport 的形狀）
exit 2（環境問題）         ← 多半是 passthrough 沒真的把裝置給 VM；換一套 VM 軟體再試一次
```

不管結果如何，**`reply topology` 那幾行都請保留**——short/long collection 在 Windows
上是不是分開的介面、回應落在哪邊，是 M2 的第一個設計輸入。

## 5. GO 之後：M2 硬體驗證（同一個 Actions run 的 `nibble-win-x64` artifact）

CLI 和托盤已經建好、無裝置路徑在 CI 上實測過；**有裝置的路徑等這一步**。
下載 `nibble-win-x64`，在 VM 裡照順序跑：

```powershell
.\nibble.exe status          # 名稱、電量、DPI、rate 全部要有值
.\nibble.exe dpi 3200        # 要回報 read-back；滑鼠移動手感應該立刻變
.\nibble.exe dpi 1600
.\nibble.exe rate 500        # 這條會踩 host-fallback（滑鼠若在 onboard 模式）
.\nibble.exe rate 1000
.\nibble.exe rgb off         # 燈要真的熄
.\nibble.exe config init; .\nibble.exe apply
.\nibble-tray.exe            # 托盤圖示 → tooltip 電量 → 右鍵選單改 DPI
.\nibble.exe doctor          # tray 檢查此時應顯示 running
```

全過 → 回報一聲，win-v0.1.0 照 `windows/scoop/nibble.json` 頂部的流程發佈。
任何一條掛掉 → 整份輸出貼回來。
