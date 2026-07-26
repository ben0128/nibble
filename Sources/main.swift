// main.swift — 入口與 argv 解析（零依賴，手寫解析）
import Foundation

let BENMOUSE_VERSION = "0.1.0"

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? "help"

switch command {
case "status":
    exit(cmdStatus())
case "battery":
    exit(cmdBattery())
case "dump":
    exit(cmdDump())
case "version", "--version", "-v":
    print("benmouse \(BENMOUSE_VERSION)")
    exit(0)
default:
    print("""
    BenMouse v\(BENMOUSE_VERSION) — 輕量羅技滑鼠控制工具（macOS 原生 · 零依賴 · 零常駐）

    用法：
      benmouse status     裝置總覽（連線、電池、DPI、回報率、feature 概況）
      benmouse battery    只印電池一行（適合腳本）
      benmouse dump       HID++ feature 完整枚舉（診斷用）
      benmouse version    版本

    環境變數：
      BENMOUSE_DEBUG=1    印出 HID++ 原始封包

    首次使用：系統設定 → 隱私權與安全性 → 輸入監控，授權你的終端機。
    """)
    exit(command == "help" ? 0 : 64)
}
