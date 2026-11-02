import AppKit

/// 字幕外觀：白字＋黑色外框，畫面下方。預覽和燒入用同一套，確保所見即所得。
enum SubtitleRenderer {
    /// 字幕底邊離畫面底部的比例
    static let bottomMargin: CGFloat = 0.12

    static func fontSize(for canvas: CGSize) -> CGFloat {
        min(canvas.width, canvas.height) * 0.065
    }

    static func font(size: CGFloat) -> NSFont {
        NSFont(name: "PingFangTC-Semibold", size: size) ?? .boldSystemFont(ofSize: size)
    }

    /// 以影片像素為單位畫出一句字幕
    static func image(text: String, canvas: CGSize) -> NSImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canvas.width > 0, canvas.height > 0 else { return nil }

        let size = fontSize(for: canvas)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let fill: [NSAttributedString.Key: Any] = [
            .font: font(size: size),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para
        ]
        var stroke = fill
        stroke[.strokeColor] = NSColor.black
        stroke[.strokeWidth] = 18.0   // 正值＝只畫外框（字級的 %）

        let maxWidth = canvas.width * 0.86
        let pad = size * 0.3
        let measured = NSAttributedString(string: trimmed, attributes: fill)
            .boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        let imageSize = CGSize(width: ceil(maxWidth + pad * 2), height: ceil(measured.height + pad * 2))

        return NSImage(size: imageSize, flipped: false) { rect in
            let r = rect.insetBy(dx: pad, dy: pad)
            NSAttributedString(string: trimmed, attributes: stroke).draw(in: r)
            NSAttributedString(string: trimmed, attributes: fill).draw(in: r)
            return true
        }
    }

    /// 字幕圖在畫布上的位置（左下原點，給 Core Animation 用）
    static func frame(imageSize: CGSize, canvas: CGSize) -> CGRect {
        CGRect(x: (canvas.width - imageSize.width) / 2,
               y: canvas.height * bottomMargin,
               width: imageSize.width,
               height: imageSize.height)
    }

    // MARK: 浮水印（免費版）：右下角小字，半透明，不擋內容

    static func watermarkImage(canvas: CGSize) -> NSImage? {
        let size = max(14, min(canvas.width, canvas.height) * 0.028)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = size * 0.15
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.05)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            .shadow: shadow
        ]
        let text = NSAttributedString(string: "SoonCut", attributes: attrs)
        let textSize = text.size()
        let pad = size * 0.2
        let imageSize = CGSize(width: ceil(textSize.width + pad * 2), height: ceil(textSize.height + pad * 2))
        return NSImage(size: imageSize, flipped: false) { rect in
            text.draw(at: NSPoint(x: pad, y: pad))
            return true
        }
    }

    static func watermarkFrame(imageSize: CGSize, canvas: CGSize) -> CGRect {
        let margin = min(canvas.width, canvas.height) * 0.03
        return CGRect(x: canvas.width - imageSize.width - margin,
                      y: margin,
                      width: imageSize.width,
                      height: imageSize.height)
    }
}
