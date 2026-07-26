# Nibble 🖱️

Lightweight, zero-dependency Logitech mouse control for macOS. Single 516 KB binary. No daemon, no telemetry, no account.

> G HUB is a 4 GB install. Nibble is 516 KB.

## Requirements

- macOS, Swift toolchain (`xcode-select --install`)
- Logitech mouse on a USB receiver (Lightspeed/Unifying). Bluetooth-direct: not yet supported.
- Tested: G502 LIGHTSPEED via receiver `046D:C539`, HID++ 4.2

## Install

```sh
git clone https://github.com/ben0128/nibble && cd nibble
make                      # build ./nibble
sudo make install         # optional: /usr/local/bin/nibble
make app                  # optional: Nibble.app (menu bar on double-click, enables notifications)
./nibble status
```

Homebrew (from the formula in this repo):

```sh
brew install --build-from-source --formula ./Formula/nibble.rb
```

First run needs **Input Monitoring** permission: System Settings → Privacy & Security → Input Monitoring → enable your terminal app → re-run. Error `0xE00002E2` means this permission is missing. No restart needed after granting.

Button remapping additionally needs **Accessibility** permission (to synthesize keyboard/media events): the host app of `nibble menubar` prompts on first engine start.

## Commands

| Command | Effect |
|---|---|
| `nibble status` | Overview: link, battery, DPI, report rate, feature flags |
| `nibble battery` | One line, script-friendly: `50% 3.85V charging` |
| `nibble doctor` | Diagnose permissions, device, config, engine — each failure prints its fix. **Start here if anything is wrong.** |
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
| `nibble buttons` | Enumerate programmable buttons (0x1b04 MX-series / 0x8110 G-series) |
| `nibble spy [seconds]` | Live button-event monitor, G-series diagnostic; auto-stops after N seconds |
| `nibble remap` | Interactive remap: press a physical button → assign keystroke / system action / disable |
| `nibble menubar` | Interactive menu bar: battery + DPI/rate/RGB controls; hosts the remap engine (~15 MB, opt-in) |
| `Nibble.app` | Same as `nibble menubar` but launched from Finder; the bundle also enables low-battery notifications |
| `nibble ui` | Native settings window (General + Buttons tabs); quits when closed |

Debug: `NIBBLE_DEBUG=1 nibble <cmd>` prints raw HID++ packets.
Exit codes: `0` ok · `1` no awake device or value not applied · `2` transport/protocol error · `64` usage.

**For scripts and agents:** `--json` works on every read command (`status`, `battery`, `dump`, `buttons`, `onboard info`, `doctor`, `version`). Errors also emit JSON: `{"error": "...", "code": "no-awake-device"}`. `doctor --json` returns `{"ok": bool, "failed": n, "checks": [...], "nextStep": "<command or setting to fix first>"}` — the fastest path from "it doesn't work" to a concrete fix.

The UI follows the system language: English by default, Chinese when the system is set to Chinese.

## Config file `~/.config/nibble.json`

```json
{ "dpi": 1600, "reportRateHz": 1000, "rgb": "off",
  "buttonMaps": { "G502 LIGHTSPEED Wireless Gaming Mouse": {
    "G7": { "type": "keys", "keys": "cmd+space" },
    "G8": { "type": "system", "action": "mission-control" } } } }
```

| Key | Type | Values |
|---|---|---|
| `dpi` | int | 50–25600 |
| `reportRateHz` | int | 125 / 250 / 500 / 1000 |
| `rgb` | string | `"off"` or `"keep"` |
| `wheelMode` | string | `"free"` / `"ratchet"` (MX-series only) |
| `wheelThreshold` | int | 1–254 |

Omitted keys are left untouched.

## Remapping buttons

Two equivalent paths — CLI `nibble remap`, or the **Buttons** tab in `nibble ui`.

The button list is enumerated from the device itself, so any Logitech mouse populates it without per-model artwork. Click **Press to identify** and press a physical button — its row highlights. Then edit the row: record a keystroke by actually pressing it, pick a system action, or disable the button. Right-click a row to clear its mapping.

Mappings are stored per device name under `buttonMaps` and executed by the menu bar app, which watches the config file and reloads automatically when you save.

## Behavior model

- All writes are **runtime** (device RAM, persist flag = 0). A power cycle reverts the mouse to its onboard profile — `nibble replay install` re-applies your config at login.
- Report-rate and RGB writes require **host mode**; commands switch the mode flag automatically. The flag also reverts on power cycle.
- Onboard flash (HID++ feature `0x8100`) is **read-only by design**. `onboard backup` dumps every sector to `~/.config/nibble/backups/` as `.bin` + `.json` metadata — your escape hatch is restoring factory settings via G HUB on any machine.
- Button remaps are hosted by `nibble menubar` (the opt-in resident mode). G-series path: the spy-layer remap zeroes the button's standard HID output and Nibble synthesizes your action from the event stream (`0x8110`). Quitting the menu bar restores factory behavior immediately; a power cycle does too. Actions: `keys` (e.g. `cmd+shift+4`), `system` (`mission-control`, `play-pause`, `next-track`, `prev-track`, `volume-up`, `volume-down`, `mute`, `app:Name`), `disable`. G1/G2 (left/right click) are never remapped.
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
Sources/Engine.swift          remap engines (G spy / MX divert) behind one protocol
Sources/Actions.swift         keystroke + system action synthesis
Sources/MenuBar.swift         interactive NSStatusItem menu (opt-in resident)
Sources/SettingsWindow.swift  native AppKit settings panel (quits on close)
Sources/ButtonsPane.swift     Buttons tab: device-enumerated remap table
Sources/KeyRecorder.swift     press-a-key shortcut recorder
Sources/L10n.swift            bilingual strings + --json output
Sources/main.swift            argv dispatch
```

Protocol notes for G-series: battery is `0x1001` BatteryVoltage (millivolts + LiPo curve), not `0x1000`/`0x1004`. Onboard sectors are 255 B (not 16-aligned) — read the tail with an overlapping read at `sectorSize-16`.

## 中文速覽

macOS 原生、零依賴的羅技滑鼠控制工具，系統語言為中文時介面自動顯示中文。

首次執行：系統設定 → 隱私權與安全性 → 輸入監控 → 授權你的終端機。**卡住就先跑 `nibble doctor`**，它會逐項檢查權限、接收器、裝置、設定檔、改鍵引擎，並直接告訴你怎麼修。

所有寫入皆為 runtime（滑鼠斷電即回復），`nibble replay install` 會在登入時自動重放你的設定。介面有兩套：`nibble menubar` 互動選單列（同時是改鍵引擎宿主），`nibble ui` 關窗即退的原生設定面板。

## License

MIT
