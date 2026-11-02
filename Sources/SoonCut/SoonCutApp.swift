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

        NSApp.setActivationPolicy(.regular)
        let panel = FloatingPanel(rootView: MainPanelView().environmentObject(store))
        panel.orderFrontRegardless()
        self.panel = panel

        // 關掉浮動視窗時，淡色範圍框也一起收起來
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.panelVisible = false }
        }

        store.showOnboarding = { [weak self] in self?.onboarding.show() }
        store.appDidLaunch()
        if OnboardingWindowController.shouldShowOnLaunch {
            onboarding.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 點 Dock 圖示時把浮動視窗叫回來
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless()
        store.panelVisible = true
        return true
    }
}
