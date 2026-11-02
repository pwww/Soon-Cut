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
        isMovableByWindowBackground = false   // 只能從頂端拖動，避免跟內部拖曳衝突
        let hosting = NSHostingView(rootView: rootView)
        // 視窗最小尺寸跟著 SwiftUI 內容的最小尺寸走，縮不到會跑版的大小
        hosting.sizingOptions = [.minSize]
        contentView = hosting

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            setFrameOrigin(NSPoint(x: vf.maxX - frame.width - 16, y: vf.maxY - frame.height - 16))
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
