import SwiftUI
#if APPSTORE
import AppKit
import StoreKit

/// 買斷頁。**整個檔案只在 App Store 版編譯**——開源版不含 StoreKit，
/// 也沒有任何付費入口（見 `Licensing.swift` 的說明）。
///
/// ## ⚠️ 落閘位置比文案重要
///
/// 這張牆有兩個入口，指向同一個畫面：
///
/// 1. **輸出列**（`SubtitleEditor.actionBar`）——使用者此刻正看著預覽畫面上
///    那個浮水印，是唯一「想移除它」的動機已經存在的時刻。
/// 2. **版本標示**（`EditionBadge`）——自己找上門的人。
///
/// 一張牆多個觸發點，不要為每個入口各做一張。
struct PaywallSheet: View {
    @EnvironmentObject private var license: LicenseStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 14)
            points
            Spacer(minLength: 18)
            if let error = license.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            buttons
        }
        .padding(22)
        .frame(width: 340)
        .onDisappear { license.clearError() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "drop.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("移除浮水印")
                .font(.title3.bold())
            Text("免費版功能完整——錄影、字幕、剪輯、各種比例的輸出都沒有限制，只有輸出的影片右下角會有一個小小的「SoonCut」。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("sparkles", "輸出的影片不再有浮水印")
            row("infinity", "一次付費，永久有效")
            row("macbook.and.iphone", "同一個 Apple 帳號的其他 Mac 也能用")
            row("lock.shield", "影片與語音一樣只在你的 Mac 上處理")
        }
    }

    // ⚠️ text 必須是 LocalizedStringKey 不是 String，否則這四行不會被抽進字串目錄
    private func row(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button {
                Task { await license.purchase(); if license.isPro { dismiss() } }
            } label: {
                HStack(spacing: 6) {
                    if license.isWorking { ProgressView().controlSize(.small) }
                    // ⚠️ 拿不到價格時不要寫死一個假數字（割り勘踩過：按鈕喊價、
                    // 下面同時寫著「無法取得商品資訊」，同一個畫面自相矛盾）。
                    Text(license.priceText.map { "買斷 \($0)" } ?? "買斷")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(license.isWorking)

            // Apple 的審查會確認這一點：買斷必須明說不是訂閱。
            Text("一次買斷，不是訂閱，不會自動續訂。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("回復購買") {
                    Task { await license.restore(); if license.isPro { dismiss() } }
                }
                .disabled(license.isWorking)
                Spacer()
                Button("稍後再說") { dismiss() }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }
}

/// 已購買後的致謝（從版本標示進來時用）
struct ProThanksView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("已移除浮水印", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.tint)
            Text("感謝支持。輸出的影片不會再有浮水印。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 260)
    }
}

/// 輸出列上的入口：預覽畫面此刻就有浮水印，動機已經在了。
struct WatermarkNoticeButton: View {
    @EnvironmentObject private var license: LicenseStore
    @State private var showPaywall = false

    var body: some View {
        if !license.isPro {
            Button {
                showPaywall = true
            } label: {
                Label("含浮水印", systemImage: "drop.fill")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .help("輸出的影片右下角會有小浮水印，一次買斷即可移除")
            .sheet(isPresented: $showPaywall) { PaywallSheet() }
        }
    }
}
#endif
