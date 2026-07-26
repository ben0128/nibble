// StatusIcon.swift — 選單列圖示：一隻會裝電量的滑鼠
// 數字直接畫在滑鼠身體裡，寬度從「圖示＋文字」約 46pt 縮到 18pt。
// 用 template image（只吃 alpha 通道）→ 淺色／深色選單列自動適配。
import AppKit

enum StatusIcon {
    /// 俯視滑鼠輪廓：窄高比例＋前端圓頂＋左右鍵接縫＋滾輪，這四點是「一眼認得出是滑鼠」的關鍵
    private static func bodyPath(_ r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let topR = r.width / 2            // 前端半圓
        let botR = r.width * 0.40         // 掌根收窄
        let x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        p.move(to: NSPoint(x: x0, y: y1 - topR))
        // clockwise: true = 角度遞減 180°→90°→0°，才會繞過頂端；false 會繞底部把圓頂畫反
        p.appendArc(withCenter: NSPoint(x: r.midX, y: y1 - topR), radius: topR,
                    startAngle: 180, endAngle: 0, clockwise: true)
        p.line(to: NSPoint(x: x1, y: y0 + botR))
        p.appendArc(withCenter: NSPoint(x: x1 - botR, y: y0 + botR), radius: botR,
                    startAngle: 0, endAngle: -90, clockwise: true)
        p.line(to: NSPoint(x: x0 + botR, y: y0))
        p.appendArc(withCenter: NSPoint(x: x0 + botR, y: y0 + botR), radius: botR,
                    startAngle: -90, endAngle: 180, clockwise: true)
        p.close()
        return p
    }

    static func mouse(percent: Int?, charging: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 19)
        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 2.4, y: 0.7, width: 13.2, height: 17.6)
            let path = bodyPath(body)
            path.lineWidth = 1.3
            let ink = NSColor.black

            if let p = percent {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                let level = body.height * CGFloat(max(0, min(100, p))) / 100
                ink.withAlphaComponent(0.28).setFill()
                NSRect(x: body.minX, y: body.minY, width: body.width, height: level).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            ink.withAlphaComponent(0.95).setStroke()
            path.stroke()

            // 左右鍵接縫：橫過機身的分隔線，滑鼠俯視最強的識別特徵
            let seamY = body.minY + body.height * 0.60
            let seam = NSBezierPath()
            seam.move(to: NSPoint(x: body.minX + 1.4, y: seamY))
            seam.line(to: NSPoint(x: body.maxX - 1.4, y: seamY))
            seam.lineWidth = 0.9
            ink.withAlphaComponent(0.6).setStroke()
            seam.stroke()

            // 兩鍵之間的縱向分隔，滾輪就坐在這條線上
            let cx = body.midX
            if !charging {   // 充電時閃電就是主角，分隔線會穿過去變成電線桿
                let divider = NSBezierPath()
                divider.move(to: NSPoint(x: cx, y: seamY))
                divider.line(to: NSPoint(x: cx, y: body.maxY - 1.6))
                divider.lineWidth = 0.9
                ink.withAlphaComponent(0.45).setStroke()
                divider.stroke()
            }

            ink.withAlphaComponent(0.95).setFill()
            let wheelMidY = (seamY + body.maxY) / 2
            if charging {
                // 充電時滾輪換成閃電——同一個位置，不佔額外寬度
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: cx + 1.5, y: wheelMidY + 2.6))
                bolt.line(to: NSPoint(x: cx - 1.7, y: wheelMidY - 0.4))
                bolt.line(to: NSPoint(x: cx - 0.1, y: wheelMidY - 0.4))
                bolt.line(to: NSPoint(x: cx - 1.5, y: wheelMidY - 2.8))
                bolt.line(to: NSPoint(x: cx + 1.7, y: wheelMidY + 0.2))
                bolt.line(to: NSPoint(x: cx + 0.1, y: wheelMidY + 0.2))
                bolt.close()
                bolt.fill()
            } else {
                NSBezierPath(roundedRect: NSRect(x: cx - 0.8, y: wheelMidY - 1.8, width: 1.6, height: 3.6),
                             xRadius: 0.8, yRadius: 0.8).fill()
            }

            // 數字放在掌根區（接縫之下），三位數自動縮字級
            let text = percent.map { String($0) } ?? "–"
            let fontSize: CGFloat = text.count >= 3 ? 5.8 : 7.5
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: ink,
            ]
            // 用 capHeight 而非 line height 置中，否則行距會把數字往上頂
            let font = attrs[.font] as! NSFont
            let ts = (text as NSString).size(withAttributes: attrs)
            let palmMidY = (body.minY + seamY) / 2
            (text as NSString).draw(at: NSPoint(x: body.midX - ts.width / 2,
                                                y: palmMidY - font.capHeight / 2 + font.descender),
                                    withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 讀不到裝置時的空心滑鼠（睡眠／離線／無權限共用，狀態靠選單內文字說明）
    static func mouseUnavailable() -> NSImage { mouse(percent: nil, charging: false) }
}
