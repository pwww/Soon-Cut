import AppKit

/// 字幕外觀設定：字色、外框、大小、上下位置（一律水平置中）
struct SubtitleStyle: Equatable, Codable {
    enum TextColor: String, CaseIterable, Identifiable, Codable {
        case white, yellow, black
        var id: String { rawValue }
        var label: String {
            switch self {
            case .white: return String(localized: "白色")
            case .yellow: return String(localized: "黃色")
            case .black: return String(localized: "黑色")
            }
        }
        var color: NSColor {
            switch self {
            case .white: return .white
            case .yellow: return NSColor(red: 1, green: 0.86, blue: 0.1, alpha: 1)
            case .black: return .black
            }
        }
    }

    enum Outline: String, CaseIterable, Identifiable, Codable {
        case none, white, black
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return String(localized: "無框")
            case .white: return String(localized: "白框")
            case .black: return String(localized: "黑框")
            }
        }
        var color: NSColor? {
            switch self {
            case .none: return nil
            case .white: return .white
            case .black: return .black
            }
        }
    }

    /// 字級＝畫面短邊的比例。9:16（1080 寬）時：小 54px、中 70px、大 86px、特大 103px
    enum Size: String, CaseIterable, Identifiable, Codable {
        case small, medium, large, extraLarge
        var id: String { rawValue }
        var label: String {
            switch self {
            case .small: return String(localized: "小")
            case .medium: return String(localized: "中")
            case .large: return String(localized: "大")
            case .extraLarge: return String(localized: "特大")
            }
        }
        var ratio: CGFloat {
            switch self {
            case .small: return 0.05
            case .medium: return 0.065
            case .large: return 0.08
            case .extraLarge: return 0.095
            }
        }
    }

    static let defaultPosition: Double = 0.12
    static let positionRange: ClosedRange<Double> = 0.03...0.85

    var textColor: TextColor = .white
    var outline: Outline = .black
    var size: Size = .medium
    /// 字幕底邊離畫面底部的比例（0.03＝貼近底部，0.85＝接近頂部）
    var position: Double = SubtitleStyle.defaultPosition

    static let storageKey = "subtitleStyle"

    static func load() -> SubtitleStyle {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let style = try? JSONDecoder().decode(SubtitleStyle.self, from: data) else { return SubtitleStyle() }
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// 字幕外觀：依 SubtitleStyle 畫字，水平置中。預覽和燒入用同一套，確保所見即所得。
enum SubtitleRenderer {
    static func fontSize(for canvas: CGSize, style: SubtitleStyle) -> CGFloat {
        min(canvas.width, canvas.height) * style.size.ratio
    }

    static func font(size: CGFloat) -> NSFont {
        NSFont(name: "PingFangTC-Semibold", size: size) ?? .boldSystemFont(ofSize: size)
    }

    /// 以影片像素為單位畫出一句字幕
    static func image(text: String, canvas: CGSize, style: SubtitleStyle) -> NSImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canvas.width > 0, canvas.height > 0 else { return nil }

        let size = fontSize(for: canvas, style: style)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let fill: [NSAttributedString.Key: Any] = [
            .font: font(size: size),
            .foregroundColor: style.textColor.color,
            .paragraphStyle: para
        ]
        var stroke: [NSAttributedString.Key: Any]?
        if let outline = style.outline.color {
            var s = fill
            s[.strokeColor] = outline
            s[.strokeWidth] = 18.0   // 正值＝只畫外框（字級的 %）
            stroke = s
        }

        let maxWidth = canvas.width * 0.86
        let pad = size * 0.3
        let measured = NSAttributedString(string: trimmed, attributes: fill)
            .boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        let imageSize = CGSize(width: ceil(maxWidth + pad * 2), height: ceil(measured.height + pad * 2))

        return NSImage(size: imageSize, flipped: false) { rect in
            let r = rect.insetBy(dx: pad, dy: pad)
            if let stroke { NSAttributedString(string: trimmed, attributes: stroke).draw(in: r) }
            NSAttributedString(string: trimmed, attributes: fill).draw(in: r)
            return true
        }
    }

    /// 字幕圖在畫布上的位置（左下原點，給 Core Animation 用）
    static func frame(imageSize: CGSize, canvas: CGSize, style: SubtitleStyle) -> CGRect {
        let y = min(canvas.height * CGFloat(style.position), canvas.height - imageSize.height)
        return CGRect(x: (canvas.width - imageSize.width) / 2,
                      y: max(0, y),
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
