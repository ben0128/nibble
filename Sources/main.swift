// main.swift — 入口與 argv 解析（零依賴，手寫解析）
import Foundation


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
case "profile":  exit(cmdProfile(subArgs))
case "config":   exit(cmdConfig(subArgs))
case "apply":    exit(cmdApply())
case "replay":   exit(cmdReplay(subArgs))
case "menubar":  exit(runMenuBar())
case "ui":       exit(runSettingsUI(initialTab: subArgs.first))
case "version", "--version", "-v":
    if jsonMode { emitJSON(["version": NIBBLE_VERSION]) } else { print("nibble \(NIBBLE_VERSION)") }
    exit(0)
default:
    print("""
    Nibble v\(NIBBLE_VERSION) — lightweight Logitech mouse control for macOS (native · zero-dependency · no daemon by default)

    READ
      nibble status [--json]        device overview
      nibble battery [--json]       battery only, script-friendly
      nibble dump [--json]          full HID++ feature enumeration
      nibble buttons [--json]       programmable buttons (0x1b04 MX / 0x8110 G)
      nibble onboard info [--json]  onboard memory info
      nibble doctor [--json]        diagnose permissions, device, engine — start here if stuck

    CONFIGURE (runtime writes, reverted by power cycle, verified by read-back)
      nibble dpi [50-25600]         get / set DPI
      nibble rate [125|250|500|1000] get / set report rate
      nibble rgb off|show           lights off (power saving) / list effects
      nibble mode [host|onboard]    control-mode flag
      nibble wheel free|ratchet     SmartShift (MX-series)

    REMAP BUTTONS (engine runs inside the menu bar app)
      nibble remap                  press a button, assign an action
      nibble profile [use <name>]   switch between sets of button mappings
      nibble spy [seconds]          live button-event monitor (diagnostic)

    CONFIG & REPLAY
      nibble config init|show       ~/.config/nibble.json
      nibble apply                  apply config file
      nibble replay install         auto-apply at login (one-shot launchd)

    ONBOARD MEMORY (read-only by design)
      nibble onboard backup         dump all sectors — escape hatch

    UI
      nibble menubar                interactive menu bar + remap engine host (~15 MB)
      nibble ui [buttons]           settings window (General + Buttons); quits when closed
      open Nibble.app               same as menubar; bundle also enables low-battery notifications

    Env: NIBBLE_DEBUG=1 dumps raw HID++ packets.
    First run: System Settings > Privacy & Security > Input Monitoring > enable your terminal.
    Exit codes: 0 ok · 1 no device / not applied · 2 transport error · 64 usage.
    """)
    exit(command == "help" ? 0 : 64)
}
