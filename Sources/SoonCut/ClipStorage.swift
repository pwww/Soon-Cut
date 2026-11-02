import AppKit
import AVFoundation

struct Clip: Identifiable {
    var id: URL { url }
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

    /// 依建立時間由舊到新
    static func existingClipURLs() -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "mp4" }
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
        let entries = clips.map { LibraryEntry(file: $0.url.lastPathComponent, trimStart: $0.trimStart, trimEnd: $0.trimEnd, staged: $0.isStaged) }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    /// 先照 library.json 的順序，再補上新檔（依建立時間）
    static func loadClips() async -> [Clip] {
        let entries = loadLibrary()
        let files = existingClipURLs()
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, $0) })
        var ordered: [URL] = entries.compactMap { byName[$0.file] }
        let known = Set(ordered.map(\.lastPathComponent))
        ordered += files.filter { !known.contains($0.lastPathComponent) }

        var clips: [Clip] = []
        for url in ordered {
            var clip = await makeClip(url: url)
            if let e = entries.first(where: { $0.file == url.lastPathComponent }) {
                let end = min(e.trimEnd, clip.duration)
                let start = min(max(0, e.trimStart), max(0, end - minClipLength))
                if end - start >= minClipLength {
                    clip.trimStart = start
                    clip.trimEnd = end
                }
                clip.isStaged = e.staged ?? false
            }
            clips.append(clip)
        }
        // 使用中的在前、暫存的在後
        return clips.filter { !$0.isStaged } + clips.filter { $0.isStaged }
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
