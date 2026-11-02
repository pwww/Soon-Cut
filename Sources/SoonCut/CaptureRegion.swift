import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// 錄影範圍。rect 用 AppKit 全域座標（左下為原點、單位 point）。
struct CaptureRegion: Codable, Equatable {
    var displayID: UInt32
    var rect: CGRect

    @MainActor
    var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    /// 轉成 ScreenCaptureKit 的 sourceRect（相對於該螢幕、左上為原點、單位 point）
    @MainActor
    func sourceRect() -> CGRect? {
        guard let screen else { return nil }
        let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        return CGRect(x: local.minX,
                      y: screen.frame.height - local.maxY,
                      width: local.width,
                      height: local.height)
    }

    /// 以目前範圍中心、保持高度，改成 9:16
    @MainActor
    func convertedToShorts() -> CaptureRegion {
        guard let screen else { return self }
        let h = rect.height
        let w = h * 9.0 / 16.0
        var r = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        let bounds = screen.frame
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        return CaptureRegion(displayID: displayID, rect: r.integral)
    }
}
