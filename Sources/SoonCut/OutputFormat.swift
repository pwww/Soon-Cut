import Foundation
import CoreGraphics

/// 社群平台與影片長度上限（2026-11 查證；平台規則常變動，數字取保守值）
enum Platform: String, CaseIterable, Identifiable {
    case threads = "Threads"
    case reels = "IG Reels"
    case igPost = "IG 貼文"
    case shorts = "YT Shorts"
    case youtube = "YouTube"
    case tiktok = "TikTok"

    var id: String { rawValue }

    /// 影片長度上限（秒）；nil = 對短影音來說沒有實際限制
    var maxDuration: Double? {
        switch self {
        case .threads: return 5 * 60      // Threads 影片最長 5 分鐘
        case .reels: return 3 * 60        // Reels 多數帳號 3 分鐘（新版逐步放寬）
        case .shorts: return 3 * 60       // Shorts 3 分鐘，且需直式或正方形
        case .tiktok: return 10 * 60      // 一般上傳 10 分鐘（部分帳號更長）
        case .igPost, .youtube: return nil
        }
    }
}

/// 輸出比例
enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case original
    case vertical    // 9:16
    case portrait    // 4:5
    case square      // 1:1
    case landscape   // 16:9

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "原始"
        case .vertical: return "9:16"
        case .portrait: return "4:5"
        case .square: return "1:1"
        case .landscape: return "16:9"
        }
    }

    /// 固定輸出尺寸；原始 = 跟著第一個片段
    var fixedSize: CGSize? {
        switch self {
        case .original: return nil
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .portrait: return CGSize(width: 1080, height: 1350)
        case .square: return CGSize(width: 1080, height: 1080)
        case .landscape: return CGSize(width: 1920, height: 1080)
        }
    }

    /// 這個比例適合發在哪些平台
    var platforms: [Platform] {
        switch self {
        case .original: return [.threads]
        case .vertical: return [.threads, .reels, .shorts, .tiktok]
        case .portrait: return [.threads, .igPost]
        case .square: return [.threads, .igPost, .shorts]
        case .landscape: return [.threads, .youtube]
        }
    }

    func canvas(base: CGSize) -> CGSize {
        fixedSize ?? CGSize(width: (base.width / 2).rounded() * 2, height: (base.height / 2).rounded() * 2)
    }
}

/// 輸出畫質：解析度（短邊）＋影片位元率
enum ExportQuality: String, CaseIterable, Identifiable, Codable {
    case high       // 1080p
    case standard   // 720p
    case small      // 540p

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "1080p"
        case .standard: return "720p"
        case .small: return "540p"
        }
    }

    var note: String {
        switch self {
        case .high: return "高畫質"
        case .standard: return "標準，社群建議"
        case .small: return "小檔案"
        }
    }

    /// 畫面短邊的像素
    var shortEdge: CGFloat {
        switch self {
        case .high: return 1080
        case .standard: return 720
        case .small: return 540
        }
    }

    /// 影片位元率（bits/s），H.264
    var videoBitrate: Int {
        switch self {
        case .high: return 8_000_000
        case .standard: return 4_000_000
        case .small: return 2_000_000
        }
    }

    static let audioBitrate = 128_000

    /// 依畫質縮放畫布；不放大，寬高取偶數
    func scaled(_ canvas: CGSize) -> CGSize {
        let short = min(canvas.width, canvas.height)
        let k = min(1, shortEdge / max(short, 1))
        return CGSize(width: max(2, (canvas.width * k / 2).rounded() * 2),
                      height: max(2, (canvas.height * k / 2).rounded() * 2))
    }

    /// 預估檔案大小（bytes）
    func estimatedBytes(duration: Double) -> Int64 {
        Int64(Double(videoBitrate + Self.audioBitrate) * duration / 8)
    }
}
