import SwiftUI
import AppKit

struct OnboardingPage: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let body: String
}

/// 第一次打開時的教學引導；之後可從浮動視窗的「?」再打開
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var index = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(symbol: "sparkles",
                       title: "歡迎使用 Soon-Cut",
                       body: "一邊看影片一邊錄，剪好頭尾、自動上繁中字幕，幾分鐘就能做出可以發到 Threads 的短影音。"),
        OnboardingPage(symbol: "viewfinder",
                       title: "1. 框選錄影範圍",
                       body: "按「範圍」，直接在畫面上拖曳框選要錄的地方。開「9:16」可以鎖定直式。框好之後，範圍外圍會有一圈淡淡的虛線提醒你。"),
        OnboardingPage(symbol: "record.circle",
                       title: "2. 錄影",
                       body: "按「錄影」或 ⇧⌘R 開始，再按一次停止，可以連續錄好幾段。第一次錄影時，macOS 會請你允許「螢幕與系統錄音」權限。"),
        OnboardingPage(symbol: "scissors",
                       title: "3. 剪輯與排序",
                       body: "點片段，拖曳膠卷條兩端的黃色把手剪掉頭尾。左右拖動縮圖可以排順序，往下拖到「暫存區」就不會放進這次輸出。"),
        OnboardingPage(symbol: "captions.bubble",
                       title: "4. 上字幕、選比例",
                       body: "到「字幕」分頁按「產生字幕」，選擇語音和字幕語言後在本機轉寫（需要時自動翻譯），可以逐句修改。再選輸出比例，會標示適合哪些平台、長度有沒有超過上限。"),
        OnboardingPage(symbol: "hand.draw",
                       title: "5. 拖去上傳",
                       body: "按「輸出影片」後，到「輸出」分頁把影片卡片直接拖進 Threads 等網頁的上傳框就完成了。發完可以標記「已上傳」，舊影片可以封存。")
    ]

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                if index < pages.count - 1 {
                    Button("跳過") { onFinish() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 20)

            Spacer(minLength: 0)

            let page = pages[index]
            Group {
                if index == 0 {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                } else {
                    Image(systemName: page.symbol)
                        .font(.system(size: 54, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                        .frame(height: 96)
                }
            }

            Text(page.title)
                .font(.title2.weight(.semibold))
            Text(page.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            HStack {
                if index > 0 {
                    Button("上一步") { withAnimation { index -= 1 } }
                }
                Spacer()
                Button(index == pages.count - 1 ? "開始使用" : "下一步") {
                    if index == pages.count - 1 {
                        onFinish()
                    } else {
                        withAnimation { index += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 420)
    }
}

/// 教學引導視窗
@MainActor
final class OnboardingWindowController {
    static let doneKey = "onboardingDone"
    private var window: NSWindow?

    static var shouldShowOnLaunch: Bool { !UserDefaults.standard.bool(forKey: doneKey) }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)   // 在浮動視窗之上
        w.contentView = NSHostingView(rootView: OnboardingView { [weak self] in self?.finish() })
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
        window = nil
    }
}
