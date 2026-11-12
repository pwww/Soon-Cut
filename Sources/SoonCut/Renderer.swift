import AVFoundation
import CoreImage
import AppKit

/// 預覽與輸出共用的畫面合成：比例畫布＋模糊背景＋字幕＋浮水印
/// （用 Core Image 每格合成，預覽看到的就是輸出的樣子）
final class OverlayState: @unchecked Sendable {
    private let lock = NSLock()
    private var subtitles: [(start: Double, end: Double, image: CIImage)] = []
    private var watermark: CIImage?

    func update(subtitles: [(start: Double, end: Double, image: CIImage)], watermark: CIImage?) {
        lock.lock()
        self.subtitles = subtitles
        self.watermark = watermark
        lock.unlock()
    }

    func images(at time: Double) -> (subtitle: CIImage?, watermark: CIImage?) {
        lock.lock()
        defer { lock.unlock() }
        // 時間重疊時，以「最近開始」的那一句為準，長句才不會把後面的句子擋住
        let sub = subtitles.last { time >= $0.start && time < $0.end }?.image
        return (sub, watermark)
    }
}

enum Renderer {
    /// 依字幕與浮水印設定，先把要疊的圖準備好（在主執行緒畫字）
    @MainActor
    static func prepareOverlay(_ state: OverlayState, subtitles: [SubtitleSegment], style: SubtitleStyle,
                               canvas: CGSize, watermark: Bool) {
        var items: [(start: Double, end: Double, image: CIImage)] = []
        for seg in subtitles where seg.end > seg.start {
            guard let image = SubtitleRenderer.image(text: seg.text, canvas: canvas, style: style),
                  let ci = ciImage(from: image) else { continue }
            let frame = SubtitleRenderer.frame(imageSize: image.size, canvas: canvas, style: style)
            items.append((seg.start, seg.end, place(ci, in: frame)))
        }
        var wm: CIImage?
        if watermark, let image = SubtitleRenderer.watermarkImage(canvas: canvas), let ci = ciImage(from: image) {
            wm = place(ci, in: SubtitleRenderer.watermarkFrame(imageSize: image.size, canvas: canvas))
        }
        items.sort { $0.start < $1.start }
        state.update(subtitles: items, watermark: wm)
    }

    static func videoComposition(for asset: AVAsset, canvas: CGSize, overlay: OverlayState) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let output = render(request.sourceImage,
                                canvas: canvas,
                                time: CMTimeGetSeconds(request.compositionTime),
                                overlay: overlay)
            request.finish(with: output, context: nil)
        }
        composition.renderSize = canvas
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        return composition
    }

    static func render(_ source: CIImage, canvas: CGSize, time: Double, overlay: OverlayState) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let ext = source.extent
        guard ext.width > 0, ext.height > 0 else {
            return CIImage(color: .black).cropped(to: canvasRect)
        }
        let base = source.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
        let w = ext.width
        let h = ext.height

        // 前景：等比縮放置中
        let fit = min(canvas.width / w, canvas.height / h)
        let foreground = base
            .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            .transformed(by: CGAffineTransform(translationX: (canvas.width - w * fit) / 2,
                                               y: (canvas.height - h * fit) / 2))

        var output: CIImage
        let fillsCanvas = abs(w * fit - canvas.width) < 2 && abs(h * fit - canvas.height) < 2
        if fillsCanvas {
            output = foreground
        } else {
            // 背景：同一畫面放大填滿、縮小後模糊再放大（省效能），稍微壓暗
            let fill = max(canvas.width / w, canvas.height / h)
            let small: CGFloat = 0.25
            let background = base
                .transformed(by: CGAffineTransform(scaleX: fill * small, y: fill * small))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 12)
                .transformed(by: CGAffineTransform(scaleX: 1 / small, y: 1 / small))
                .transformed(by: CGAffineTransform(translationX: (canvas.width - w * fill) / 2,
                                                   y: (canvas.height - h * fill) / 2))
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: -0.12,
                    kCIInputSaturationKey: 1.1
                ])
                .cropped(to: canvasRect)
            output = foreground.composited(over: background)
        }

        let (subtitle, watermark) = overlay.images(at: time)
        if let subtitle { output = subtitle.composited(over: output) }
        if let watermark { output = watermark.composited(over: output) }
        return output.cropped(to: canvasRect)
    }

    private static func ciImage(from image: NSImage) -> CIImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return CIImage(cgImage: cg)
    }

    /// 把字幕圖（可能是 2x 像素）縮放並移到畫布上的位置
    private static func place(_ image: CIImage, in frame: CGRect) -> CIImage {
        let sx = frame.width / max(image.extent.width, 1)
        let sy = frame.height / max(image.extent.height, 1)
        return image
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
    }
}
