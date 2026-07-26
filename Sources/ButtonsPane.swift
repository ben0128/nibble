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
    private let learnButton = NSButton(title: "🎯 按實體鍵定位", target: nil, action: nil)
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

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 428).isActive = true

        learnButton.target = self
        learnButton.action = #selector(toggleLearn)
        let editBtn = NSButton(title: "編輯選取的按鍵…", target: self, action: #selector(editSelected))
        let row = NSStackView(views: [learnButton, editBtn])
        row.spacing = 8

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue = "改鍵由 menubar 常駐執行；G1/G2 不可改（防鎖死）"

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
                    out.append(ButtonRow(index: i, name: "G\(i + 1)" + (i == 0 ? "（左鍵）" : i == 1 ? "（右鍵）" : ""),
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
            onStatus?("\(deviceName) · \(rows.count) 顆按鍵（裝置自我列舉）")
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
                text = a.type == "keys" ? "⌨ \(a.keys ?? "")" : a.type == "system" ? "⚙ \(a.action ?? "")" : "🚫 停用"
            } else {
                text = r.remappable ? "（預設）" : "（系統保留）"
            }
        default:
            text = r.remappable ? "可改鍵" : "—"
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
                onStatus?("按滑鼠上的任一顆鍵——對應的列會高亮（順便驗證位序是否正確）")
            } else if dev.has(0x1b04), let fi = try dev.featureIndex(of: 0x1b04) {
                // MX 路徑：暫時 divert 所有可 divert 的鍵來聽事件，停止時全部還原
                spyIdx = fi
                divertedForLearn = (try dev.controls()).filter(\.divertable).map(\.cid)
                for cid in divertedForLearn { try? dev.setDivert(cid: cid, on: true) }
                tr.onReport = { [weak self] p in self?.handleDivertedEvent(p) }
                onStatus?("按滑鼠上的任一顆鍵——對應的列會高亮（定位期間該鍵暫不作用）")
            } else {
                onStatus?("此裝置不支援按鍵定位")
                return
            }
            spyDev = dev
            spyTransport = tr
            learning = true
            learnButton.title = "⏹ 停止定位"
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
        learnButton.title = "🎯 按實體鍵定位"
        onStatus?("定位結束")
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
                onStatus?("偵測到 \(rows[row].name)（CID 0x\(String(format: "%04X", cid))）")
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
            onStatus?("收到 bit \(bit)（mask \(String(format: "%04X", mask))），超出按鍵數——位序假設可能有誤")
            return
        }
        highlighted = row
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        onStatus?("偵測到 \(rows[row].name)（bit \(bit)）——若你按的不是這顆，位序需要調整")
    }

    // MARK: 改鍵彈窗

    @objc private func editSelected() {
        let sel = table.selectedRow
        guard sel >= 0, sel < rows.count else { onStatus?("先選一列，或用「按實體鍵定位」"); return }
        let r = rows[sel]
        guard r.remappable else { onStatus?("\(r.name) 不可改（系統保留／防鎖死）"); return }
        presentEditor(for: sel)
    }

    private func presentEditor(for rowIndex: Int) {
        let r = rows[rowIndex]
        let alert = NSAlert()
        alert.messageText = "改鍵：\(r.name)"
        alert.informativeText = "選擇動作類型，儲存後於 menubar 生效"

        let typePopup = NSPopUpButton(frame: NSRect(x: 0, y: 62, width: 300, height: 26))
        typePopup.addItems(withTitles: ["快捷鍵", "系統動作", "停用這顆鍵", "還原預設"])
        let keysField = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        keysField.placeholderString = "例：cmd+shift+4 / ctrl+left / f13"
        let systemPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        systemPopup.addItems(withTitles: SystemAction.allCases.map(\.rawValue))

        switch r.action?.type {
        case "keys": typePopup.selectItem(at: 0); keysField.stringValue = r.action?.keys ?? ""
        case "system":
            typePopup.selectItem(at: 1)
            if let a = r.action?.action { systemPopup.selectItem(withTitle: a) }
        case "disable": typePopup.selectItem(at: 2)
        default: typePopup.selectItem(at: 0)
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 92))
        container.addSubview(typePopup)
        container.addSubview(keysField)
        container.addSubview(systemPopup)
        alert.accessoryView = container
        alert.addButton(withTitle: "儲存並套用")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var action: ButtonAction?
        switch typePopup.indexOfSelectedItem {
        case 0:
            let combo = keysField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !combo.isEmpty, parseCombo(combo) != nil else {
                onStatus?("⚠️ 快捷鍵解析失敗：\(combo)")
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

    private func save(_ action: ButtonAction?, for rowIndex: Int) {
        var cfg = loadConfig() ?? BMConfig()
        var maps = cfg.buttonMaps ?? [:]
        var devMap = maps[deviceName] ?? [:]
        let key = rows[rowIndex].name.components(separatedBy: "（").first ?? rows[rowIndex].name
        if let action { devMap[key] = action } else { devMap.removeValue(forKey: key) }
        maps[deviceName] = devMap.isEmpty ? nil : devMap
        cfg.buttonMaps = maps
        do {
            try saveConfig(cfg)
            rows[rowIndex].action = action
            table.reloadData()
            let desc = action.map { $0.type == "keys" ? ($0.keys ?? "") : $0.type == "system" ? ($0.action ?? "") : "停用" } ?? "預設"
            onStatus?("✓ \(key) → \(desc)（已存檔；menubar 選單點「重新載入改鍵引擎」生效）")
        } catch {
            onStatus?("❌ 存檔失敗：\(error)")
        }
    }
}
