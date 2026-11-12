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

    /// 輸出清單跟著專案（影片檔仍放在共用的 Exports/）
    static var indexURL: URL { ClipStorage.currentProjectDir.appendingPathComponent("exports.json") }

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

    /// 影片已經不在（被拖到垃圾桶、在 Finder 刪掉或搬走）的 .srt 一起丟到垃圾桶
    static func trashOrphanTranscripts() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: exportsDir, includingPropertiesForKeys: nil) else { return }
        for srt in files where srt.pathExtension.lowercased() == "srt" {
            let video = srt.deletingPathExtension().appendingPathExtension("mp4")
            if !fm.fileExists(atPath: video.path) {
                try? fm.trashItem(at: srt, resultingItemURL: nil)
            }
        }
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

    /// 讀 SRT：回傳每一句的時間與文字（容許 , 或 . 當毫秒分隔、CRLF、檔頭 BOM）
    static func parse(_ text: String) -> [(start: Double, end: Double, text: String)] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var result: [(start: Double, end: Double, text: String)] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let t = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[t].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0]), let end = seconds(parts[1]) else { continue }
            let body = lines[(t + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespaces)
            result.append((start, end, body))
        }
        return result
    }

    private static func seconds(_ s: String) -> Double? {
        let clean = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let hms = clean.split(separator: ":")
        guard hms.count == 3, let h = Double(hms[0]), let m = Double(hms[1]), let sec = Double(hms[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    private static func timestamp(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}

// MARK: - 字幕校正資料夾：每個專案一份 SRT，讓本機 LLM 校正後存回來

/// ~/Movies/Soon-Cut/Captions/
///   <專案名稱>.srt  各專案的字幕（時間對應該專案的「全片」）；外部改完存檔，打開那個專案時會套回
///   README.md       給 LLM 的校正規則
///   glossary.md     使用者自己的術語、人名清單（不會被覆蓋）
enum CaptionWorkspace {
    static var dir: URL {
        let dir = ClipStorage.rootDir.appendingPathComponent("Captions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 專案的校正檔：用專案名稱當檔名（去掉檔名不能用的字元）；同名專案加上編號區分
    static func fileName(for project: ProjectInfo, among all: [ProjectInfo]) -> String {
        var base = project.name
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = String(localized: "專案") }
        let sameName = all.filter { $0.name == project.name }
        if sameName.count > 1 {
            base += "-" + String(project.id.uuidString.prefix(4))
        }
        return base + ".srt"
    }

    static func fileURL(for project: ProjectInfo, among all: [ProjectInfo]) -> URL {
        dir.appendingPathComponent(fileName(for: project, among: all))
    }

    static var readmeURL: URL { dir.appendingPathComponent("README.md") }
    static var glossaryURL: URL { dir.appendingPathComponent("glossary.md") }

    static func ensureFiles() {
        try? readme.write(to: readmeURL, atomically: true, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: glossaryURL.path) {
            try? glossary.write(to: glossaryURL, atomically: true, encoding: .utf8)
        }
    }

    static let readme = """
    # Soon-Cut 字幕校正資料夾 / Caption proofreading folder

    每個 `.srt` 是一個 Soon-Cut 專案的字幕，檔名就是專案名稱（例如 `市民大道.srt`）。請校正後**直接存回同一個檔案**，Soon-Cut 會自動套用到那個專案；同時校正好幾個專案也不會互相影響。
    Each `.srt` holds one Soon-Cut project's captions, named after the project (e.g. `Demo.srt`). Fix it and **save it back to the same file** — Soon-Cut applies the changes to that project. Several projects can be proofread at once without affecting each other.

    ## 請修正 / Please fix
    - 錯別字、同音字、斷詞錯誤（語音辨識常見）／typos and sound-alike errors from speech recognition
    - 人名、地名、品牌、專有名詞、術語（可上網查證正確寫法）／names, places, brands and technical terms (look them up if needed)
    - 不通順或前後邏輯對不上的用字／wording that doesn't make sense in context
    - 參考 `glossary.md` 裡的術語與人名／use the terms and names in `glossary.md`

    ## 請不要 / Please don't
    - 改編號或時間軸 `00:00:00,000 --> ...`／change the numbers or timestamps
    - 合併、拆分、新增或刪除句子（句數要一樣）／merge, split, add or remove lines (keep the same count)
    - 加上說明文字或 Markdown／add notes or Markdown to the SRT

    要從影片剪掉某一句，請回到 Soon-Cut 按那一句旁邊的剪刀。
    To cut a line out of the video, use the scissors next to it in Soon-Cut.
    """

    static let glossary = """
    # 術語與人名 / Glossary

    在這裡寫下影片會出現的正確寫法，LLM 校正時會參考。這個檔案不會被 Soon-Cut 覆蓋。
    List the correct spellings that appear in your videos. Soon-Cut never overwrites this file.

    - 
    """
}
