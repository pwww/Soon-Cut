import Foundation

enum OutputStatus: String, Codable, CaseIterable, Identifiable {
    case latest = "最新"
    case uploaded = "已上傳"
    case archived = "封存"
    var id: String { rawValue }
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
