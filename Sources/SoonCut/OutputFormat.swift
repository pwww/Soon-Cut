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

/// 目前使用的版本
enum Edition {
    case openSource   // 自行從原始碼編譯
    case free         // App Store 免費版（有浮水印）
    case pro          // App Store 付費版（已買斷）

    var label: String {
        switch self {
        case .openSource: return "開源版"
        case .free: return "免費版"
        case .pro: return "付費版"
        }
    }

    var explanation: String {
        switch self {
        case .openSource:
            return "你使用的是從 GitHub 原始碼自行編譯的開源版（GPL-3.0），功能完整、沒有浮水印。"
        case .free:
            return "你使用的是 App Store 免費版，功能完整，輸出的影片右下角有小小的「SoonCut」浮水印。一次買斷即可移除浮水印。"
        case .pro:
            return "你使用的是 App Store 付費版，輸出的影片沒有浮水印。感謝支持！"
        }
    }
}

/// 免費版／付費版
enum Licensing {
    static var edition: Edition {
        #if APPSTORE
        return UserDefaults.standard.bool(forKey: "proUnlocked") ? .pro : .free   // 之後接 StoreKit 買斷
        #else
        return .openSource
        #endif
    }

    /// App Store 版未購買時，右下角加小浮水印；自行從原始碼編譯的開源版沒有浮水印。
    static var showsWatermark: Bool {
        #if APPSTORE
        return !UserDefaults.standard.bool(forKey: "proUnlocked")   // 之後接 StoreKit 買斷
        #else
        return UserDefaults.standard.bool(forKey: "debugWatermark")  // 開發時可打開測試
        #endif
    }
}
