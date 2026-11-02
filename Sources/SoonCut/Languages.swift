import Foundation

/// 影片裡說話的語言（給 Whisper 轉寫用）
enum SpeechLanguage: String, CaseIterable, Identifiable, Codable {
    case auto, zh, en, ja, ko, es, fr, de, th, vi, id

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return String(localized: "自動偵測")
        case .zh: return String(localized: "中文")
        case .en: return String(localized: "英文")
        case .ja: return String(localized: "日文")
        case .ko: return String(localized: "韓文")
        case .es: return String(localized: "西班牙文")
        case .fr: return String(localized: "法文")
        case .de: return String(localized: "德文")
        case .th: return String(localized: "泰文")
        case .vi: return String(localized: "越南文")
        case .id: return String(localized: "印尼文")
        }
    }

    /// Whisper 語言代碼；nil = 自動偵測
    var whisperCode: String? { self == .auto ? nil : rawValue }
}

/// 字幕要用的語言；跟語音不同時用 Apple 內建翻譯（本機）
enum SubtitleLanguage: String, CaseIterable, Identifiable, Codable {
    case same, zhHant, zhHans, en, ja, ko, es, fr, de, th, vi, id

    var id: String { rawValue }

    var label: String {
        switch self {
        case .same: return String(localized: "與語音相同")
        case .zhHant: return String(localized: "繁體中文")
        case .zhHans: return String(localized: "簡體中文")
        case .en: return String(localized: "英文")
        case .ja: return String(localized: "日文")
        case .ko: return String(localized: "韓文")
        case .es: return String(localized: "西班牙文")
        case .fr: return String(localized: "法文")
        case .de: return String(localized: "德文")
        case .th: return String(localized: "泰文")
        case .vi: return String(localized: "越南文")
        case .id: return String(localized: "印尼文")
        }
    }

    /// 翻譯目標的語言識別碼
    var localeIdentifier: String? {
        switch self {
        case .same: return nil
        case .zhHant: return "zh-Hant"
        case .zhHans: return "zh-Hans"
        default: return rawValue
        }
    }

    /// 對應的 Whisper 語言代碼（判斷要不要翻譯）
    var whisperBase: String? {
        switch self {
        case .same: return nil
        case .zhHant, .zhHans: return "zh"
        default: return rawValue
        }
    }

    /// 語音是 spoken 時，需不需要翻譯
    func needsTranslation(from spoken: String) -> Bool {
        guard let base = whisperBase else { return false }
        return base != spoken
    }
}

/// 中文字形轉換
enum ChineseScript {
    static func toTraditional(_ s: String) -> String {
        s.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? s
    }

    static func toSimplified(_ s: String) -> String {
        s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s
    }
}
