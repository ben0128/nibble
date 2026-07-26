// Actions.swift — 動作合成器：快捷鍵（CGEvent）＋系統動作（媒體鍵/Mission Control/開 App）
// 需要「輔助使用（Accessibility）」TCC 權限才能合成事件。
import AppKit

struct ButtonAction: Codable {
    var type: String       // "keys" | "system" | "disable"
    var keys: String?      // 例 "cmd+shift+4"、"f13"、"ctrl+left"
    var action: String?    // SystemAction rawValue 或 "app:AppName"
}

enum SystemAction: String, CaseIterable {
    case missionControl = "mission-control"
    case playPause = "play-pause"
    case nextTrack = "next-track"
    case prevTrack = "prev-track"
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
    case mute = "mute"
}

/// macOS 虛擬鍵碼（ANSI 佈局標準值）
let nibbleKeyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
    "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
]

/// 解析 "cmd+shift+4" → (修飾鍵, 鍵碼)；解析失敗回 nil
func parseCombo(_ combo: String) -> (CGEventFlags, CGKeyCode)? {
    var flags: CGEventFlags = []
    var key: CGKeyCode?
    for part in combo.lowercased().split(separator: "+").map(String.init) {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "opt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        default:
            guard let k = nibbleKeyCodes[part] else { return nil }
            key = k
        }
    }
    guard let k = key else { return nil }
    return (flags, k)
}

@discardableResult
func postKeystroke(_ combo: String) -> Bool {
    guard let (flags, key) = parseCombo(combo),
          let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
}

/// 媒體鍵走 NX systemDefined 事件（CGEvent 沒有這一層）
func postMediaKey(_ nxKey: Int) {
    for down in [true, false] {
        let stateFlag = down ? 0xa00 : 0xb00
        if let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                      modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(stateFlag)),
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: 0, context: nil, subtype: 8,
                                      data1: (nxKey << 16) | stateFlag, data2: -1) {
            e.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

@discardableResult
func performSystem(_ raw: String) -> Bool {
    if raw.hasPrefix("app:") {
        sh(["/usr/bin/open", "-a", String(raw.dropFirst(4))])
        return true
    }
    switch SystemAction(rawValue: raw) {
    case .missionControl: sh(["/usr/bin/open", "-a", "Mission Control"]); return true
    case .playPause: postMediaKey(16); return true    // NX_KEYTYPE_PLAY
    case .nextTrack: postMediaKey(17); return true
    case .prevTrack: postMediaKey(18); return true
    case .volumeUp: postMediaKey(0); return true
    case .volumeDown: postMediaKey(1); return true
    case .mute: postMediaKey(7); return true
    case .none: return false
    }
}

func performButtonAction(_ a: ButtonAction) {
    switch a.type {
    case "keys": if let k = a.keys { postKeystroke(k) }
    case "system": if let s = a.action { performSystem(s) }
    default: break   // "disable"：吞掉事件
    }
}

/// 輔助使用權限檢查；promptIfNeeded 會觸發系統授權對話框
func axTrusted(promptIfNeeded: Bool = false) -> Bool {
    if promptIfNeeded {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
    return AXIsProcessTrusted()
}
