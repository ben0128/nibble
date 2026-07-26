// StatusIcon.swift — 選單列圖示：一隻會裝電量的滑鼠
// 數字直接畫在滑鼠body裡，寬度從「圖示＋文字」約 46pt 縮到 22pt。
// 用 template image（只吃 alpha 通道）→ 淺色／深色選單列自動適配。
import AppKit

enum StatusIcon {
    /// 滑鼠外形＋液面式電量＋body 內的百分比數字
    static func mouse(percent: Int?, charging: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 1.5, y: 0.5, width: 19, height: 17)
            // 上圓下方的滑鼠輪廓：頂部弧度大、底部收窄，一眼認得出是滑鼠
            let outline = NSBezierPath(roundedRect: body, xRadius: 8.5, yRadius: 7.5)
            outline.lineWidth = 1.3

            if let p = percent {
                // 液面：由下往上填到電量高度，裁切在輪廓內
                NSGraphicsContext.saveGraphicsState()
                outline.addClip()
                let level = body.height * CGFloat(max(0, min(100, p))) / 100
                NSColor.black.withAlphaComponent(0.30).setFill()
                NSRect(x: body.minX, y: body.minY, width: body.width, height: level).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            NSColor.black.withAlphaComponent(0.95).setStroke()
            outline.stroke()

            // 頂部：平常是滾輪短線，充電中換成閃電——同一個位置，不佔額外寬度
            let cx = body.midX
            if charging {
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: cx + 1.6, y: 15.6))
                bolt.line(to: NSPoint(x: cx - 1.8, y: 12.4))
                bolt.line(to: NSPoint(x: cx - 0.1, y: 12.4))
                bolt.line(to: NSPoint(x: cx - 1.6, y: 9.6))
                bolt.line(to: NSPoint(x: cx + 1.8, y: 12.8))
                bolt.line(to: NSPoint(x: cx + 0.1, y: 12.8))
                bolt.close()
                NSColor.black.withAlphaComponent(0.95).setFill()
                bolt.fill()
            } else {
                let wheel = NSBezierPath(roundedRect: NSRect(x: cx - 0.75, y: 11.4, width: 1.5, height: 4.2),
                                         xRadius: 0.75, yRadius: 0.75)
                NSColor.black.withAlphaComponent(0.95).setFill()
                wheel.fill()
            }

            // 數字畫在 body 下半部（滾輪之下），三位數自動縮字級
            let text = percent.map { String($0) } ?? "–"
            let fontSize: CGFloat = text.count >= 3 ? 8 : 9.5
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let ts = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: body.midX - ts.width / 2, y: 2.2), withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 讀不到裝置時的空心滑鼠（睡眠／離線／無權限共用，狀態靠選單內文字說明）
    static func mouseUnavailable() -> NSImage { mouse(percent: nil, charging: false) }
}
