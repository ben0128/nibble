// L10n.swift — machine-readable output helpers + lightweight AppKit localization.
// English defaults live here so a standalone CLI binary stays readable; the
// bundled zh-Hans table is used only when the user prefers it.
import Foundation

/// `--json`: read commands emit machine-readable output for scripts and agents.
var jsonMode = false

func emitJSON(_ obj: [String: Any]) {
    let data = try? JSONSerialization.data(withJSONObject: obj,
                                           options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}")
}

/// Errors are machine-readable too: {"error":…,"code":…} in JSON mode, plain text otherwise.
func emitError(_ message: String, code: String) {
    if jsonMode { emitJSON(["error": message, "code": code]) } else { print("❌ \(message)") }
}

// MARK: - Localization

private var l10nCache: [String: String]?
private let l10nQueue = DispatchQueue(label: "com.ben0128.nibble.l10n")

private let englishStrings: [String: String] = [
    "app.name": "Nibble",
    "common.cancel": "Cancel",
    "common.ok": "OK",
    "common.save": "Save",
    "common.delete": "Delete",
    "common.ready": "Ready",
    "common.disabled": "disabled",
    "common.default": "default",
    "common.button": "button",
    "common.action": "action",
    "common.profile": "Profile",
    "common.granted": "granted",
    "common.off": "Off",
    "common.cycle": "Cycle",
    "common.breathing": "Breathing",
    "common.charging": "charging",
    "common.discharging": "discharging",
    "common.custom": "Custom",
    "settings.general": "General",
    "settings.buttons": "Buttons",
    "settings.detecting": "Detecting…",
    "settings.checking": "checking…",
    "settings.reapply": "Re-apply my settings at login",
    "settings.start.login": "Start Nibble at login",
    "settings.notify.below": "Notify me below",
    "settings.open": "Open Settings…",
    "settings.start.nibble": "Start Nibble",
    "settings.close": "Close",
    "settings.section.status": "Status",
    "settings.section.dpi": "DPI",
    "settings.section.rate": "Report rate (Hz)",
    "settings.section.lighting": "Lighting",
    "settings.health.input.monitoring": "Input Monitoring",
    "settings.health.accessibility": "Accessibility",
    "settings.health.engine": "Remap engine",
    "settings.device.offline": "Mouse offline or asleep",
    "settings.battery.reopen": "Move the mouse, then reopen this panel",
    "settings.saved.login": "Settings will be re-applied at login ✓",
    "settings.saved.login.off": "Login re-apply turned off",
    "settings.status.dpi": "DPI → %1$d ✓",
    "settings.status.dpi.mismatch": "⚠️ asked %1$d, device reports %2$d",
    "settings.status.rate": "Report rate → %1$d Hz ✓",
    "settings.status.rate.mismatch": "⚠️ asked %1$d, device reports %2$d",
    "settings.status.lighting": "Lighting → %@ ✓",
    "settings.status.effect.unavailable": "⚠️ effect not available on this device",
    "settings.status.dpi.invalid": "⚠️ DPI must be a number between 50 and 25600",
    "settings.status.range.only": "⚠️ %1$d–%2$d%% only — using %3$d%%",
    "settings.status.lowbattery.at": "Low-battery alert at %1$d%% ✓",
    "settings.status.lowbattery.off": "Low-battery alerts off",
    "settings.status.startup.on": "Nibble will start at login ✓",
    "settings.status.startup.removed": "Login item removed",
    "settings.status.startup.blocked": "Registered, but macOS is blocking it — enable Nibble in System Settings › General › Login Items",
    "settings.status.replay.saved": "Saved as default ✓ replayed at login",
    "settings.status.menubar.starting": "Menu bar starting…",
    "settings.status.lowbattery": "🔋 %1$d%% · %2$@",
    "settings.status.battery.charging": "charging",
    "settings.status.battery.discharging": "discharging",
    "settings.save.pending": "Save %1$d button changes?",
    "settings.save.pending.detail": "They haven't been written to the config yet.",
    "settings.save.discard": "Discard",
    "settings.health.not.granted": "not granted — Nibble can't read the mouse",
    "settings.health.ax.not.granted": "not granted — remapped buttons stay silent",
    "settings.health.menu.bar.not.reported": "the menu bar hasn't reported yet",
    "settings.health.menu.bar.unknown": "unknown — the menu bar isn't running to report it",
    "settings.health.menu.bar.off": "menu bar not running",
    "settings.health.menu.bar.remaps.off": "menu bar not running — your %1$d remaps are off",
    "settings.health.engine.running": "running · %1$d mappings",
    "settings.health.engine.reason.none": "no mappings configured",
    "settings.health.engine.reason.none.for": "no mappings for %@",
    "settings.health.engine.reason.ax": "Accessibility permission not granted",
    "settings.health.engine.reason.disconnected": "device disconnected — waiting for reconnect",
    "settings.health.engine.reason.paused": "paused by user",
    "settings.health.engine.reason.running": "running",
    "settings.device.notfound": "⚠️ /Applications/Nibble.app not found — run `make install-app`",
    "settings.tooltip.lighting": "Written to the device immediately. The mouse has no way to report its current effect back, so Nibble shows the last one it applied.",
    "settings.tooltip.rate": "Higher rates poll more often — smoother tracking, slightly more battery. Writing this requires host mode; Nibble switches automatically.",
    "settings.tooltip.replay": "Installs a one-shot launchd agent that runs `nibble apply` at login. It exits immediately after — nothing stays resident.",
    "settings.tooltip.dpi.custom": "Any value the sensor accepts. A DPI set with the mouse's own buttons shows up here when it isn't one of the presets.",
    "settings.tooltip.startup": "Keeps the menu bar running, which is what executes your button remaps. Without it, a reboot leaves the remaps dead — the login re-apply below only restores DPI, rate and lighting.",
    "settings.tooltip.engine": "Launches /Applications/Nibble.app — the menu bar hosts the remap engine.",
    "settings.tooltip.save": "Write the pending button changes to the config file. The menu bar reloads the engine after that.",
    "settings.tooltip.rate.supported": "This device supports %1$@ Hz. Writing the rate requires host mode; Nibble switches automatically.",
    "settings.help.startup": "Button remapping only works while the Nibble menu bar is running. This registers it as a login item so it comes back after a reboot.",
    "settings.help.replay": "Everything on this tab is written to the mouse immediately, and lost when it powers off — the mouse falls back to its onboard profile. With this ticked, whatever you set here is remembered and re-applied at login; there's nothing to save by hand.",
    "settings.help.notify": "Delivered by the menu bar app, so it needs that running too. You get one reminder per discharge cycle — plugging in resets it. The menu bar icon turns red at the same level.",
    "settings.help.status": "The three things every remap depends on. Input Monitoring lets Nibble read the mouse; Accessibility lets it synthesize your keystrokes; the engine lives in the menu bar app. Permissions are reported for whichever process hosts the engine — `nibble doctor` prints the same checks.",
    "settings.help.lighting": "Lighting can't be read back from the mouse — Nibble shows the last effect it applied. A power cycle returns the mouse to its onboard profile.",

    "buttons.identify": "Press to identify",
    "buttons.identify.stop": "⏹ Stop",
    "buttons.none.selected": "No button selected",
    "buttons.type.keys": "Keys",
    "buttons.type.macro": "Macro",
    "buttons.type.system": "System",
    "buttons.type.disable": "Disable",
    "buttons.type.default": "Default",
    "buttons.clear.mapping": "Clear mapping",
    "buttons.profile.new": "New profile…",
    "buttons.profile.duplicate": "Duplicate this profile…",
    "buttons.profile.rename": "Rename…",
    "buttons.profile.delete": "Delete",
    "buttons.new.profile.name": "Name for the new profile",
    "buttons.copy.profile.name": "Name for the copy of %@",
    "buttons.rename.profile.to": "Rename %@ to",
    "buttons.created.profile": "Created %@ — it starts empty",
    "buttons.created.profile.from": "Created %1$@ from %2$@",
    "buttons.renamed.profile": "Renamed to %@",
    "buttons.delete.profile.title": "Delete the %@ profile?",
    "buttons.delete.profile.detail": "Its button mappings go with it. Other profiles are untouched.",
    "buttons.deleted.profile": "Deleted %@",
    "buttons.profile.switched": "Profile: %@",
    "buttons.profile.discarded": "Profile: %1$@ · discarded %2$d unsaved button changes",
    "buttons.device.summary": "%1$@ · %2$d buttons",
    "buttons.saved.changes": "Saved %1$d changes — the menu bar reloads the engine",
    "buttons.save.failed": "❌ save failed: %@",
    "buttons.discarded.changes": "Discarded unsaved changes",
    "buttons.stage.not.saved": "%1$@ → %2$@ · not saved yet",
    "buttons.error.macro": "⚠️ Can't read that macro — steps are key combos or delays (150ms), max 64 steps / 30s",
    "buttons.primary.note": "Primary buttons stay untouched so the mouse can never lock you out.",
    "buttons.note.select": "Select a row, or use Press to identify and press the physical button.",
    "buttons.note.keys": "Click the field and press the combination. Esc clears it.",
    "buttons.note.macro": "Steps separated by commas — key combos and delays like 150ms.",
    "buttons.note.system": "Pick a system action, or type an app name / deeplink to open.",
    "buttons.note.disable": "The button will do nothing at all.",
    "buttons.note.default": "The mouse handles this button itself.",
    "buttons.identify.press.mouse": "Press a mouse button (wheel scrolling is not a button)",
    "buttons.identify.inert": "Press a mouse button (buttons are inert while identifying)",
    "buttons.identify.unsupported": "This device does not support identify",
    "buttons.identify.stopped": "Identify stopped",
    "buttons.identify.bit.beyond": "Got bit %1$d — beyond the button count",
    "buttons.identify.detected.bit": "Detected %1$@ · bit %2$d",
    "buttons.identify.detected": "Detected %@",
    "buttons.action.system": "(system)",
    "buttons.tooltip.profile": "Each profile is its own set of button mappings. Switching one takes effect immediately — the menu bar has the same list.",
    "buttons.tooltip.identify": "Press a physical mouse button and its row is selected. Wheel scrolling isn't a button; the wheel click and tilts are.",
    "buttons.tooltip.table": "Right-click a row to clear its mapping. G1/G2 (left/right click) can't be remapped so the mouse can never lock you out.",
    "buttons.help.staged": "Edits are staged, not written as you go — press Save (or Return) to commit them, and the menu bar reloads the remap engine. Right-click a row to clear it. G1/G2 stay untouched so the mouse can never lock you out.",
    "buttons.tooltip.recorder": "Click here, then press the combination you want. Esc clears it.",
    "buttons.tooltip.types": "Keystroke sends one combination · Macro plays a sequence · System runs a built-in action, app or deeplink · Disable makes the button inert · Default hands it back to the mouse",
    "buttons.tooltip.macro": "Comma-separated steps. Each step is a key combination or a delay (150ms, 1.5s). Max 64 steps, 30s total.",
    "buttons.tooltip.app": "An app name (Safari) launches it. Anything containing :// is opened as a deeplink — raycast://extensions/…, obsidian://…, shortcuts://…",

    "key.recorder.press": "Press a key combination…",
    "key.recorder.click": "Click here, then press a key combination",

    "menubar.detecting": "Detecting…",
    "menubar.already.running": "Nibble menu bar is already running.",
    "menubar.permission.required": "⚠️ Input Monitoring required",
    "menubar.open.system.settings": "Open System Settings…",
    "menubar.dpi": "DPI",
    "menubar.report.rate": "Report rate",
    "menubar.lighting": "Lighting",
    "menubar.remapping": "Remapping",
    "menubar.pause.remapping": "Pause remapping",
    "menubar.resume.remapping": "Resume remapping",
    "menubar.edit.buttons": "Edit buttons…",
    "menubar.settings": "Settings…",
    "menubar.save.current.settings": "Save current settings",
    "menubar.refresh.now": "Refresh now",
    "menubar.quit": "Quit (mouse keeps working)",
    "menubar.edit.profiles": "Edit profiles…",
    "menubar.paused": "paused",
    "menubar.paused.full": "Paused — buttons behave normally",
    "menubar.none.configured": "Remapping: none configured",
    "menubar.none.for.device": "Remapping: %1$@ has no mappings",
    "menubar.needs.accessibility": "Remapping: ⚠️ needs Accessibility — click here",
    "menubar.unsupported.device": "Remapping: unsupported device",
    "menubar.device.disconnected": "Remapping: device disconnected — will retry",
    "menubar.active.count": "Remapping: ✓ %1$d active",
    "menubar.error": "Remapping: ❌ %@",
    "menubar.active": "%1$d active",
    "menubar.none": "none",
    "menubar.not.running": "⚠️ not running",
    "menubar.input.permission.title": "Nibble can't read your mouse",
    "menubar.input.permission.detail": "Grant Input Monitoring, then Refresh",
    "menubar.mouse.asleep": "Mouse asleep",
    "menubar.mouse.asleep.detail": "Move it to wake — values below are hidden until then",
    "menubar.mouse.offline": "Mouse offline",
    "menubar.offline.tooltip": "Nibble — mouse offline or asleep",
    "menubar.permission.tooltip": "Nibble — Input Monitoring permission required",
    "menubar.error.tooltip": "Nibble — %@",
    "menubar.status.dpi": "DPI → %1$d ✓",
    "menubar.status.dpi.mismatch": "⚠️ asked %1$d, device reports %2$d",
    "menubar.status.rate": "Report rate → %1$d Hz ✓",
    "menubar.status.rate.mismatch": "⚠️ asked %1$d, device reports %2$d",
    "menubar.status.rgb": "RGB → %1$@ ✓",
    "menubar.status.rgb.unavailable": "⚠️ effect not available on this device",
    "menubar.saved.default": "Saved as default ✓ replayed at login",
    "menubar.battery.title": "%1$@ at %2$d%%",
    "menubar.battery.body": "Time to charge 🔌",
]

private func loadLocalizedStrings() -> [String: String] {
    if let cached = l10nCache { return cached }
    let loaded = l10nQueue.sync { () -> [String: String] in
        if let cached = l10nCache { return cached }

        // Bundle preferredLocalizations resolves AppleLanguages against the
        // declared localizations; it returns English unless zh-Hans is preferred.
        let localization = Bundle.preferredLocalizations(
            from: ["en", "zh-Hans"],
            forPreferences: nil
        ).first ?? "en"
        guard localization == "zh-Hans",
              let url = Bundle.main.url(forResource: "Localizable",
                                        withExtension: "strings",
                                        subdirectory: nil,
                                        localization: "zh-Hans"),
              let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: String] else { return [:] }
        l10nCache = value
        return value
    }
    return loaded
}

func localized(_ key: String) -> String {
    let table = loadLocalizedStrings()
    if let localizedString = table[key] { return localizedString }
    return englishStrings[key] ?? key
}

/// Localizes UI-facing device battery labels without touching JSON/doctor.
func localizedBatteryLabel(percent: Int, voltage: String, charging: Bool) -> String {
    let state = localized(charging ? "settings.status.battery.charging"
                                   : "settings.status.battery.discharging")
    return String(format: localized("settings.status.lowbattery"), percent, state) + voltage
}

/// Engine state files deliberately carry stable English reasons for doctor/JSON;
/// translate the known user-facing ones while leaving unexpected errors intact.
func localizedEngineState(_ reason: String) -> String {
    switch reason {
    case "no mappings configured":
        return localized("settings.health.engine.reason.none")
    case "Accessibility permission not granted":
        return localized("settings.health.engine.reason.ax")
    case "device disconnected — waiting for reconnect":
        return localized("settings.health.engine.reason.disconnected")
    case "paused by user":
        return localized("settings.health.engine.reason.paused")
    case "running":
        return localized("settings.health.engine.reason.running")
    case let value where value.hasPrefix("no mappings for "):
        let device = String(value.dropFirst("no mappings for ".count))
        return String(format: localized("settings.health.engine.reason.none.for"), device)
    default:
        return reason
    }
}
