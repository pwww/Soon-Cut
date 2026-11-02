import AppKit

/// 在每個螢幕蓋一層半透明遮罩，讓使用者直接在畫面上拖曳框選
@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var completion: ((CaptureRegion?) -> Void)?

    func begin(shortsMode: Bool, completion: @escaping (CaptureRegion?) -> Void) {
        cancelExisting()
        self.completion = completion
        for screen in NSScreen.screens {
            let window = SelectionWindow(screen: screen, shortsMode: shortsMode) { [weak self] rect in
                self?.finish(rect, on: screen)
            }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)
            windows.append(window)
        }
        NSApp.activate()
    }

    private func cancelExisting() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func finish(_ localRect: CGRect?, on screen: NSScreen) {
        cancelExisting()
        let done = completion
        completion = nil
        guard let localRect, localRect.width >= 40, localRect.height >= 40,
              let id = screen.displayID else {
            done?(nil)
            return
        }
        let global = localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY).integral
        done?(CaptureRegion(displayID: id, rect: global))
    }
}

final class SelectionWindow: NSWindow {
    init(screen: NSScreen, shortsMode: Bool, onDone: @escaping (CGRect?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: false)
        contentView = SelectionView(shortsMode: shortsMode, onDone: onDone)
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    private let shortsMode: Bool
    private let onDone: (CGRect?) -> Void
    private var start: NSPoint?
    private var selection: NSRect?

    init(shortsMode: Bool, onDone: @escaping (CGRect?) -> Void) {
        self.shortsMode = shortsMode
        self.onDone = onDone
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        selection = rect(from: start, to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onDone(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone(nil) } // Esc
    }

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        let w = abs(b.x - a.x)
        let h = shortsMode ? w * 16.0 / 9.0 : abs(b.y - a.y)
        let x = b.x >= a.x ? a.x : a.x - w
        let y = b.y >= a.y ? a.y : a.y - h
        return NSRect(x: x, y: y, width: w, height: h).intersection(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white
        ]

        guard let r = selection else {
            let hint = shortsMode ? "拖曳框選錄影範圍（鎖定 9:16）· Esc 取消" : "拖曳框選錄影範圍 · Esc 取消"
            let s = NSAttributedString(string: hint, attributes: attrs)
            s.draw(at: NSPoint(x: bounds.midX - s.size().width / 2, y: bounds.midY))
            return
        }

        NSColor.clear.setFill()
        r.fill(using: .copy)
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: r)
        path.lineWidth = 2
        path.stroke()

        let label = NSAttributedString(string: "\(Int(r.width)) × \(Int(r.height))", attributes: attrs)
        label.draw(at: NSPoint(x: r.minX, y: max(r.minY - 22, 4)))
    }
}
