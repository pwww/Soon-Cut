import Foundation

enum OutputStatus: String, Codable, CaseIterable, Identifiable {
    // ⚠️ rawValue 會寫進 exports.json，**不要為了翻譯而改動**——
    // 改了之後舊的輸出紀錄會解不開，使用者的「已上傳／封存」整批消失。
    // 顯示一律走 `label`。
    case latest = "最新"
    case uploaded = "已上傳"
    case archived = "封存"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .latest: return String(localized: "最新")
        case .uploaded: return String(localized: "已上傳")
        case .archived: return String(localized: "封存")
        }
    }
}

struct ExportItem: Codable, Identifiable {
    var file: String
    var status: OutputStatus
    var createdAt: Date
    var duration: Double
    var format: String?     // 輸出比例，例如「9:16」

    var id: String { file }
    var url: URL { OutputLibrary.exportsDir.appendingPathComponent(file) }
}

/// 輸出的影片存在 ~/Movies/Soon-Cut/Exports，分層資訊存在 exports.json
enum OutputLibrary {
    static var exportsDir: URL {
        let dir = ClipStorage.rootDir.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var indexURL: URL { exportsDir.appendingPathComponent("exports.json") }

    static func newExportURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return exportsDir.appendingPathComponent("soon-cut-\(f.string(from: Date())).mp4")
    }

    /// 只回傳檔案還在的項目，新的在前
    static func load() -> [ExportItem] {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder().decode([ExportItem].self, from: data) else { return [] }
        return items
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ items: [ExportItem]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

// MARK: - 字幕稿（SRT）：跟影片同名、放在同一個資料夾

/// 輸出影片時順便寫一份 .srt，時間對應輸出的影片。
/// 用途：讓 Claude 等工具直接讀字幕稿寫社群貼文，不用重新轉寫影片；也能上傳到 YouTube 當 CC 字幕。
enum SRTWriter {
    static func url(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("srt")
    }

    static func srt(from segments: [SubtitleSegment]) -> String {
        let lines = segments
            .filter { $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        return lines.enumerated().map { i, seg in
            "\(i + 1)\n\(timestamp(seg.start)) --> \(timestamp(seg.end))\n\(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }.joined(separator: "\n")
    }

    /// 沒有字幕就不寫檔
    static func write(_ segments: [SubtitleSegment], nextTo video: URL) throws {
        let text = srt(from: segments)
        guard !text.isEmpty else { return }
        try text.write(to: url(for: video), atomically: true, encoding: .utf8)
    }

    private static func timestamp(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
