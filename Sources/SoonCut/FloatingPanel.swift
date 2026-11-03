import AppKit
import SwiftUI

/// 永遠在最上層、不搶焦點、跨桌面空間的浮動視窗
final class FloatingPanel: NSPanel {
    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Soon-Cut"
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)  // 比範圍框高一層
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // 不用 AppKit 的「整片背景都能拖」：會搶走縮圖、膠卷條的拖曳。
        // 改由 SwiftUI 的 WindowDragGesture 只在空白處拖動視窗（MainPanelView）。
        isMovableByWindowBackground = false
        let hosting = NSHostingView(rootView: rootView)
        // 視窗最小尺寸跟著 SwiftUI 內容的最小尺寸走，縮不到會跑版的大小
        hosting.sizingOptions = [.minSize]
        contentView = hosting

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            setFrameOrigin(NSPoint(x: vf.maxX - frame.width - 16, y: vf.maxY - frame.height - 16))
        }
    }

    /// 固定在最上層，或像一般視窗一樣可以被其他視窗蓋住
    func setPinned(_ pinned: Bool) {
        level = pinned ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) : .normal
        isFloatingPanel = pinned
        if pinned { orderFrontRegardless() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
