import AVFoundation
import CoreGraphics

enum ComposerError: LocalizedError {
    case empty
    var errorDescription: String? { String(localized: "沒有可以拼接的片段。") }
}

/// 把多個片段（依剪輯點）接成一條時間軸；尺寸不同的片段等比縮放置中到第一個片段的畫布
enum Composer {
    struct Result {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let duration: Double
        let renderSize: CGSize
        /// 時間軸上每一小段（每個黃色區段）的位置，轉寫時逐段處理
        let pieces: [ClipRange]
    }

    static func build(clips: [Clip]) async throws -> Result {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposerError.empty
        }
        // 每個片段可能有多條音軌（系統聲音＋麥克風），依序放進對應的音軌，播放與輸出時會混在一起
        var audioTracks: [AVMutableCompositionTrack] = []

        var cursor = CMTime.zero
        var segments: [(range: CMTimeRange, size: CGSize, transform: CGAffineTransform)] = []

        for clip in clips where clip.trimmedDuration >= ClipStorage.minClipLength {
            let asset = AVURLAsset(url: clip.url)
            guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let assetDuration = try await asset.load(.duration)
            let srcAudios = try await asset.loadTracks(withMediaType: .audio)
            let natural = try await srcVideo.load(.naturalSize)
            let preferred = try await srcVideo.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: natural).applying(preferred)
            let size = CGSize(width: abs(rect.width), height: abs(rect.height))

            // 一個片段裡的每個黃色區段依序接起來，中間的空隙跳過
            for r in clip.ranges where r.length >= 0.1 {
                let start = CMTime(seconds: r.start, preferredTimescale: 600)
                var duration = CMTime(seconds: r.length, preferredTimescale: 600)
                if CMTimeCompare(start + duration, assetDuration) > 0 { duration = assetDuration - start }
                guard CMTimeGetSeconds(duration) > 0.05 else { continue }
                let sourceRange = CMTimeRange(start: start, duration: duration)

                try videoTrack.insertTimeRange(sourceRange, of: srcVideo, at: cursor)
                for (k, srcAudio) in srcAudios.enumerated() {
                    if k >= audioTracks.count,
                       let added = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        audioTracks.append(added)
                    }
                    guard k < audioTracks.count else { break }
                    try audioTracks[k].insertTimeRange(sourceRange, of: srcAudio, at: cursor)
                }
                // 變速：把剛插入的這段縮放成 duration / speed（影像和所有音軌一起）
                var placed = duration
                if abs(clip.speed - 1) > 0.001 {
                    placed = CMTimeMultiplyByFloat64(duration, multiplier: 1 / clip.speed)
                    composition.scaleTimeRange(CMTimeRange(start: cursor, duration: duration), toDuration: placed)
                }
                segments.append((CMTimeRange(start: cursor, duration: placed), size, preferred))
                cursor = cursor + placed
            }
        }

        guard let first = segments.first else { throw ComposerError.empty }

        let renderSize = CGSize(width: (first.size.width / 2).rounded() * 2,
                                height: (first.size.height / 2).rounded() * 2)
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for seg in segments {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = seg.range
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            let scale = min(renderSize.width / seg.size.width, renderSize.height / seg.size.height)
            let tx = (renderSize.width - seg.size.width * scale) / 2
            let ty = (renderSize.height - seg.size.height * scale) / 2
            let t = seg.transform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: tx, y: ty))
            layer.setTransform(t, at: seg.range.start)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        return Result(composition: composition,
                      videoComposition: videoComposition,
                      duration: CMTimeGetSeconds(cursor),
                      renderSize: renderSize,
                      pieces: segments.map {
                          ClipRange(start: CMTimeGetSeconds($0.range.start), end: CMTimeGetSeconds($0.range.end))
                      })
    }
}
