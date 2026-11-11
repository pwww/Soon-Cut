import AVFoundation
import AppKit

enum ExportError: LocalizedError {
    case cannotRead
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotRead: return String(localized: "無法讀取片段。")
        case .writeFailed(let reason): return String(localized: "寫入影片失敗：\(reason)")
        }
    }
}

/// 拼接片段 → 依比例合成（模糊背景）＋燒入字幕＋免費版浮水印 → 依畫質寫出 H.264 MP4
/// 用 AVAssetReader/Writer 自己指定解析度與位元率，檔案大小可控制。
enum Exporter {
    @MainActor
    static func export(clips: [Clip],
                       subtitles: [SubtitleSegment],
                       style: SubtitleStyle,
                       format: OutputFormat,
                       quality: ExportQuality,
                       to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let result = try await Composer.build(clips: clips)
        let canvas = quality.scaled(format.canvas(base: result.renderSize))
        let overlay = OverlayState()
        Renderer.prepareOverlay(overlay, subtitles: subtitles, style: style, canvas: canvas,
                                watermark: Licensing.showsWatermark)
        let videoComposition = Renderer.videoComposition(for: result.composition, canvas: canvas, overlay: overlay)

        try await write(asset: result.composition,
                        videoComposition: videoComposition,
                        canvas: canvas,
                        quality: quality,
                        duration: result.duration,
                        to: url,
                        progress: progress)
        return result.duration
    }

    private static func write(asset: AVAsset,
                              videoComposition: AVVideoComposition,
                              canvas: CGSize,
                              quality: ExportQuality,
                              duration: Double,
                              to url: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)

        // 讀取：合成後的畫面＋混好的聲音
        let reader = try AVAssetReader(asset: asset)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty else { throw ExportError.cannotRead }

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2
            ])
            output.audioTimePitchAlgorithm = .spectral   // 變速時保持音高
            reader.add(output)
            audioOutput = output
        }

        // 寫入：指定解析度與位元率
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: ExportQuality.audioBitrate
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else {
            throw ExportError.writeFailed(reader.error?.localizedDescription ?? String(localized: "無法開始讀取"))
        }
        guard writer.startWriting() else {
            throw ExportError.writeFailed(writer.error?.localizedDescription ?? String(localized: "無法開始寫入"))
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pump(from: videoOutput, to: videoInput, label: "video") { time in
                    if duration > 0 { progress(min(1, time / duration)) }
                }
            }
            if let audioOutput, let audioInput {
                group.addTask {
                    await pump(from: audioOutput, to: audioInput, label: "audio", onSample: nil)
                }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.writeFailed(reader.error?.localizedDescription ?? String(localized: "讀取中斷"))
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.writeFailed(writer.error?.localizedDescription ?? String(localized: "寫入中斷"))
        }
        progress(1)
    }

    /// 把讀到的樣本一路寫進去，直到讀完
    private static func pump(from output: AVAssetReaderOutput,
                             to input: AVAssetWriterInput,
                             label: String,
                             onSample: (@Sendable (Double) -> Void)?) async {
        let queue = DispatchQueue(label: "cc.aicolab.sooncut.export.\(label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onSample?(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
                    if !input.append(sample) {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
