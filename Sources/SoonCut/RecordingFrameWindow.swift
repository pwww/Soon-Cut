import AppKit

enum FrameStyle {
    case idle       // 淡淡的線：提示目前的錄影範圍
    case recording  // 紅色虛線：錄影中
}

/// 在錄影範圍外圍畫框。視窗屬於本 App，會被錄影過濾器排除，不會錄進去。
final class RecordingFrameWindow: NSWindow {
    static let inset: CGFloat = 4

    init(rect: CGRect, style: FrameStyle) {
        super.init(contentRect: rect.insetBy(dx: -Self.inset, dy: -Self.inset),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating   // 在一般視窗之上、浮動視窗之下
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = FrameBorderView(style: style)
    }
}

private final class FrameBorderView: NSView {
    private let style: FrameStyle

    init(style: FrameStyle) {
        self.style = style
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .recording:
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            let dash: [CGFloat] = [8, 5]
            path.setLineDash(dash, count: dash.count, phase: 0)
            NSColor.systemRed.setStroke()
            path.stroke()
        case .idle:
            // 深色底線＋淺色虛線，亮暗畫面上都看得到，但不搶眼
            let base = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            base.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.25).setStroke()
            base.stroke()
            let line = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            line.lineWidth = 1.5
            let dash: [CGFloat] = [6, 4]
            line.setLineDash(dash, count: dash.count, phase: 0)
            NSColor.white.withAlphaComponent(0.6).setStroke()
            line.stroke()
        }
    }
}
