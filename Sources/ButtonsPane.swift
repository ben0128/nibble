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
    /// 有幾筆待儲存的改動——視窗用它決定 Save 按鈕能不能按
    var onPendingChange: ((Int) -> Void)?

    private let table = NSTableView()
    private var helpBadge: NSImageView!
    private let learnButton = NSButton(title: "Press to identify", target: nil, action: nil)
    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let profileMenuButton = NSPopUpButton(frame: .zero, pullsDown: true)

    // 右側編輯面板
    private let editorTitle = NSTextField(labelWithString: "No button selected")
    private let typeControl = NSSegmentedControl(labels: ["Keys", "Macro", "System", "Disable", "Default"],
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
    /// 待儲存的改動：按鍵名 → 動作（值為 nil 代表要清掉該映射）。
    /// 先前每動一下就寫檔，於是每次都要等寫檔 → 檔案監看 → 引擎重載 → 表格刷新，操作起來黏手。
    private var pending: [String: ButtonAction?] = [:]

    var pendingCount: Int { pending.count }

    /// spy 事件 bitmask 的 bit → 列序。位序若被實測推翻，只改這裡。
    static func bitToRow(_ bit: Int) -> Int { bit }

    // MARK: 版面

    func makeView() -> NSView {
        // 兩欄平分寬度：button 固定夠放最長的鍵名，action 吃掉剩下全部，
        // 右側不留空白（否則看起來像有第三個空欄位）
        let btnCol = withTitle("button", "col-btn", 92)
        btnCol.minWidth = 80
        btnCol.maxWidth = 110
        table.addTableColumn(btnCol)
        let actCol = withTitle("action", "col-act", 140)
        actCol.minWidth = 100
        table.addTableColumn(actCol)
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle   // action 欄補滿剩餘寬度
        table.style = .plain
        // 欄寬不給拖：這是固定兩欄的清單，可拖的分隔線只會讓人以為右邊還有一欄
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.target = self

        let ctx = NSMenu()
        let clearItem = NSMenuItem(title: "Clear mapping", action: #selector(clearSelected), keyEquivalent: "")
        clearItem.target = self
        ctx.addItem(clearItem)
        table.menu = ctx

        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        profilePopup.toolTip = "Each profile is its own set of button mappings. Switching one takes effect immediately — the menu bar has the same list."
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        profilePopup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        // pull-down 的第一項是標題，不會被選中
        profileMenuButton.addItem(withTitle: "⋯")
        for (title, sel) in [("New profile…", #selector(newProfile)),
                             ("Duplicate this profile…", #selector(duplicateProfile)),
                             ("Rename…", #selector(renameCurrentProfile)),
                             ("Delete", #selector(deleteCurrentProfile))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            profileMenuButton.menu?.addItem(item)
        }
        profileMenuButton.translatesAutoresizingMaskIntoConstraints = false
        profileMenuButton.widthAnchor.constraint(equalToConstant: 46).isActive = true

        let profileRow = NSStackView(views: [NSTextField(labelWithString: "Profile"), profilePopup, profileMenuButton])
        profileRow.spacing = 8
        profileRow.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        scroll.automaticallyAdjustsContentInsets = false   // 否則首列會被表頭切掉一截

        learnButton.target = self
        learnButton.action = #selector(toggleLearn)
        learnButton.translatesAutoresizingMaskIntoConstraints = false

        learnButton.toolTip = "Press a physical mouse button and its row is selected. Wheel scrolling isn't a button; the wheel click and tilts are."
        table.toolTip = "Right-click a row to clear its mapping. G1/G2 (left/right click) can't be remapped so the mouse can never lock you out."
        helpBadge = nibbleHelpBadge(
            "Edits are staged, not written as you go — press Save (or Return) to commit them, "
            + "and the menu bar reloads the remap engine. Right-click a row to clear it. "
            + "G1/G2 stay untouched so the mouse can never lock you out.")
        helpBadge.translatesAutoresizingMaskIntoConstraints = false

        let editor = makeEditor()
        editor.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        for v in [profileRow, scroll, learnButton, helpBadge, editor] as [NSView] { container.addSubview(v) }
        // Profile 自成一條橫幅；下方才分左右兩欄，
        // 編輯區與表格頂端對齊——先前錨在 profileRow 上，標題就跟 Profile 擠成一行
        NSLayoutConstraint.activate([
            profileRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            profileRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            profileRow.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: profileRow.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: editor.leadingAnchor, constant: -18),
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),   // 隨視窗變寬

            learnButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            learnButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            learnButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            helpBadge.leadingAnchor.constraint(equalTo: learnButton.trailingAnchor, constant: 8),
            helpBadge.centerYAnchor.constraint(equalTo: learnButton.centerYAnchor),

            editor.topAnchor.constraint(equalTo: scroll.topAnchor),
            editor.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            editor.widthAnchor.constraint(equalToConstant: 300),
            editor.bottomAnchor.constraint(lessThanOrEqualTo: learnButton.topAnchor, constant: -8),
        ])
        rebuildProfilePopup()
        updateEditor()
        return container
    }

    private func makeEditor() -> NSView {
        editorTitle.font = .boldSystemFont(ofSize: 13)

        typeControl.target = self
        typeControl.action = #selector(typeChanged)
        typeControl.segmentDistribution = .fillProportionally

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

    // MARK: Profile

    private func rebuildProfilePopup() {
        let cfg = loadConfig()
        profilePopup.removeAllItems()
        profilePopup.addItems(withTitles: profileNames(cfg))
        profilePopup.selectItem(withTitle: currentProfileName(cfg))
    }

    @objc private func profileChanged() {
        guard let name = profilePopup.titleOfSelectedItem else { return }
        let dropped = pending.count   // 換組就不套用舊組的暫存，但要講出來
        if dropped > 0 { pending.removeAll(); onPendingChange?(0) }
        do {
            try switchProfile(to: name)
            reload()
            onStatus?(dropped > 0
                ? "Profile: \(name) · discarded \(dropped) unsaved button change\(dropped == 1 ? "" : "s")"
                : "Profile: \(name)")
        } catch { onStatus?("❌ \(error)") }
    }

    /// 小輸入框對話框——名稱這種一行輸入不值得開一個視窗
    private func askName(_ title: String, _ initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func afterProfileChange(_ note: String) {
        // reload() 會清掉暫存的改動。悄悄丟掉使用者剛編輯的東西是最糟的，
        // 至少要說出來——連 rename（顯示的映射根本沒變）先前都是無聲清空
        let dropped = pending.count
        rebuildProfilePopup()
        reload()
        onStatus?(dropped > 0
            ? "\(note) · discarded \(dropped) unsaved button change\(dropped == 1 ? "" : "s")"
            : note)
    }

    @objc private func newProfile() {
        guard let name = askName("Name for the new profile") else { return }
        do { try createProfile(name); afterProfileChange("Created \(name) — it starts empty") }
        catch { onStatus?("❌ \(error)") }
    }

    @objc private func duplicateProfile() {
        let from = currentProfileName(loadConfig())
        guard let name = askName("Name for the copy of \(from)", "\(from) copy") else { return }
        do { try createProfile(name, copyFrom: from); afterProfileChange("Created \(name) from \(from)") }
        catch { onStatus?("❌ \(error)") }
    }

    @objc private func renameCurrentProfile() {
        let old = currentProfileName(loadConfig())
        guard let name = askName("Rename \(old) to", old), name != old else { return }
        do { try renameProfile(old, to: name); afterProfileChange("Renamed to \(name)") }
        catch { onStatus?("❌ \(error)") }
    }

    @objc private func deleteCurrentProfile() {
        let name = currentProfileName(loadConfig())
        let alert = NSAlert()
        alert.messageText = "Delete the \(name) profile?"
        alert.informativeText = "Its button mappings go with it. Other profiles are untouched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try deleteProfile(name); afterProfileChange("Deleted \(name)") }
        catch { onStatus?("❌ \(error)") }
    }

    // MARK: 資料

    func reload() {
        do {
            let (dev, _) = try uiOpenDevice(preferred: 1)
            deviceName = (try? dev.name()) ?? "unknown"
            let saved = activeButtonMaps(loadConfig())[deviceName] ?? [:]
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
            pending.removeAll()
            onPendingChange?(0)
            table.reloadData()
            table.sizeLastColumnToFit()   // 撐滿捲動區，右側不留下看似空欄的縫隙
            if table.selectedRow < 0 { table.scrollRowToVisible(0) }
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
            // 不加圖示：⌨ 在這個字級只會畫成一個小方塊，而值本身已經說明了類型
            // （有逗號的是巨集、單字的是系統動作）
            switch a.type {
            case "keys", "macro": text = a.keys ?? ""
            case "system": text = a.action ?? ""
            default: text = "disabled"
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

    /// 只暫存在記憶體，等使用者按 Save 才落地
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
        stage(action, for: i)
    }

    @objc private func clearSelected() {
        let sel = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard sel >= 0, sel < rows.count, rows[sel].action != nil else { return }
        stage(nil, for: sel)
        updateEditor()
    }

    private func buttonKey(_ rowIndex: Int) -> String {
        rows[rowIndex].name.components(separatedBy: " ").first ?? rows[rowIndex].name
    }

    private func describe(_ action: ButtonAction?) -> String {
        action.map {
            switch $0.type {
            case "keys", "macro": return $0.keys ?? ""
            case "system": return $0.action ?? ""
            default: return "disabled"
            }
        } ?? "default"
    }

    /// 暫存一筆改動：畫面立刻反映，設定檔還沒動
    private func stage(_ action: ButtonAction?, for rowIndex: Int) {
        let key = buttonKey(rowIndex)
        pending[key] = action
        rows[rowIndex].action = action
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        onStatus?("\(key) → \(describe(action)) · not saved yet")
        onPendingChange?(pending.count)
    }

    /// 一次寫入所有暫存改動——只碰設定檔一次，引擎也只重載一次
    func commitPending() {
        guard !pending.isEmpty else { return }
        let count = pending.count
        do {
            try updateActiveButtonMap(device: deviceName) { devMap in
                for (key, action) in pending {
                    if let action { devMap[key] = action } else { devMap.removeValue(forKey: key) }
                }
            }
            pending.removeAll()
            onPendingChange?(0)
            onStatus?("Saved \(count) change\(count == 1 ? "" : "s") — the menu bar reloads the engine")
        } catch {
            onStatus?("❌ save failed: \(error)")
        }
    }

    func discardPending() {
        guard !pending.isEmpty else { return }
        pending.removeAll()
        onPendingChange?(0)
        reload()
        onStatus?("Discarded unsaved changes")
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
