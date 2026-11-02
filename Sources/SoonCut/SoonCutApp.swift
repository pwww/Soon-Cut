import SwiftUI
import AppKit

@main
struct SoonCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()
    private var panel: FloatingPanel?
    private var closeObserver: NSObjectProtocol?
    private var miniObservers: [NSObjectProtocol] = []
    private let onboarding = OnboardingWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 同時只允許一個 SoonCut：已經有一個在跑就切過去，自己結束
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0 != NSRunningApplication.current }
            if let existing = others.first {
                existing.activate()
                NSApp.terminate(nil)
                return
            }
        }

        // 開 StoreKit：讀目前的 entitlement、抓價格、監聽 App 外完成的交易。
        // 開源版（非 APPSTORE 組態）這個呼叫是空的，不會連任何東西。
        LicenseStore.shared.start()

        NSApp.setActivationPolicy(.regular)
        // 直接把圖示設給 Dock，不受 macOS 圖示快取影響
        if let logo = NSImage(named: "AppLogo") {
            NSApp.applicationIconImage = logo
        }
        let panel = FloatingPanel(rootView: MainPanelView()
            .environmentObject(store)
            .environmentObject(LicenseStore.shared))
        panel.orderFrontRegardless()
        self.panel = panel

        // 關掉浮動視窗時，淡色範圍框也一起收起來
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.panelVisible = false }
        }

        // 縮到 Dock 時範圍框也收起來，還原時再出現
        miniObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMiniaturizeNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.panelVisible = false }
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didDeminiaturizeNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.panelVisible = true }
            }
        ]

        store.showOnboarding = { [weak self] in self?.onboarding.show() }
        store.appDidLaunch()
        if OnboardingWindowController.shouldShowOnLaunch {
            onboarding.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 點 Dock 圖示時把浮動視窗叫回來
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel?.isMiniaturized == true { panel?.deminiaturize(nil) }
        panel?.orderFrontRegardless()
        store.panelVisible = true
        return true
    }
}
