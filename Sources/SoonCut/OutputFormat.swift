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

/// 免費版／付費版
enum Licensing {
    /// App Store 版未購買時，右下角加小浮水印；自行從原始碼編譯的開源版沒有浮水印。
    static var showsWatermark: Bool {
        #if APPSTORE
        return !UserDefaults.standard.bool(forKey: "proUnlocked")   // 之後接 StoreKit 買斷
        #else
        return UserDefaults.standard.bool(forKey: "debugWatermark")  // 開發時可打開測試
        #endif
    }
}
