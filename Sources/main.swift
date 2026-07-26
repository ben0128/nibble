// main.swift — 入口與 argv 解析（零依賴，手寫解析）
import Foundation

let NIBBLE_VERSION = "0.5.0"

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? "help"
let subArgs = Array(arguments.dropFirst())

switch command {
case "status":   exit(cmdStatus())
case "battery":  exit(cmdBattery())
case "dump":     exit(cmdDump())
case "dpi":      exit(cmdDPI(subArgs))
case "rate":     exit(cmdRate(subArgs))
case "rgb":      exit(cmdRGB(subArgs))
case "mode":     exit(cmdMode(subArgs))
case "wheel":    exit(cmdWheel(subArgs))
case "onboard":  exit(cmdOnboard(subArgs))
case "buttons":  exit(cmdButtons())
case "config":   exit(cmdConfig(subArgs))
case "apply":    exit(cmdApply())
case "replay":   exit(cmdReplay(subArgs))
case "menubar":  exit(runMenuBar())
case "ui":       exit(runSettingsUI())
case "version", "--version", "-v":
    print("nibble \(NIBBLE_VERSION)")
    exit(0)
default:
    print("""
    Nibble v\(NIBBLE_VERSION) — 輕量羅技滑鼠控制工具（macOS 原生 · 零依賴 · 零常駐）

    讀取：
      nibble status              裝置總覽
      nibble battery             只印電池一行（適合腳本）
      nibble dump                HID++ feature 完整枚舉（診斷）
      nibble onboard info        板載記憶體資訊
      nibble buttons             按鍵列舉（0x1b04，改鍵前置）

    設定（runtime 寫入，斷電回復；寫後回讀驗證）：
      nibble dpi [值]            讀／寫 DPI（50–25600）
      nibble rate [Hz]           讀／寫回報率
      nibble rgb off|show        關燈省電／看燈效槽
      nibble mode [host|onboard] 板載↔軟體主導模式（旗標，斷電回復）
      nibble wheel free|ratchet  滾輪模式（MX 系限定）

    設定檔與重放：
      nibble config init|show    以目前狀態建立／檢視 ~/.config/nibble.json
      nibble apply               套用設定檔
      nibble replay install      登入時自動 apply（launchd 一次性，零常駐）

    板載備份（唯讀；寫入功能凍結中）：
      nibble onboard backup      dump 全部 sector 存檔（逃生門）

    選單列（opt-in 常駐）：
      nibble menubar             電量顯示，5 分鐘更新一次

    環境變數：NIBBLE_DEBUG=1 印出 HID++ 原始封包
    首次使用：系統設定 → 隱私權與安全性 → 輸入監控，授權你的終端機。
    """)
    exit(command == "help" ? 0 : 64)
}
