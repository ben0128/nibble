// MenuBar.swift — M4 選單列模式（opt-in 常駐；AppKit NSStatusItem，不用 SwiftUI 全家桶）
// 只佔一個電量數字。Quit 無懼：設定都是 runtime + 重放，退出不影響滑鼠。
import AppKit

func runMenuBar() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // 無 Dock 圖示（LSUIElement 等效）
    let delegate = MenuBarDelegate()
    app.delegate = delegate
    app.run()
    return 0
}

final class MenuBarDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let deviceItem = NSMenuItem(title: "偵測中…", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖱…"

        let menu = NSMenu()
        menu.addItem(deviceItem)
        menu.addItem(detailItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("立即更新", #selector(refreshAction)))
        menu.addItem(makeItem("套用設定檔（apply）", #selector(applyAction)))
        menu.addItem(.separator())
        menu.addItem(makeItem("結束（滑鼠照常運作）", #selector(quitAction), key: "q"))
        statusItem.menu = menu

        refresh()
        // 5 分鐘一次的輕探測（episodic：開→查→關，不長期佔用裝置）
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func makeItem(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        return item
    }

    private func refresh() {
        do {
            let tr = try ReceiverTransport.openFirst()
            guard let hit = discover(tr).first else {
                statusItem.button?.title = "🖱💤"
                deviceItem.title = "滑鼠睡眠中"
                detailItem.title = ""
                return
            }
            deviceItem.title = (try? hit.dev.name()) ?? "Logitech device #\(hit.idx)"
            if let b = try? hit.dev.battery() {
                let warn = b.percent <= 15 && !b.charging
                statusItem.button?.title = "\(warn ? "⚠️" : "🖱")\(b.percent)%"
                let volt = b.millivolts.map { String(format: " · %.2fV", Double($0) / 1000) } ?? ""
                detailItem.title = "\(b.charging ? "充電中 ⚡" : "放電中")\(volt)"
            } else {
                statusItem.button?.title = "🖱–"
                detailItem.title = "電池讀取失敗"
            }
        } catch {
            statusItem.button?.title = "🖱—"
            deviceItem.title = "接收器離線"
            detailItem.title = "\(error)"
        }
    }

    @objc private func refreshAction() { refresh() }
    @objc private func applyAction() { _ = cmdApply(); refresh() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}
