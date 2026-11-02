import AppKit
import AVFoundation

/// 一個片段＝某個影片檔的一段範圍。同一個檔案剪開後會有好幾個片段。
struct Clip: Identifiable {
    var id = UUID()
    let url: URL
    var duration: Double
    var thumbnail: NSImage?
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var isStaged = false   // 在暫存區：不放進這次剪輯與輸出

    var trimmedDuration: Double { max(0, trimEnd - trimStart) }
    var isTrimmed: Bool { trimStart > 0.01 || trimEnd < duration - 0.01 }
}

/// 片段順序與剪輯點，存在 Raw/library.json（不動原始影片）
struct LibraryEntry: Codable {
    var id: String?
    var file: String
    var trimStart: Double
    var trimEnd: Double
    var staged: Bool?
}

enum ClipStorage {
    static let minClipLength: Double = 0.5

    static var rootDir: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soon-Cut", isDirectory: true)
    }

    static var rawDir: URL {
        let dir = rootDir.appendingPathComponent("Raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var libraryURL: URL { rawDir.appendingPathComponent("library.json") }

    static func newClipURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return rawDir.appendingPathComponent("clip-\(f.string(from: Date())).mp4")
    }

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 匯入的影片：檔名加上時間避免重複
    static func importedClipURL(for source: URL) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.lowercased()
        return rawDir.appendingPathComponent("import-\(f.string(from: Date()))-\(base).\(ext.isEmpty ? "mp4" : ext)")
    }

    /// 依建立時間由舊到新
    static func existingClipURLs() -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }
    }

    static func loadLibrary() -> [LibraryEntry] {
        guard let data = try? Data(contentsOf: libraryURL) else { return [] }
        return (try? JSONDecoder().decode([LibraryEntry].self, from: data)) ?? []
    }

    static func saveLibrary(_ clips: [Clip]) {
        let entries = clips.map {
            LibraryEntry(id: $0.id.uuidString, file: $0.url.lastPathComponent,
                         trimStart: $0.trimStart, trimEnd: $0.trimEnd, staged: $0.isStaged)
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    /// 先照 library.json 的順序（同一個檔案可以有好幾段），再補上沒被記錄的新檔
    static func loadClips() async -> [Clip] {
        let entries = loadLibrary()
        let files = existingClipURLs()
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, $0) })

        var base: [String: Clip] = [:]   // 每個檔案只讀一次長度
        var clips: [Clip] = []
        for e in entries {
            guard let url = byName[e.file] else { continue }
            if base[e.file] == nil { base[e.file] = await makeClip(url: url) }
            guard var clip = base[e.file] else { continue }
            clip.id = e.id.flatMap(UUID.init(uuidString:)) ?? UUID()
            let end = min(e.trimEnd, clip.duration)
            let start = min(max(0, e.trimStart), max(0, end - minClipLength))
            if end - start >= minClipLength {
                clip.trimStart = start
                clip.trimEnd = end
            }
            clip.isStaged = e.staged ?? false
            if clip.trimStart > 0.1 {
                clip.thumbnail = await thumbnail(for: clip)
            }
            clips.append(clip)
        }
        for url in files where base[url.lastPathComponent] == nil {
            clips.append(await makeClip(url: url))
        }
        // 使用中的在前、暫存的在後
        return clips.filter { !$0.isStaged } + clips.filter { $0.isStaged }
    }

    /// 片段縮圖：取這一段開頭附近的畫面
    static func thumbnail(for clip: Clip) async -> NSImage? {
        let t = clip.trimStart + min(0.5, clip.trimmedDuration / 2)
        return await frame(of: AVURLAsset(url: clip.url), at: t, maxSize: 240)
    }

    static func makeClip(url: URL) async -> Clip {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let thumb = await frame(of: asset, at: min(0.5, max(duration / 2, 0)), maxSize: 240)
        return Clip(url: url, duration: duration, thumbnail: thumb, trimStart: 0, trimEnd: duration)
    }

    static func frame(of asset: AVAsset, at seconds: Double, maxSize: CGFloat) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
