import AppKit
import AVFoundation

/// 片段裡要保留的一段（膠卷條上的一個黃色區塊）
struct ClipRange: Codable, Equatable, Hashable {
    var start: Double
    var end: Double
    var length: Double { max(0, end - start) }
}

/// 一個片段＝一個影片檔，可以保留好幾段（剪開後中間的空隙會被跳過）
struct Clip: Identifiable {
    var id = UUID()
    let url: URL
    var duration: Double
    var thumbnail: NSImage?
    var ranges: [ClipRange] = []
    var isStaged = false   // 在暫存區：不放進這次剪輯與輸出
    /// 播放速度（0.5＝慢一倍、2＝快一倍）；預覽與輸出都照這個速度
    var speed: Double = 1

    var trimStart: Double { ranges.first?.start ?? 0 }
    var trimEnd: Double { ranges.last?.end ?? duration }
    var trimmedDuration: Double { ranges.reduce(0) { $0 + $1.length } }
    /// 套用速度後在成片裡的長度
    var playbackDuration: Double { trimmedDuration / max(speed, 0.1) }
    var isTrimmed: Bool { ranges.count > 1 || trimStart > 0.01 || trimEnd < duration - 0.01 }

    /// 包含 time 的區段索引
    func rangeIndex(containing time: Double) -> Int? {
        ranges.firstIndex { time >= $0.start && time < $0.end }
    }
}

/// 片段順序與剪輯點，存在 Raw/library.json（不動原始影片）
struct LibraryEntry: Codable {
    var id: String?
    var file: String
    var trimStart: Double
    var trimEnd: Double
    var staged: Bool?
    var ranges: [ClipRange]?
    var speed: Double?
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
                         trimStart: $0.trimStart, trimEnd: $0.trimEnd, staged: $0.isStaged,
                         ranges: $0.ranges, speed: $0.speed == 1 ? nil : $0.speed)
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
            let saved = e.ranges ?? [ClipRange(start: e.trimStart, end: e.trimEnd)]
            let cleaned = sanitize(saved, duration: clip.duration)
            if !cleaned.isEmpty { clip.ranges = cleaned }
            clip.isStaged = e.staged ?? false
            clip.speed = e.speed ?? 1
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
        return Clip(url: url, duration: duration, thumbnail: thumb,
                    ranges: [ClipRange(start: 0, end: duration)])
    }

    /// 排序、限制在影片長度內、去掉太短或重疊的區段
    static func sanitize(_ ranges: [ClipRange], duration: Double) -> [ClipRange] {
        var result: [ClipRange] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) {
            var x = ClipRange(start: max(0, r.start), end: min(duration, r.end))
            if let last = result.last, x.start < last.end { x.start = last.end }
            if x.length >= minClipLength { result.append(x) }
        }
        return result
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
