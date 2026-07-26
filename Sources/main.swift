// main.swift — 入口與 argv 解析（零依賴，手寫解析）
import Foundation

let NIBBLE_VERSION = "1.1.0"

var rawArgs = Array(CommandLine.arguments.dropFirst())
if let i = rawArgs.firstIndex(of: "--json") {
    jsonMode = true
    rawArgs.remove(at: i)
}

// 從 .app bundle 雙擊啟動時沒有引數（Finder 只會塞 -psn_*）→ 直接進選單列模式
let bundled = Bundle.main.bundleIdentifier != nil
let fromFinder = bundled && rawArgs.allSatisfy { $0.hasPrefix("-psn_") }
let command = fromFinder ? "menubar" : (rawArgs.first ?? "help")
let subArgs = fromFinder ? [] : Array(rawArgs.dropFirst())

switch command {
case "status":   exit(cmdStatus())
case "battery":  exit(cmdBattery())
case "dump":     exit(cmdDump())
case "doctor":   exit(cmdDoctor())
case "dpi":      exit(cmdDPI(subArgs))
case "rate":     exit(cmdRate(subArgs))
case "rgb":      exit(cmdRGB(subArgs))
case "mode":     exit(cmdMode(subArgs))
case "wheel":    exit(cmdWheel(subArgs))
case "onboard":  exit(cmdOnboard(subArgs))
case "buttons":  exit(cmdButtons())
case "spy":      exit(cmdSpy(subArgs))
case "remap":    exit(cmdRemap())
case "config":   exit(cmdConfig(subArgs))
case "apply":    exit(cmdApply())
case "replay":   exit(cmdReplay(subArgs))
case "menubar":  exit(runMenuBar())
case "ui":       exit(runSettingsUI())
case "version", "--version", "-v":
    if jsonMode { emitJSON(["version": NIBBLE_VERSION]) } else { print("nibble \(NIBBLE_VERSION)") }
    exit(0)
default:
    print("""
    Nibble v\(NIBBLE_VERSION) — \(L("lightweight Logitech mouse control for macOS (native · zero-dependency · no daemon by default)",
                                    "輕量羅技滑鼠控制工具（macOS 原生 · 零依賴 · 預設零常駐）"))

    \(L("READ", "讀取"))
      nibble status [--json]        \(L("device overview", "裝置總覽"))
      nibble battery [--json]       \(L("battery only, script-friendly", "只印電池，適合腳本"))
      nibble dump [--json]          \(L("full HID++ feature enumeration", "HID++ feature 完整枚舉"))
      nibble buttons [--json]       \(L("programmable buttons (0x1b04 MX / 0x8110 G)", "按鍵列舉（0x1b04 MX / 0x8110 G 系）"))
      nibble onboard info [--json]  \(L("onboard memory info", "板載記憶體資訊"))
      nibble doctor [--json]        \(L("diagnose permissions, device, engine — start here if stuck", "診斷權限／裝置／引擎——卡住先跑這個"))

    \(L("CONFIGURE (runtime writes, reverted by power cycle, verified by read-back)",
        "設定（runtime 寫入，斷電回復，寫後回讀驗證）"))
      nibble dpi [50-25600]         \(L("get / set DPI", "讀／寫 DPI"))
      nibble rate [125|250|500|1000]\(L(" get / set report rate", " 讀／寫回報率"))
      nibble rgb off|show           \(L("lights off (power saving) / list effects", "關燈省電／看燈效槽"))
      nibble mode [host|onboard]    \(L("control-mode flag", "板載↔軟體主導模式旗標"))
      nibble wheel free|ratchet     \(L("SmartShift (MX-series)", "滾輪模式（MX 系）"))

    \(L("REMAP BUTTONS (engine runs inside the menu bar app)", "改鍵（引擎由選單列常駐執行）"))
      nibble remap                  \(L("press a button, assign an action", "按實體鍵 → 指定動作"))
      nibble spy [seconds]          \(L("live button-event monitor (diagnostic)", "按鍵事件即時監看（診斷）"))

    \(L("CONFIG & REPLAY", "設定檔與重放"))
      nibble config init|show       ~/.config/nibble.json
      nibble apply                  \(L("apply config file", "套用設定檔"))
      nibble replay install         \(L("auto-apply at login (one-shot launchd)", "登入自動 apply（launchd 一次性）"))

    \(L("ONBOARD MEMORY (read-only by design)", "板載記憶體（唯讀）"))
      nibble onboard backup         \(L("dump all sectors — escape hatch", "全 sector 存檔——逃生門"))

    \(L("UI", "介面"))
      nibble menubar                \(L("interactive menu bar + remap engine host (~15 MB)", "互動選單列＋改鍵引擎宿主（約 15 MB）"))
      nibble ui                     \(L("settings window (General + Buttons); quits when closed", "設定面板（General＋Buttons），關窗即退"))
      open Nibble.app               \(L("same as menubar; bundle also enables low-battery notifications", "同 menubar；bundle 版另有低電量通知"))

    \(L("Env: NIBBLE_DEBUG=1 dumps raw HID++ packets.", "環境變數：NIBBLE_DEBUG=1 印出 HID++ 原始封包"))
    \(L("First run: System Settings > Privacy & Security > Input Monitoring > enable your terminal.",
        "首次使用：系統設定 → 隱私權與安全性 → 輸入監控 → 授權你的終端機"))
    \(L("Exit codes: 0 ok · 1 no device / not applied · 2 transport error · 64 usage.",
        "退出碼：0 成功 · 1 無裝置／未生效 · 2 傳輸錯誤 · 64 用法錯誤"))
    """)
    exit(command == "help" ? 0 : 64)
}
