import Foundation
#if APPSTORE
import StoreKit
#endif

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

/// 版本判定。**算圖與輸出路徑都從這裡讀**，它不綁 actor，任何執行緒都能問。
///
/// ## ⚠️ 開源版刻意不含 StoreKit
///
/// `#if APPSTORE` 之外，`isPro` 恆為 true、`edition` 恆為 `.openSource`、沒有浮水印。
/// 那是 GPL 版本的承諾：clone 下來自己編譯的人拿到完整功能，
/// 不需要 Apple 開發者帳號，也不會連到 App Store。
enum Licensing {
    static let productID = "cc.aicolab.SoonCut.pro"

    private static let lock = NSLock()
    #if APPSTORE
    private static var _isPro = false      // 真實狀態由 LicenseStore 從 StoreKit 填入
    #else
    private static var _isPro = true
    #endif

    /// 由 `LicenseStore` 單向寫入。**不要從別處設值**——
    /// 多個寫入點是這類旗標長期靜靜偏掉的標準成因。
    static var isPro: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isPro }
        set { lock.lock(); _isPro = newValue; lock.unlock() }
    }

    static var edition: Edition {
        #if APPSTORE
        return isPro ? .pro : .free
        #else
        return .openSource
        #endif
    }

    /// App Store 版未購買時，右下角加小浮水印。
    static var showsWatermark: Bool {
        #if APPSTORE
        return !isPro
        #else
        // 開源版沒有浮水印。開發時要驗合成版面可以手動打開這個開關。
        return UserDefaults.standard.bool(forKey: "debugWatermark")
        #endif
    }
}

/// 畫面用的買斷狀態與購買流程。
///
/// ## ⚠️ 為什麼不是 UserDefaults
///
/// 這裡原本是 `UserDefaults.standard.bool(forKey: "proUnlocked")`，那有三個問題：
///
/// 1. **一行指令就破解**：`defaults write cc.aicolab.SoonCut proUnlocked -bool YES`
/// 2. **換機不會跟著走**，付了錢在新電腦上還是免費版
/// 3. **Apple 要求要有「回復購買」**，沒有真實交易紀錄就做不出來
///
/// 現在的唯一真相來源是 StoreKit 2 的 `Transaction.currentEntitlements`，那是簽章驗證過的。
@MainActor
final class LicenseStore: ObservableObject {
    static let shared = LicenseStore()

    /// ⚠️ 這裡用 `didSet` 單點同步到 `Licensing`，不要在各個設值點各寫一次。
    @Published private(set) var isPro: Bool = Licensing.isPro {
        didSet { Licensing.isPro = isPro }
    }

    @Published private(set) var priceText: String?
    @Published var purchaseError: String?
    @Published private(set) var isWorking = false

    var edition: Edition { Licensing.edition }

    private init() {}

    func start() {
        #if APPSTORE
        Task {
            await refresh()
            await loadPrice()
            // 交易可能在 App 之外完成（家長核准、另一台裝置購買）。
            for await update in Transaction.updates {
                if case .verified(let t) = update {
                    await t.finish()
                    await refresh()
                }
            }
        }
        #endif
    }

    #if APPSTORE
    /// 唯一的真相來源：StoreKit 自己簽章驗證過的 entitlement。
    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result,
               t.productID == Licensing.productID,
               t.revocationDate == nil {
                owned = true
            }
        }
        isPro = owned
    }

    private func loadPrice() async {
        // 拿不到價格時維持 nil。**不要寫死一個假價格**——割り勘 把初始值寫死成
        // "¥500"，StoreKit 拿不到商品時按鈕照樣喊價、下面卻寫著「無法取得商品資訊」，
        // 同一個畫面自相矛盾。
        guard let product = try? await Product.products(for: [Licensing.productID]).first else { return }
        priceText = product.displayPrice
    }

    func purchase() async {
        purchaseError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            guard let product = try await Product.products(for: [Licensing.productID]).first else {
                purchaseError = "暫時無法取得商品資訊，請確認網路後再試。"
                return
            }
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let t) = verification else {
                    purchaseError = "這筆購買無法驗證。"
                    return
                }
                await t.finish()
                await refresh()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    /// Apple 要求買斷型 App 必須提供這顆按鈕。
    /// ⚠️ `StoreKit.AppStore` 要寫全名——這支 App 自己有一個叫 `AppStore` 的
    /// ObservableObject（`AppStore.swift`），不加前綴會解析到那一個。
    func restore() async {
        purchaseError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await StoreKit.AppStore.sync()
            await refresh()
            if !isPro { purchaseError = "找不到可以回復的購買紀錄。" }
        } catch {
            purchaseError = error.localizedDescription
        }
    }
    #else
    func refresh() async {}
    func purchase() async {}
    func restore() async {}
    #endif
}
