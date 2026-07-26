// KeyRecorder.swift — 真・快捷鍵錄製：按下什麼就記什麼，不必手打 "cmd+shift+4"
import AppKit

/// keyCode → 名稱（nibbleKeyCodes 的反查表）
let nibbleKeyNames: [CGKeyCode: String] = {
    var out: [CGKeyCode: String] = [:]
    for (name, code) in nibbleKeyCodes where out[code] == nil || name.count < out[code]!.count {
        out[code] = name
    }
    return out
}()

final class KeyRecorderView: NSView {
    var combo: String? { didSet { needsDisplay = true; onChange?(combo) } }
    var onChange: ((String?) -> Void)?
    private var recording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 26) }

    override func becomeFirstResponder() -> Bool { recording = true; needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { recording = false; needsDisplay = true; return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func draw(_ dirtyRect: NSRect) {
        let bg = recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()

        let text = combo.map(prettify)
            ?? (recording ? "Press a key combination…"
                          : "Click here, then press a key combination")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: combo == nil ? .regular : .medium),
            .foregroundColor: combo == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    /// "cmd+shift+4" → "⌘⇧4"，讓使用者確認自己按對了
    private func prettify(_ c: String) -> String {
        var out = ""
        var key = ""
        for part in c.split(separator: "+").map(String.init) {
            switch part {
            case "ctrl": out += "⌃"
            case "alt": out += "⌥"
            case "shift": out += "⇧"
            case "cmd": out += "⌘"
            case "fn": out += "fn"
            default: key = part
            }
        }
        return out + key.uppercased()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { combo = nil; return }   // Esc 清除
        var parts: [String] = []
        let f = event.modifierFlags
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("alt") }
        if f.contains(.shift) { parts.append("shift") }
        if f.contains(.command) { parts.append("cmd") }
        guard let name = nibbleKeyNames[event.keyCode] else {
            NSSound.beep()   // 沒對應名稱的鍵不能存進 config
            return
        }
        parts.append(name)
        combo = parts.joined(separator: "+")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 錄製中要攔下 ⌘Q/⌘W 這類系統快捷鍵，否則使用者一按就把視窗關了
        guard recording, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }
}
