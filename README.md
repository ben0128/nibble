# Nibble 🖱️

Lightweight, zero-dependency Logitech mouse control for macOS. Single binary, under 1 MB. No daemon, no telemetry, no account.

**Site:** [nibble-45j.pages.dev](https://nibble-45j.pages.dev)

> G HUB is a 4 GB install. Nibble is under 1 MB.

## Requirements

- macOS, Swift toolchain (`xcode-select --install`)
- Logitech mouse on a USB receiver (Lightspeed/Unifying), or paired directly over Bluetooth (MX-series and other BLE HID++ mice)
- Tested: G502 LIGHTSPEED via receiver `046D:C539`, HID++ 4.2. The Bluetooth-direct path is implemented per the HID++ spec but not yet verified on hardware.

## Install

```sh
git clone https://github.com/ben0128/nibble && cd nibble
make                      # build ./nibble
sudo make install         # optional: /usr/local/bin/nibble
make install-app          # optional: /Applications/Nibble.app (menu bar app + notifications)
./nibble status
```

Or via Homebrew:

```sh
brew tap ben0128/nibble
brew trust ben0128/nibble    # Homebrew requires trusting third-party taps
brew install nibble
```

First run needs **Input Monitoring** permission: System Settings → Privacy & Security → Input Monitoring → enable your terminal app → re-run. Error `0xE00002E2` means this permission is missing. No restart needed after granting.

Button remapping additionally needs **Accessibility** permission (to synthesize keyboard and media events). Grant it to whichever app hosts the engine — normally `/Applications/Nibble.app`. The engine retries on its own, so the remaps start working seconds after you flip the switch; no restart.

If remaps do nothing, run `nibble doctor` — it reports whether the engine is running and why not.

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
| `nibble startup [on\|off]` | Start the menu bar at login (needs `/Applications/Nibble.app`) |
| `nibble buttons` | Enumerate programmable buttons (0x1b04 MX-series / 0x8110 G-series) |
| `nibble spy [seconds]` | Live button-event monitor, G-series diagnostic; auto-stops after N seconds |
| `nibble remap` | Interactive remap: press a physical button → assign keystroke / system action / disable |
| `nibble profile [list\|use\|new\|copy\|rename\|delete]` | Switch between sets of button mappings |
| `nibble menubar` | Interactive menu bar: battery + DPI/rate/RGB controls; hosts the remap engine (~15 MB, opt-in) |
| `Nibble.app` | Same as `nibble menubar` but launched from Finder; the bundle also enables low-battery notifications |
| `nibble ui` | Native settings window (General + Buttons tabs); quits when closed |

Debug: `NIBBLE_DEBUG=1 nibble <cmd>` prints raw HID++ packets.
Exit codes: `0` ok · `1` no awake device or value not applied · `2` transport/protocol error · `64` usage.

**For scripts and agents:** `--json` works on every read command (`status`, `battery`, `dump`, `buttons`, `onboard info`, `doctor`, `version`). Errors also emit JSON: `{"error": "...", "code": "no-awake-device"}`. `doctor --json` returns `{"ok": bool, "failed": n, "checks": [...], "nextStep": "<command or setting to fix first>"}` — the fastest path from "it doesn't work" to a concrete fix.


## Config file `~/.config/nibble.json`

```json
{ "dpi": 1600, "reportRateHz": 1000, "rgb": "off",
  "buttonMaps": { "G502 LIGHTSPEED Wireless Gaming Mouse": {
    "G7": { "type": "keys",   "keys": "cmd+space" },
    "G8": { "type": "macro",  "keys": "cmd+c, 150ms, cmd+v" },
    "G9": { "type": "system", "action": "url:raycast://extensions/mooxl/deepcast/index" } } } }
```

| Key | Type | Values |
|---|---|---|
| `dpi` | int | 50–25600 |
| `reportRateHz` | int | 125 / 250 / 500 / 1000 |
| `rgb` | string | `"off"`, `"cycle"`, `"breathing"`, or `"keep"` |
| `wheelMode` | string | `"free"` / `"ratchet"` (MX-series only) |
| `wheelThreshold` | int | 1–254 |
| `lowBatteryNotify` | bool | `false` silences the alert; omitted means on |
| `lowBatteryPercent` | int | 5–50, default 15 — out-of-range values are clamped, not obeyed |

Omitted keys are left untouched.

## Remapping buttons

Two equivalent paths — CLI `nibble remap`, or the **Buttons** tab in `nibble ui`.

The button list is enumerated from the device itself, so any Logitech mouse populates it without per-model artwork. Click **Press to identify** and press a physical button — its row highlights. Then edit the row: record a keystroke by actually pressing it, pick a system action, or disable the button. Right-click a row to clear its mapping.

Edits are staged, not written as you type: the table shows them immediately and **Save** (bottom right, or Return) commits them in one write. Closing with unsaved edits asks first. `nibble remap` writes straight away, as a CLI should.

Mappings are stored per device name and executed by the menu bar app, which watches the config file and reloads automatically when you save.

### Profiles

A profile is a complete set of button mappings — switch one and every device changes together. The menu bar carries the list under **Remapping → Profile** so you can change sets without opening a window; the Buttons tab has the same picker plus new / duplicate / rename / delete.

```sh
nibble profile              # list, with the active one marked
nibble profile copy Gaming  # branch off the current set
nibble profile use Default
```

Config keeps them under `buttonProfiles` with `activeProfile` naming the live one. A config written by an older version — mappings directly under `buttonMaps` — is read as the `Default` profile and migrated on the first write, with the previous file kept as `nibble.json.bak`. `Default` can't be deleted, deleting the active profile falls back to it, and an `activeProfile` naming something that no longer exists resolves to `Default` rather than silently losing every mapping.

## Behavior model

- All writes are **runtime** (device RAM, persist flag = 0). A power cycle reverts the mouse to its onboard profile — `nibble replay install` re-applies your config at login.
- The **General** tab writes to the mouse as you change it. Tick *Re-apply my settings at login* and whatever you set is remembered automatically — there is no separate save step. **Save** belongs to the Buttons tab, where edits are staged — General has nothing to save, so it shows just **Close**. The one exception: staged edits keep Save reachable after you switch to General, because hiding it there would leave no way to commit them.
- Two login switches, doing different jobs: *Start Nibble at login* registers the app as a login item (`SMAppService`) so the menu bar — and therefore **button remapping** — comes back after a reboot; *Re-apply my settings at login* restores DPI, report rate and lighting to the device. Ticking the second one without the first gives you your DPI back and dead remaps.
- The **Status** rows on General report the three things every remap depends on: Input Monitoring, Accessibility, and the engine itself. Permissions are shown for whichever process hosts the engine, not for the settings window — so they stay honest when you run `nibble ui` from a terminal. `nibble doctor` prints the same checks.
- Low-battery alerts are configurable (*Notify me below N%*): one reminder per discharge cycle, reset by plugging in, delivered by the menu bar app. The status icon turns red at the same level.
- Report-rate and RGB writes require **host mode**; commands switch the mode flag automatically. The flag also reverts on power cycle.
- Onboard flash (HID++ feature `0x8100`) is **read-only by design**. `onboard backup` dumps every sector to `~/.config/nibble/backups/` as `.bin` + `.json` metadata — your escape hatch is restoring factory settings via G HUB on any machine.
- Button remaps are hosted by `nibble menubar` (the opt-in resident mode). G-series path: the spy-layer remap zeroes the button's standard HID output and Nibble synthesizes your action from the event stream (`0x8110`). Quitting the menu bar restores factory behavior immediately; a power cycle does too. Actions: `keys` (e.g. `cmd+shift+4`), `macro` (a comma-separated sequence: `cmd+c, 150ms, cmd+v` — steps are key combinations or delays in `ms`/`s`, capped at 64 steps and 30s total), `system` (`mission-control`, `play-pause`, `next-track`, `prev-track`, `volume-up`, `volume-down`, `mute`, `app:Name`, `url:<deeplink>` — e.g. `url:raycast://extensions/mooxl/deepcast/index`), `disable`.

Macros play on their own queue, so a long sequence never blocks the button that started it. Competitive games often forbid input automation — check before binding one. G1/G2 (left/right click) are never remapped.
- Zero resident processes unless you opt into `menubar`.

## Troubleshooting

| Symptom | Cause → fix |
|---|---|
| `0xE00002E2` on open | Input Monitoring not granted → grant to terminal app, re-run |
| "no awake device" | Mouse asleep → move it, re-run |
| HID++ error `0x02` on write | Onboard mode rejects it → handled by automatic host-mode fallback |
| No Logitech device found | Needs vendor `0x046D` with HID usage page `0xFF00` (receiver) or `0xFF43` (Bluetooth-direct) |
| Writes send but no replies ever arrive | If hacking on the code: IOHIDManager must outlive the device object |

## Tests

```sh
make test
```

Covers the pure layer — HID++ request framing and response matching, error decoding, the battery feature fallback chain, key and macro parsing with their limits, config encoding, and button-map key parsing. No mouse required; a mock transport stands in for the device. Hardware I/O, TCC permissions and AppKit layout are deliberately out of scope — those are verified against a real device.

No XCTest: it would pull in SwiftPM and its build directories, which this project deliberately avoids. `Tests/main.swift` is a plain executable with a 20-line assert helper.

## Development

`make app` signs the bundle with a self-signed identity named `Nibble Dev` if one exists in your keychain, falling back to ad-hoc. Either way, **expect to re-grant Accessibility after rebuilding the app**: macOS binds the grant to the cdhash for any certificate it cannot chain to a trusted root, and a self-signed certificate is not one. Only a Developer ID certificate makes the grant survive rebuilds. The self-signed identity is still worth having — it produces a proper sealed bundle rather than an ad-hoc one — and is created like this:

```sh
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout /tmp/ns.key -out /tmp/ns.crt -days 3650 -nodes \
  -subj "/CN=Nibble Dev" -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
/usr/bin/openssl pkcs12 -export -out /tmp/ns.p12 -inkey /tmp/ns.key -in /tmp/ns.crt -passout pass:nibble -name "Nibble Dev"
security import /tmp/ns.p12 -k ~/Library/Keychains/login.keychain-db -P nibble -T /usr/bin/codesign -A
```

Two traps worth knowing when packaging: a `com.apple.FinderInfo` xattr makes `codesign` refuse to seal the bundle — it signs only the inner binary and reports `Identifier=nibble` instead of the bundle id — and `cp -R` breaks the seal where `ditto` preserves it. The Makefile handles both.

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
Sources/LoginItem.swift       login item registration (SMAppService)
Sources/L10n.swift            --json output + machine-readable errors
Sources/main.swift            argv dispatch
```

Protocol notes for G-series: battery is `0x1001` BatteryVoltage (millivolts + LiPo curve), not `0x1000`/`0x1004`. Onboard sectors are 255 B (not 16-aligned) — read the tail with an overlapping read at `sectorSize-16`.

## License

MIT
