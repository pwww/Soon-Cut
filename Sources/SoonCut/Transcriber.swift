import Foundation
import AVFoundation
import WhisperKit

struct SubtitleSegment: Identifiable, Hashable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

enum TranscribeError: LocalizedError {
    case noAudio

    var errorDescription: String? {
        switch self {
        case .noAudio: return String(localized: "這個片段沒有聲音，無法轉寫。")
        }
    }
}

enum ModelLoadPhase: Sendable {
    case downloading(Double)   // 0...1
    case preparing
}

/// WhisperKit 本機轉寫，固定中文，輸出轉成繁體
actor Transcriber {
    static let modelName = "large-v3-v20240930_turbo"
    /// Hugging Face 上這個模型的實際大小（argmaxinc/whisperkit-coreml，約 1.6 GB）
    static let modelDownloadBytes: Int64 = 1_638_464_446
    private static let folderKey = "whisperModelFolder"

    private var pipe: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?

    var isModelLoaded: Bool { pipe != nil }

    /// 模型放在 ~/Library/Application Support/Soon-Cut/Models（不會碰到「文件」資料夾權限）
    static var modelsBase: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soon-Cut/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 模型已經下載過
    static var isModelDownloaded: Bool {
        guard let path = UserDefaults.standard.string(forKey: folderKey) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 第一次：下載（有進度）→ 準備（Core ML 編譯，約 1–2 分鐘）。之後只需要載入。
    func loadModel(onPhase: @escaping @Sendable (ModelLoadPhase) -> Void = { _ in }) async throws -> WhisperKit {
        if let pipe { return pipe }
        if let loadTask { return try await loadTask.value }   // 背景預載中，等同一個工作

        let task = Task { () throws -> WhisperKit in
            let folder: URL
            if Self.isModelDownloaded, let saved = UserDefaults.standard.string(forKey: Self.folderKey) {
                folder = URL(fileURLWithPath: saved)
            } else {
                onPhase(.downloading(0))
                folder = try await WhisperKit.download(
                    variant: Self.modelName,
                    downloadBase: Self.modelsBase,
                    progressCallback: { progress in
                        onPhase(.downloading(progress.fractionCompleted))
                    }
                )
                UserDefaults.standard.set(folder.path, forKey: Self.folderKey)
            }
            onPhase(.preparing)
            return try await WhisperKit(WhisperKitConfig(modelFolder: folder.path))
        }
        loadTask = task
        do {
            let loaded = try await task.value
            pipe = loaded
            loadTask = nil
            return loaded
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// 轉寫整條拼接好的時間軸（AVComposition）或單一影片
    /// - Parameter language: Whisper 語言代碼；nil = 自動偵測
    /// - Returns: 字幕句子，以及實際的語音語言代碼。中文一律先轉成繁體。
    /// 逐段轉寫整條時間軸：每一小段（每個黃色區段）分開轉，再把時間對回時間軸。
    /// 某一段轉到一半就停（Whisper 偶爾會這樣）時，從停下的地方接著轉。
    func transcribe(asset: AVAsset, pieces: [ClipRange], language: String?) async throws -> (segments: [SubtitleSegment], language: String) {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw TranscribeError.noAudio }
        var spoken = language
        var all: [SubtitleSegment] = []

        for piece in pieces where piece.length >= 0.5 {
            let firstIndex = all.count
            var offset = piece.start
            var attempts = 0
            while piece.end - offset > 1.5 && attempts < 12 {
                attempts += 1
                let range = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600),
                                        end: CMTime(seconds: piece.end, preferredTimescale: 600))
                let result = try await transcribeRange(asset: asset, range: range, language: spoken)
                if spoken == nil { spoken = result.language }   // 自動偵測：以第一段為準，後面固定
                let segs = result.segments.compactMap { seg -> SubtitleSegment? in
                    let start = offset + seg.start
                    let end = min(piece.end, offset + seg.end)
                    guard end > start else { return nil }
                    return SubtitleSegment(start: start, end: end, text: seg.text)
                }
                guard let lastEnd = segs.last?.end else { break }   // 後面沒有說話
                all += segs
                if piece.end - lastEnd <= 2 { break }               // 這一段轉完了
                offset = max(lastEnd, offset + 1)                   // 停在中間：從停下的地方接著轉
            }

            // 補洞：Whisper 有時會把整個 30 秒視窗判成「沒說話」直接跳過（新聞、背景音多時常見），
            // 字幕就會整段消失。找出這一段裡超過 3 秒沒有字幕的地方，放寬門檻再轉一次。
            let found = all[firstIndex...].sorted { $0.start < $1.start }
            var holes: [ClipRange] = []
            var cursor = piece.start
            for seg in found {
                if seg.start - cursor > Self.holeThreshold { holes.append(ClipRange(start: cursor, end: seg.start)) }
                cursor = max(cursor, seg.end)
            }
            if piece.end - cursor > Self.holeThreshold { holes.append(ClipRange(start: cursor, end: piece.end)) }

            for hole in holes {
                // 長的洞切成 25 秒一段（不靠 VAD 切，VAD 正是會漏掉的那一關）
                var windowStart = max(piece.start, hole.start - 0.3)
                let holeEnd = min(piece.end, hole.end + 0.3)
                while holeEnd - windowStart > 1.0 {
                    let windowEnd = min(holeEnd, windowStart + 25)
                    let range = CMTimeRange(start: CMTime(seconds: windowStart, preferredTimescale: 600),
                                            end: CMTime(seconds: windowEnd, preferredTimescale: 600))
                    if let result = try? await transcribeRange(asset: asset, range: range, language: spoken, relaxed: true) {
                        for seg in result.segments {
                            let start = max(hole.start, windowStart + seg.start)
                            let end = min(hole.end, windowStart + seg.end)
                            guard end - start > 0.2, !Self.looksLikeHallucination(seg.text) else { continue }
                            all.append(SubtitleSegment(start: start, end: end, text: seg.text))
                        }
                    }
                    windowStart = windowEnd
                }
            }
        }
        all.sort { $0.start < $1.start }
        let lang = spoken ?? "zh"
        let cleaned = all.compactMap { seg -> SubtitleSegment? in
            let text = Self.clean(seg.text, chinese: lang == "zh")
            guard !text.isEmpty else { return nil }
            return SubtitleSegment(start: seg.start, end: seg.end, text: text)
        }
        return (cleaned, lang)
    }

    /// 轉寫時間軸上的一小段；回傳的時間從這一小段的開頭算起
    /// 超過這麼多秒沒有字幕，就當成可能漏掉、補轉一次
    static let holeThreshold: Double = 3

    /// 放寬門檻時，Whisper 在真正安靜的地方容易「腦補」出這類句子，丟掉
    static func looksLikeHallucination(_ text: String) -> Bool {
        let t = text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        let patterns = ["訂閱", "订阅", "點贊", "点赞", "打賞", "打赏", "字幕由", "字幕製作", "字幕制作",
                        "明鏡", "明镜", "Amara", "謝謝觀看", "谢谢观看", "感謝收看", "感谢收看",
                        "Thank you for watching", "Subtitles by"]
        if patterns.contains(where: { t.localizedCaseInsensitiveContains($0) }) { return true }
        // 同一個字重複一大串（例如「啊啊啊啊啊啊」）
        if let first = t.first, t.count >= 6, t.allSatisfy({ $0 == first }) { return true }
        return false
    }

    /// - Parameter relaxed: 補洞用：不切 VAD、不因「像沒說話」或信心低而跳過視窗
    private func transcribeRange(asset: AVAsset, range: CMTimeRange, language: String?,
                                 relaxed: Bool = false) async throws -> (segments: [SubtitleSegment], language: String) {
        let audioURL = try await Self.extractAudio(from: asset, timeRange: range)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let whisper = try await loadModel()
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = (language == nil)
        options.usePrefillPrompt = true
        options.temperature = 0
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.chunkingStrategy = .vad
        if relaxed {
            options.chunkingStrategy = nil
            options.noSpeechThreshold = nil
            options.logProbThreshold = nil
            options.firstTokenLogProbThreshold = nil
        }

        let results = try await whisper.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let spoken = language ?? results.first?.language ?? "zh"
        let segments = results.flatMap { $0.segments }.map {
            SubtitleSegment(start: Double($0.start), end: Double($0.end), text: $0.text)
        }
        return (segments, spoken)
    }

    /// 去掉特殊 token；中文轉成繁體（只有中文才轉，避免改到日文漢字）
    static func clean(_ raw: String, chinese: Bool) -> String {
        let noTokens = raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        let trimmed = noTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        return chinese ? ChineseScript.toTraditional(trimmed) : trimmed
    }

    /// 從 MP4 抽出音軌成暫存 m4a
    static func extractAudio(from asset: AVAsset, timeRange: CMTimeRange? = nil) async throws -> URL {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw TranscribeError.noAudio }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscribeError.noAudio
        }
        if let timeRange { session.timeRange = timeRange }
        session.audioTimePitchAlgorithm = .spectral   // 變速片段保持音高，辨識比較準
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sooncut-\(UUID().uuidString).m4a")
        try await session.export(to: out, as: .m4a)
        return out
    }
}
