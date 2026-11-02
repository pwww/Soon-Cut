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
        case .noAudio: return "這個片段沒有聲音，無法轉寫。"
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
    func transcribe(asset: AVAsset, language: String?) async throws -> (segments: [SubtitleSegment], language: String) {
        let audioURL = try await Self.extractAudio(from: asset)
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

        let results = try await whisper.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let spoken = language ?? results.first?.language ?? "zh"
        let segments: [SubtitleSegment] = results.flatMap { $0.segments }.compactMap { seg in
            let text = Self.clean(seg.text, chinese: spoken == "zh")
            guard !text.isEmpty else { return nil }
            return SubtitleSegment(start: Double(seg.start), end: Double(seg.end), text: text)
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
    static func extractAudio(from asset: AVAsset) async throws -> URL {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw TranscribeError.noAudio }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscribeError.noAudio
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sooncut-\(UUID().uuidString).m4a")
        try await session.export(to: out, as: .m4a)
        return out
    }
}
