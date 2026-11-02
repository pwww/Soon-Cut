import AVFoundation
import AppKit

enum ExportError: LocalizedError {
    case cannotCreateSession
    var errorDescription: String? { "無法建立輸出工作。" }
}

/// 拼接片段 → 依比例合成（模糊背景）＋燒入字幕＋免費版浮水印 → H.264 MP4
enum Exporter {
    @MainActor
    static func export(clips: [Clip], subtitles: [SubtitleSegment], format: OutputFormat, to url: URL) async throws -> Double {
        let result = try await Composer.build(clips: clips)
        let canvas = format.canvas(base: result.renderSize)
        let overlay = OverlayState()
        Renderer.prepareOverlay(overlay, subtitles: subtitles, canvas: canvas, watermark: Licensing.showsWatermark)
        let videoComposition = Renderer.videoComposition(for: result.composition, canvas: canvas, overlay: overlay)

        guard let session = AVAssetExportSession(asset: result.composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.cannotCreateSession
        }
        session.videoComposition = videoComposition
        try await session.export(to: url, as: .mp4)
        return result.duration
    }
}
