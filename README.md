# Nibble 🖱️

Lightweight, zero-dependency Logitech mouse control for macOS. Single 256 KB binary. No daemon, no telemetry, no account.

> G HUB is a 4 GB install. Nibble is 256 KB.

## Requirements

- macOS, Swift toolchain (`xcode-select --install`)
- Logitech mouse on a USB receiver (Lightspeed/Unifying). Bluetooth-direct: not yet supported.
- Tested: G502 LIGHTSPEED via receiver `046D:C539`, HID++ 4.2

## Install

```sh
git clone https://github.com/ben0128/nibble && cd nibble
make
./nibble status
```

First run needs **Input Monitoring** permission: System Settings → Privacy & Security → Input Monitoring → enable your terminal app → re-run. Error `0xE00002E2` means this permission is missing. No restart needed after granting.

## Commands

| Command | Effect |
|---|---|
| `nibble status` | Overview: link, battery, DPI, report rate, feature flags |
| `nibble battery` | One line, script-friendly: `50% 3.85V charging` |
| `nibble dump` | Enumerate all HID++ features (diagnostic) |
| `nibble dpi [50-25600]` | Get / set DPI, verified by read-back |
| `nibble rate [125\|250\|500\|1000]` | Get / set report rate in Hz |
| `nibble rgb off\|show` | Lights off (power saving) / list zones and effects |
| `nibble mode [host\|onboard]` | Get / set control-mode flag |
| `nibble wheel free\|ratchet [threshold N]` | SmartShift, MX-series only (untested) |
| `nibble onboard info\|backup` | Onboard memory info / read-only full dump |
| `nibble config init\|show` | Create from current state / print `~/.config/nibble.json` |
| `nibble apply` | Apply config file (runtime writes) |
| `nibble replay install\|uninstall` | Auto-`apply` at login via one-shot launchd agent |
| `nibble menubar` | Interactive menu bar: battery + DPI/rate/RGB controls (~15 MB resident, opt-in) |
| `nibble ui` | Native settings window; quits when closed (zero resident) |

Debug: `NIBBLE_DEBUG=1 nibble <cmd>` prints raw HID++ packets.
Exit codes: `0` ok · `1` no awake device or value not applied · `2` transport/protocol error · `64` usage.

## Config file `~/.config/nibble.json`

```json
{ "dpi": 1600, "reportRateHz": 1000, "rgb": "off" }
```

| Key | Type | Values |
|---|---|---|
| `dpi` | int | 50–25600 |
| `reportRateHz` | int | 125 / 250 / 500 / 1000 |
| `rgb` | string | `"off"` or `"keep"` |
| `wheelMode` | string | `"free"` / `"ratchet"` (MX-series only) |
| `wheelThreshold` | int | 1–254 |

Omitted keys are left untouched.

## Behavior model

- All writes are **runtime** (device RAM, persist flag = 0). A power cycle reverts the mouse to its onboard profile — `nibble replay install` re-applies your config at login.
- Report-rate and RGB writes require **host mode**; commands switch the mode flag automatically. The flag also reverts on power cycle.
- Onboard flash (HID++ feature `0x8100`) is **read-only by design**. `onboard backup` dumps every sector to `~/.config/nibble/backups/` as `.bin` + `.json` metadata — your escape hatch is restoring factory settings via G HUB on any machine.
- Zero resident processes unless you opt into `menubar`.

## Troubleshooting

| Symptom | Cause → fix |
|---|---|
| `0xE00002E2` on open | Input Monitoring not granted → grant to terminal app, re-run |
| "no awake device" | Mouse asleep → move it, re-run |
| HID++ error `0x02` on write | Onboard mode rejects it → handled by automatic host-mode fallback |
| Receiver not found | Requires USB device with vendor `0x046D` + HID usage page `0xFF00` |
| Writes send but no replies ever arrive | If hacking on the code: IOHIDManager must outlive the device object |

## Architecture

```
Sources/HIDPP.swift           protocol core — no IOKit import (portable, testable)
Sources/Transport.swift       IOKit HID transport (the only IOKit file)
Sources/Commands.swift        CLI commands + shared UI helpers
Sources/MenuBar.swift         interactive NSStatusItem menu (opt-in resident)
Sources/SettingsWindow.swift  native AppKit settings panel (quits on close)
Sources/main.swift            argv dispatch
```

Protocol notes for G-series: battery is `0x1001` BatteryVoltage (millivolts + LiPo curve), not `0x1000`/`0x1004`. Onboard sectors are 255 B (not 16-aligned) — read the tail with an overlapping read at `sectorSize-16`.

## 中文速覽

macOS 原生、零依賴的羅技滑鼠控制工具。指令見上表。首次執行：系統設定 → 隱私權與安全性 → 輸入監控 → 授權你的終端機。所有寫入皆為 runtime（斷電回復），`nibble replay install` 登入時自動重放；`nibble menubar` 是互動選單列，`nibble ui` 是關窗即退的原生設定面板。

## License

MIT
