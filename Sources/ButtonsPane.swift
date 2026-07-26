// ButtonsPane.swift — M5c 改鍵 UI（設定面板的 Buttons 分頁）
// 不畫滑鼠：按鍵清單由裝置自我列舉（0x8110 G 系 / 0x1b04 MX 系），
// 定位靠 press-to-identify——按實體鍵，對應列高亮。這同時是位序驗證器：
// 按 G7 若亮在別列，代表 bitmask 假設要修（改 ButtonsPane.bitToRow 一處即可）。
import AppKit

struct ButtonRow {
    let index: Int          // 0-based 鍵序（G(index+1)）
    let name: String
    let remappable: Bool
    var cid: UInt16? = nil        // MX 路徑用（G 系為 nil）
    var action: ButtonAction?
}

final class ButtonsPane: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onStatus: ((String) -> Void)?
    private let table = NSTableView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let learnButton = NSButton(title: "Press to identify", target: nil, action: nil)
    private var rows: [ButtonRow] = []
    private var deviceName = "unknown"
    private var learning = false
    private var highlighted: Int?
    private var spyDev: HIDPPDevice?
    private var spyTransport: ReceiverTransport?
    private var spyIdx: UInt8 = 0
    private var prevMask: UInt16 = 0
    private var divertedForLearn: [UInt16] = []

    /// spy 事件 bitmask 的 bit → 列序。位序若被實測推翻，只改這裡。
    static func bitToRow(_ bit: Int) -> Int { bit }

    func makeView() -> NSView {
        table.addTableColumn(withTitle("button", "col-btn", 90))
        table.addTableColumn(withTitle("action", "col-act", 200))
        table.addTableColumn(withTitle("", "col-edit", 90))
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.doubleAction = #selector(editSelected)
        table.target = self

        let ctx = NSMenu()
        let editItem = NSMenuItem(title: "Edit…", action: #selector(editSelected), keyEquivalent: "")
        editItem.target = self
        let clearItem = NSMenuItem(title: "Clear mapping", action: #selector(clearSelected), keyEquivalent: "")
        clearItem.target = self
        ctx.addItem(editItem)
        ctx.addItem(clearItem)
        table.menu = ctx

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 428).isActive = true

        learnButton.target = self
        learnButton.action = #selector(toggleLearn)
        let editBtn = NSButton(title: "Edit selected…", target: self, action: #selector(editSelected))
        let row = NSStackView(views: [learnButton, editBtn])
        row.spacing = 8

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue = "Remaps run in the menu bar app · right-click a row to clear · G1/G2 locked"

        let stack = NSStackView(views: [scroll, row, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
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
            onStatus?("\(deviceName) · \(rows.count) buttons (enumerated from device)")
        } catch {
            rows = []
            table.reloadData()
            onStatus?("❌ \(error)")
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "col-btn":
            text = (highlighted == row ? "▶ " : "") + r.name
        case "col-act":
            if let a = r.action {
                text = a.type == "keys" ? "⌨ \(a.keys ?? "")" : a.type == "system" ? "⚙ \(a.action ?? "")" : "🚫 disabled"
            } else {
                text = r.remappable ? "(default)" : "(system)"
            }
        default:
            text = r.remappable ? "remappable" : "—"
        }
        let label = NSTextField(labelWithString: text)
        label.font = highlighted == row ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        if highlighted == row { label.textColor = .controlAccentColor }
        else if !r.remappable { label.textColor = .tertiaryLabelColor }
        return label
    }

    // MARK: press-to-identify（同時是位序驗證器）

    @objc private func toggleLearn() {
        learning ? stopLearn() : startLearn()
    }

    private func startLearn() {
        do {
            let (dev, _) = try uiOpenDevice(preferred: 1)
            guard let tr = dev.transport as? ReceiverTransport else { return }
            if dev.has(0x8110), let idx = try dev.featureIndex(of: 0x8110) {
                spyIdx = idx
                prevMask = 0
                try dev.buttonSpyStart()
                tr.onReport = { [weak self] p in self?.handleSpy(p) }
                onStatus?("Press any mouse button — its row will highlight")
            } else if dev.has(0x1b04), let fi = try dev.featureIndex(of: 0x1b04) {
                // MX 路徑：暫時 divert 所有可 divert 的鍵來聽事件，停止時全部還原
                spyIdx = fi
                divertedForLearn = (try dev.controls()).filter(\.divertable).map(\.cid)
                for cid in divertedForLearn { try? dev.setDivert(cid: cid, on: true) }
                tr.onReport = { [weak self] p in self?.handleDivertedEvent(p) }
                onStatus?("Press any mouse button — its row will highlight (buttons are inert while identifying)")
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

    /// MX 路徑事件：payload 是目前按住的 CID 清單
    private func handleDivertedEvent(_ p: [UInt8]) {
        guard p.count >= 5, p[1] == spyIdx, p[2] == 0x00 else { return }
        var i = 3
        while i + 1 < p.count && i < 11 {
            let cid = UInt16(p[i]) << 8 | UInt16(p[i + 1])
            if cid != 0, let row = rows.firstIndex(where: { $0.cid == cid }) {
                highlighted = row
                table.reloadData()
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
                onStatus?("Detected \(rows[row].name) (CID 0x\(String(format: "%04X", cid)))")
                return
            }
            i += 2
        }
    }

    func teardown() { if learning { stopLearn() } }

    private func handleSpy(_ p: [UInt8]) {
        guard p.count >= 5, p[1] == spyIdx, p[2] == 0x00 else { return }
        let mask = UInt16(p[3]) << 8 | UInt16(p[4])
        let newly = mask & ~prevMask
        prevMask = mask
        guard let bit = (0..<16).first(where: { newly & (1 << $0) != 0 }) else { return }
        let row = Self.bitToRow(bit)
        guard row < rows.count else {
            onStatus?("Got bit \(bit) (mask \(String(format: "%04X", mask))) — beyond the button count, bit order may be wrong")
            return
        }
        highlighted = row
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        onStatus?("Detected \(rows[row].name) (bit \(bit)) — if that is not the button you pressed, the bit order needs adjusting")
    }

    // MARK: 改鍵彈窗

    @objc private func clearSelected() {
        let sel = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard sel >= 0, sel < rows.count else { return }
        guard rows[sel].action != nil else {
            onStatus?("\(rows[sel].name) has no mapping")
            return
        }
        save(nil, for: sel)
    }

    @objc private func editSelected() {
        let sel = table.selectedRow
        guard sel >= 0, sel < rows.count else { onStatus?("Select a row, or use press-to-identify"); return }
        let r = rows[sel]
        guard r.remappable else { onStatus?("\(r.name) is locked (system button)"); return }
        presentEditor(for: sel)
    }

    private func presentEditor(for rowIndex: Int) {
        let r = rows[rowIndex]
        let alert = NSAlert()
        alert.messageText = "Remap \(r.name)"
        alert.informativeText = "Applies as soon as you save — the menu bar reloads automatically."

        let typePopup = NSPopUpButton(frame: NSRect(x: 0, y: 64, width: 320, height: 26))
        typePopup.addItems(withTitles: ["Keystroke", "System action",
                                        "Disable this button", "Restore default"])
        let recorder = KeyRecorderView(frame: NSRect(x: 0, y: 30, width: 320, height: 26))
        let systemPopup = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 320, height: 26))
        systemPopup.addItems(withTitles: SystemAction.allCases.map(\.rawValue))
        let hint = NSTextField(labelWithString: "")
        hint.frame = NSRect(x: 0, y: 4, width: 320, height: 18)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        switch r.action?.type {
        case "keys": typePopup.selectItem(at: 0); recorder.combo = r.action?.keys
        case "system":
            typePopup.selectItem(at: 1)
            if let a = r.action?.action { systemPopup.selectItem(withTitle: a) }
        case "disable": typePopup.selectItem(at: 2)
        default: typePopup.selectItem(at: 0)
        }

        // 依類型只顯示相關控制項——不要讓使用者同時看到不相干的欄位
        func syncVisibility() {
            let idx = typePopup.indexOfSelectedItem
            recorder.isHidden = idx != 0
            systemPopup.isHidden = idx != 1
            switch idx {
            case 0: hint.stringValue = "Esc clears the recording"
            case 1: hint.stringValue = "app:Name also works, e.g. app:Safari"
            case 2: hint.stringValue = "The button stops doing anything"
            default: hint.stringValue = "Hands the button back to the mouse"
            }
        }
        let observer = TypeChangeObserver { syncVisibility() }
        typePopup.target = observer
        typePopup.action = #selector(TypeChangeObserver.changed)
        syncVisibility()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 94))
        container.addSubview(typePopup)
        container.addSubview(recorder)
        container.addSubview(systemPopup)
        container.addSubview(hint)
        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = recorder

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = observer   // 讓 observer 活到 modal 結束

        var action: ButtonAction?
        switch typePopup.indexOfSelectedItem {
        case 0:
            guard let combo = recorder.combo, parseCombo(combo) != nil else {
                onStatus?("⚠️ No key combination recorded")
                return
            }
            action = ButtonAction(type: "keys", keys: combo, action: nil)
        case 1:
            action = ButtonAction(type: "system", keys: nil, action: systemPopup.titleOfSelectedItem)
        case 2:
            action = ButtonAction(type: "disable", keys: nil, action: nil)
        default:
            action = nil
        }
        save(action, for: rowIndex)
    }

    /// NSPopUpButton 的 target 必須是 NSObject；用小物件轉接 closure
    private final class TypeChangeObserver: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func changed() { handler() }
    }

    private func save(_ action: ButtonAction?, for rowIndex: Int) {
        var cfg = loadConfig() ?? BMConfig()
        var maps = cfg.buttonMaps ?? [:]
        var devMap = maps[deviceName] ?? [:]
        let key = rows[rowIndex].name.components(separatedBy: CharacterSet(charactersIn: "（ ")).first ?? rows[rowIndex].name
        if let action { devMap[key] = action } else { devMap.removeValue(forKey: key) }
        maps[deviceName] = devMap.isEmpty ? nil : devMap
        cfg.buttonMaps = maps
        do {
            try saveConfig(cfg)
            rows[rowIndex].action = action
            table.reloadData()
            let desc = action.map { $0.type == "keys" ? ($0.keys ?? "") : $0.type == "system" ? ($0.action ?? "") : "disabled" } ?? "default"
            onStatus?("✓ \(key) → \(desc) · saved, menu bar reloads automatically")
        } catch {
            onStatus?("❌ save failed: \(error)")
        }
    }
}
