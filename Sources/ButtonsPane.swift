// ButtonsPane.swift — 改鍵 UI（設定面板的 Buttons 分頁）
// 不畫滑鼠：按鍵清單由裝置自我列舉（0x8110 G 系 / 0x1b04 MX 系）。
// 版面 = 左清單 ／ 右即時編輯面板：選一列右邊就能改，改完立刻寫檔，不開彈窗、不用按儲存。
// 定位靠 press-to-identify——按實體鍵，對應列自動選取，接著右邊直接錄快捷鍵。
import AppKit

struct ButtonRow {
    let index: Int          // 0-based 鍵序（G(index+1)）
    let name: String
    let remappable: Bool
    var cid: UInt16? = nil  // MX 路徑用（G 系為 nil）
    var action: ButtonAction?
}

final class ButtonsPane: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onStatus: ((String) -> Void)?

    private let table = NSTableView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let learnButton = NSButton(title: "Press to identify", target: nil, action: nil)

    // 右側編輯面板
    private let editorTitle = NSTextField(labelWithString: "No button selected")
    private let typeControl = NSSegmentedControl(labels: ["Keystroke", "Macro", "System", "Disable", "Default"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let macroField = NSTextField(string: "")
    private let recorder = KeyRecorderView(frame: .zero)
    private let systemPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let appField = NSTextField(string: "")
    private let editorNote = NSTextField(labelWithString: "")
    private var editorControls: [NSView] = []

    private var rows: [ButtonRow] = []
    private var deviceName = "unknown"
    private var learning = false
    private var highlighted: Int?
    private var spyDev: HIDPPDevice?
    private var spyTransport: ReceiverTransport?
    private var spyIdx: UInt8 = 0
    private var prevMask: UInt16 = 0
    private var divertedForLearn: [UInt16] = []
    private var suppressEditorApply = false   // 載入既有設定時不要反過來觸發寫檔

    /// spy 事件 bitmask 的 bit → 列序。位序若被實測推翻，只改這裡。
    static func bitToRow(_ bit: Int) -> Int { bit }

    // MARK: 版面

    func makeView() -> NSView {
        table.addTableColumn(withTitle("button", "col-btn", 78))
        table.addTableColumn(withTitle("action", "col-act", 150))
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.target = self

        let ctx = NSMenu()
        let clearItem = NSMenuItem(title: "Clear mapping", action: #selector(clearSelected), keyEquivalent: "")
        clearItem.target = self
        ctx.addItem(clearItem)
        table.menu = ctx

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

        learnButton.target = self
        learnButton.action = #selector(toggleLearn)
        learnButton.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.usesSingleLineMode = true
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.stringValue = "Changes apply instantly"
        hintLabel.toolTip = "Saved to ~/.config/nibble.json. The menu bar app watches that file and reloads the engine, so edits take effect without restarting anything."
        learnButton.toolTip = "Press a physical mouse button and its row is selected. Wheel scrolling isn't a button; the wheel click and tilts are."
        table.toolTip = "Right-click a row to clear its mapping. G1/G2 (left/right click) can't be remapped so the mouse can never lock you out."
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let editor = makeEditor()
        editor.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        for v in [scroll, learnButton, hintLabel, editor] { container.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            scroll.widthAnchor.constraint(equalToConstant: 236),

            learnButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            learnButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),

            hintLabel.topAnchor.constraint(equalTo: learnButton.bottomAnchor, constant: 8),
            hintLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            hintLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            editor.topAnchor.constraint(equalTo: scroll.topAnchor),
            editor.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 16),
            editor.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            editor.bottomAnchor.constraint(lessThanOrEqualTo: learnButton.bottomAnchor),
        ])
        updateEditor()
        return container
    }

    private func makeEditor() -> NSView {
        editorTitle.font = .boldSystemFont(ofSize: 13)

        typeControl.target = self
        typeControl.action = #selector(typeChanged)
        typeControl.segmentDistribution = .fillEqually

        recorder.onChange = { [weak self] _ in self?.applyEditor() }
        recorder.toolTip = "Click here, then press the combination you want. Esc clears it."
        typeControl.toolTip = "Keystroke sends one combination · Macro plays a sequence · System runs a built-in action, app or deeplink · Disable makes the button inert · Default hands it back to the mouse"
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.heightAnchor.constraint(equalToConstant: 30).isActive = true

        macroField.placeholderString = "cmd+c, 150ms, cmd+v"
        macroField.target = self
        macroField.action = #selector(applyEditor)
        macroField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        macroField.toolTip = "Comma-separated steps. Each step is a key combination or a delay (150ms, 1.5s). Max 64 steps, 30s total."

        systemPopup.addItems(withTitles: SystemAction.allCases.map(\.rawValue))
        systemPopup.target = self
        systemPopup.action = #selector(applyEditor)

        appField.placeholderString = "app name or deeplink"
        appField.toolTip = "An app name (Safari) launches it. Anything containing :// is opened as a deeplink — raycast://extensions/…, obsidian://…, shortcuts://…"
        appField.target = self
        appField.action = #selector(appFieldCommitted)
        appField.font = .systemFont(ofSize: 12)

        editorNote.font = .systemFont(ofSize: 11)
        editorNote.textColor = .secondaryLabelColor
        editorNote.lineBreakMode = .byWordWrapping
        editorNote.maximumNumberOfLines = 3
        editorNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        editorControls = [typeControl, recorder, macroField, systemPopup, appField]

        let stack = NSStackView(views: [editorTitle, typeControl, recorder, macroField, systemPopup, appField, editorNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for v in [typeControl, recorder, macroField, systemPopup, appField] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        editorNote.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func withTitle(_ title: String, _ id: String, _ width: CGFloat) -> NSTableColumn {
        let c = NSTableColumn(identifier: .init(id))
        c.title = title
        c.width = width
        return c
    }

    // MARK: 資料

    func reload() {
        do {
            let (dev, _) = try uiOpenDevice(preferred: 1)
            deviceName = (try? dev.name()) ?? "unknown"
            let saved = loadConfig()?.buttonMaps?[deviceName] ?? [:]
            var out: [ButtonRow] = []
            if dev.has(0x8110) {
                let n = try dev.buttonSpyCount()
                for i in 0..<n {
                    out.append(ButtonRow(index: i, name: "G\(i + 1)" + (i == 0 ? " (left)" : i == 1 ? " (right)" : ""),
                                         remappable: i >= 2, action: saved["G\(i + 1)"]))
                }
            } else if dev.has(0x1b04) {
                for (i, c) in (try dev.controls()).enumerated() {
                    let nm = HIDPP.cidNames[c.cid] ?? String(format: "CID 0x%04X", c.cid)
                    out.append(ButtonRow(index: i, name: nm, remappable: c.divertable, cid: c.cid, action: saved[nm]))
                }
            }
            rows = out
            table.reloadData()
            updateEditor()
            onStatus?("\(deviceName) · \(rows.count) buttons")
        } catch {
            rows = []
            table.reloadData()
            updateEditor()
            onStatus?("❌ \(error)")
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let text: String
        if tableColumn?.identifier.rawValue == "col-btn" {
            text = (highlighted == row ? "▶ " : "") + r.name
        } else if let a = r.action {
            switch a.type {
            case "keys": text = "⌨ \(a.keys ?? "")"
            case "macro": text = "⏩ \(a.keys ?? "")"
            case "system": text = "⚙ \(a.action ?? "")"
            default: text = "🚫 disabled"
            }
        } else {
            text = r.remappable ? "—" : "(system)"
        }
        let label = NSTextField(labelWithString: text)
        label.font = highlighted == row ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        if highlighted == row { label.textColor = .controlAccentColor }
        else if !r.remappable { label.textColor = .tertiaryLabelColor }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateEditor() }

    // MARK: 右側編輯面板（即時套用）

    private var selectedRow: Int? {
        let s = table.selectedRow
        return (s >= 0 && s < rows.count) ? s : nil
    }

    private func setEditorEnabled(_ on: Bool) {
        for v in editorControls { (v as? NSControl)?.isEnabled = on }
    }

    private func updateEditor() {
        suppressEditorApply = true
        defer { suppressEditorApply = false }

        guard let i = selectedRow else {
            editorTitle.stringValue = "No button selected"
            editorNote.stringValue = "Select a row, or use Press to identify and press the physical button."
            setEditorEnabled(false)
            recorder.isHidden = true
            systemPopup.isHidden = true
            appField.isHidden = true
            return
        }
        let r = rows[i]
        editorTitle.stringValue = r.name
        guard r.remappable else {
            editorNote.stringValue = "Primary buttons stay untouched so the mouse can never lock you out."
            setEditorEnabled(false)
            recorder.isHidden = true
            systemPopup.isHidden = true
            appField.isHidden = true
            return
        }
        setEditorEnabled(true)

        switch r.action?.type {
        case "keys":
            typeControl.selectedSegment = 0
            recorder.combo = r.action?.keys
        case "macro":
            typeControl.selectedSegment = 1
            macroField.stringValue = r.action?.keys ?? ""
        case "system":
            typeControl.selectedSegment = 2
            let a = r.action?.action ?? ""
            if a.hasPrefix("app:") || a.hasPrefix("url:") { appField.stringValue = String(a.dropFirst(4)) }
            else { systemPopup.selectItem(withTitle: a) }
        case "disable":
            typeControl.selectedSegment = 3
        default:
            typeControl.selectedSegment = 4
            recorder.combo = nil
        }
        syncEditorVisibility()
    }

    private func syncEditorVisibility() {
        let idx = typeControl.selectedSegment
        recorder.isHidden = idx != 0
        macroField.isHidden = idx != 1
        systemPopup.isHidden = idx != 2
        appField.isHidden = idx != 2
        switch idx {
        case 0: editorNote.stringValue = "Click the field and press the combination. Esc clears it."
        case 1: editorNote.stringValue = "Steps separated by commas — key combos and delays like 150ms."
        case 2: editorNote.stringValue = "Pick a system action, or type an app name / deeplink to open."
        case 3: editorNote.stringValue = "The button will do nothing at all."
        default: editorNote.stringValue = "The mouse handles this button itself."
        }
    }

    @objc private func typeChanged() {
        syncEditorVisibility()
        if typeControl.selectedSegment == 0 { window?.makeFirstResponder(recorder) }
        applyEditor()
    }

    private var window: NSWindow? { table.window }

    @objc private func appFieldCommitted() { applyEditor() }

    /// 每次改動立刻寫檔——選單列監看設定檔，會自動重載引擎
    @objc private func applyEditor() {
        guard !suppressEditorApply, let i = selectedRow, rows[i].remappable else { return }
        var action: ButtonAction?
        switch typeControl.selectedSegment {
        case 0:
            guard let combo = recorder.combo, parseCombo(combo) != nil else { return }   // 還沒錄到就先不寫
            action = ButtonAction(type: "keys", keys: combo, action: nil)
        case 1:
            let seq = macroField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !seq.isEmpty else { return }
            guard parseMacro(seq) != nil else {
                onStatus?("⚠️ Can't read that macro — steps are key combos or delays (150ms), max 64 steps / 30s")
                return
            }
            action = ButtonAction(type: "macro", keys: seq, action: nil)
        case 2:
            let entry = appField.stringValue.trimmingCharacters(in: .whitespaces)
            let custom = entry.contains("://") ? "url:\(entry)" : "app:\(entry)"
            action = ButtonAction(type: "system", keys: nil,
                                  action: entry.isEmpty ? systemPopup.titleOfSelectedItem : custom)
        case 3:
            action = ButtonAction(type: "disable", keys: nil, action: nil)
        default:
            action = nil
        }
        save(action, for: i)
    }

    @objc private func clearSelected() {
        let sel = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard sel >= 0, sel < rows.count, rows[sel].action != nil else { return }
        save(nil, for: sel)
        updateEditor()
    }

    private func save(_ action: ButtonAction?, for rowIndex: Int) {
        var cfg = loadConfig() ?? BMConfig()
        var maps = cfg.buttonMaps ?? [:]
        var devMap = maps[deviceName] ?? [:]
        let key = rows[rowIndex].name.components(separatedBy: " ").first ?? rows[rowIndex].name
        if let action { devMap[key] = action } else { devMap.removeValue(forKey: key) }
        maps[deviceName] = devMap.isEmpty ? nil : devMap
        cfg.buttonMaps = maps
        do {
            try saveConfig(cfg)
            rows[rowIndex].action = action
            table.reloadData()
            table.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
            let desc = action.map {
                switch $0.type {
                case "keys", "macro": return $0.keys ?? ""
                case "system": return $0.action ?? ""
                default: return "disabled"
                }
            } ?? "default"
            onStatus?("\(key) → \(desc) · applied")
        } catch {
            onStatus?("❌ save failed: \(error)")
        }
    }

    // MARK: press-to-identify

    @objc private func toggleLearn() { learning ? stopLearn() : startLearn() }

    private func startLearn() {
        do {
            let (dev, _) = try uiOpenDevice(preferred: 1)
            guard let tr = dev.transport as? ReceiverTransport else { return }
            if dev.has(0x8110), let idx = try dev.featureIndex(of: 0x8110) {
                spyIdx = idx
                prevMask = 0
                try dev.buttonSpyStart()
                tr.onReport = { [weak self] p in self?.handleSpy(p) }
                onStatus?("Press a mouse button (wheel scrolling is not a button)")
            } else if dev.has(0x1b04), let fi = try dev.featureIndex(of: 0x1b04) {
                // MX 路徑：暫時 divert 所有可 divert 的鍵來聽事件，停止時全部還原
                spyIdx = fi
                divertedForLearn = (try dev.controls()).filter(\.divertable).map(\.cid)
                for cid in divertedForLearn { try? dev.setDivert(cid: cid, on: true) }
                tr.onReport = { [weak self] p in self?.handleDivertedEvent(p) }
                onStatus?("Press a mouse button (buttons are inert while identifying)")
            } else {
                onStatus?("This device does not support identify")
                return
            }
            spyDev = dev
            spyTransport = tr
            learning = true
            learnButton.title = "⏹ Stop"
        } catch {
            onStatus?("❌ \(error)")
        }
    }

    private func stopLearn() {
        spyTransport?.onReport = nil
        if let dev = spyDev {
            if dev.has(0x8110) { try? dev.buttonSpyStop() }
            for cid in divertedForLearn { try? dev.setDivert(cid: cid, on: false) }
        }
        divertedForLearn = []
        spyDev = nil
        spyTransport = nil
        learning = false
        learnButton.title = "Press to identify"
        onStatus?("Identify stopped")
    }

    func teardown() { if learning { stopLearn() } }

    private func select(_ row: Int, note: String) {
        highlighted = row
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateEditor()
        onStatus?(note)
    }

    private func handleSpy(_ p: [UInt8]) {
        guard p.count >= 5, p[1] == spyIdx, p[2] == 0x00 else { return }
        let mask = UInt16(p[3]) << 8 | UInt16(p[4])
        let newly = mask & ~prevMask
        prevMask = mask
        guard let bit = (0..<16).first(where: { newly & (1 << $0) != 0 }) else { return }
        let row = Self.bitToRow(bit)
        guard row < rows.count else {
            onStatus?("Got bit \(bit) — beyond the button count")
            return
        }
        select(row, note: "Detected \(rows[row].name) · bit \(bit)")
    }

    /// MX 路徑事件：payload 是目前按住的 CID 清單
    private func handleDivertedEvent(_ p: [UInt8]) {
        guard p.count >= 5, p[1] == spyIdx, p[2] == 0x00 else { return }
        var i = 3
        while i + 1 < p.count && i < 11 {
            let cid = UInt16(p[i]) << 8 | UInt16(p[i + 1])
            if cid != 0, let row = rows.firstIndex(where: { $0.cid == cid }) {
                select(row, note: "Detected \(rows[row].name)")
                return
            }
            i += 2
        }
    }
}
