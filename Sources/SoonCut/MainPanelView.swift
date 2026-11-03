import SwiftUI
import UniformTypeIdentifiers

struct MainPanelView: View {
    @EnvironmentObject var store: AppStore
    @State private var windowDrag: (mouse: NSPoint, origin: NSPoint)?
    @AppStorage("clipsCollapsed") private var clipsCollapsed = false
    @AppStorage("stagingCollapsed") private var stagingCollapsed = false
    @AppStorage("tabsCollapsed") private var tabsCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            regionInfo
            Divider()
            clipsSection
            previewSection
            if let msg = store.errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 按住任何空白處都能拖動視窗；縮圖、膠卷條等自己有拖曳的地方優先。
        // 自己搬視窗（不用系統的拖動），避免拖到螢幕上緣被系統貼齊卡住。
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in
                    guard let panel = FloatingPanel.current else { return }
                    let mouse = NSEvent.mouseLocation
                    if windowDrag == nil { windowDrag = (mouse, panel.frame.origin) }
                    guard let start = windowDrag else { return }
                    panel.move(to: NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                           y: start.origin.y + mouse.y - start.mouse.y))
                }
                .onEnded { _ in windowDrag = nil }
        )
        .overlay(alignment: .top) {
            // 拖動提示
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            // 右上角 App 圖示與名稱（不擋拖動視窗）
            HStack(spacing: 5) {
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                Text("Soon-Cut")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 5)
            .padding(.trailing, 14)
            .allowsHitTesting(false)
        }
    }

    // MARK: 快捷列

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                store.selectRegion()
            } label: {
                Label("範圍", systemImage: "viewfinder")
                    .lineLimit(1)
            }
            .fixedSize()   // 文字一定完整顯示；視窗最小寬度會跟著撐開
            .disabled(store.isRecording)
            .help("在畫面上拖曳框選錄影範圍")

            Button {
                store.toggleRecording()
            } label: {
                Label(store.isRecording ? formatTime(store.elapsed) : String(localized: "錄影"),
                      systemImage: store.isRecording ? "stop.circle.fill" : "record.circle")
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize()
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy)
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Spacer()

            Toggle(isOn: $store.shortsMode) {
                Text("9:16")
            }
            .toggleStyle(.button)
            .fixedSize()
            .disabled(store.isRecording)
            .help("Shorts 模式：框選鎖定 9:16")

            Toggle(isOn: $store.captureSystemAudio) {
                Image(systemName: store.captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .toggleStyle(.button)
            .disabled(store.isRecording)
            .help("錄電腦播放的聲音")

            Toggle(isOn: $store.captureMicrophone) {
                Image(systemName: store.captureMicrophone ? "mic.fill" : "mic.slash")
            }
            .toggleStyle(.button)
            .disabled(store.isRecording)
            .help("同時錄麥克風（右鍵選擇麥克風）")
            .contextMenu { microphoneMenu }

            Button {
                store.pinned.toggle()
            } label: {
                Image(systemName: store.pinned ? "pin.fill" : "pin.slash")
                    .foregroundStyle(store.pinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(store.pinned ? "已固定在最上層（按一下取消，視窗可以被其他視窗蓋住）" : "沒有固定（按一下固定在最上層）")

            LanguageMenu()

            Button {
                store.showOnboarding?()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("使用教學")
        }
        .controlSize(.large)
    }

    private var regionInfo: some View {
        HStack {
            Group {
                if let r = store.region {
                    Text("範圍 \(Int(r.rect.width)) × \(Int(r.rect.height)) pt")
                } else {
                    Text("尚未框選範圍，先按「範圍」")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            EditionBadge()
        }
    }

    // MARK: 片段（使用中＋暫存區）

    private var clipsSection: some View {
        let active = store.activeClips
        let staged = store.stagedClips
        let total = active.reduce(0) { $0 + $1.trimmedDuration }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                CollapseChevron(collapsed: $clipsCollapsed)
                Text("剪輯片段").font(.headline)
                Text("\(active.count) 段 · \(formatTime(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.importVideos()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("匯入影片（也可以直接把影片拖進這裡）")
                Button {
                    store.openRawFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("打開片段資料夾")
            }

            if !clipsCollapsed {
                if active.isEmpty {
                    emptyRow(staged.isEmpty ? "錄完或匯入的片段會出現在這裡（也可以把影片拖進來）" : "把暫存區的片段往上拖回來",
                             height: ClipRow.mainSize.height)
                } else {
                    ClipRow(clips: active, staged: false)
                }
            }

            HStack {
                CollapseChevron(collapsed: $stagingCollapsed)
                Text("暫存區").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(staged.count)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text("往下拖＝暫存，不放進這次輸出")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)

            if !stagingCollapsed {
                if staged.isEmpty {
                    emptyRow("沒有暫存的片段", height: ClipRow.stagedSize.height)
                } else {
                    ClipRow(clips: staged, staged: true)
                }
            }
        }
        // 從 Finder 拖影片進來＝匯入
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter { ClipStorage.videoExtensions.contains($0.pathExtension.lowercased()) }
            guard !videos.isEmpty else { return false }
            store.importFiles(videos)
            return true
        }
    }

    @ViewBuilder
    private var microphoneMenu: some View {
        Button {
            store.microphoneID = nil
        } label: {
            if store.microphoneID == nil { Label("系統預設麥克風", systemImage: "checkmark") } else { Text("系統預設麥克風") }
        }
        Divider()
        ForEach(AppStore.microphones()) { mic in
            Button {
                store.microphoneID = mic.id
                store.captureMicrophone = true
            } label: {
                if store.microphoneID == mic.id { Label(mic.name, systemImage: "checkmark") } else { Text(mic.name) }
            }
        }
    }

    // ⚠️ LocalizedStringKey 不是 String，否則呼叫端那些字串不會被抽進字串目錄
    private func emptyRow(_ text: LocalizedStringKey, height: CGFloat) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4])))
    }

    // MARK: 預覽

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CollapseChevron(collapsed: $tabsCollapsed)
                Picker("", selection: $store.previewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: store.previewMode) {
                    // 點分頁時自動展開
                    if tabsCollapsed { withAnimation(.easeOut(duration: 0.18)) { tabsCollapsed = false } }
                }
            }

            if !tabsCollapsed {
            switch store.previewMode {
            case .clip:
                if let clip = store.selectedClip {
                    ClipEditor(clip: clip, isRecording: store.isRecording)
                } else {
                    placeholder("剪輯", store.clips.isEmpty ? "錄好片段後會在這裡預覽與剪輯" : "點上面的片段就會在這裡播放與剪輯")
                }
            case .subtitle:
                if store.activeClips.isEmpty {
                    placeholder("字幕", "把要用的片段放在「剪輯片段」，這裡會接起來上字幕、輸出")
                } else {
                    SubtitleEditor(isRecording: store.isRecording)
                }
            case .output:
                OutputView()
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func placeholder(_ title: LocalizedStringKey, _ note: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(note).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }
}

// MARK: - 片段列：直接拖動排序；上下拖移進／移出暫存區

struct ClipRow: View {
    static let mainSize = CGSize(width: 96, height: 72)
    static let stagedSize = CGSize(width: 72, height: 54)
    static let spacing: CGFloat = 8

    @EnvironmentObject var store: AppStore
    let clips: [Clip]
    let staged: Bool

    @State private var draggingID: UUID?
    @State private var dragOffset: CGSize = .zero
    @State private var consumedX: CGFloat = 0   // 已經換過位置的水平距離
    @State private var trashFrame: CGRect = .zero
    @State private var overTrash = false

    private var size: CGSize { staged ? Self.stagedSize : Self.mainSize }
    private var step: CGFloat { size.width + Self.spacing }
    private var switchThreshold: CGFloat { size.height * 0.75 }

    var body: some View {
        HStack(spacing: 6) {
            thumbs
                .zIndex(1)   // 拖曳中的縮圖要蓋在垃圾桶上面
            TrashDropZone(height: size.height, active: draggingID != nil, targeted: overTrash)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { trashFrame = $0 }
        }
    }

    private var thumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.spacing) {
                ForEach(clips) { clip in
                    let isDragging = draggingID == clip.id
                    ClipThumb(clip: clip,
                              size: size,
                              isSelected: store.selectedClipID == clip.id,
                              dimmed: staged,
                              hint: isDragging ? dropHint : nil)
                        .scaleEffect(isDragging ? 1.06 : 1)
                        .shadow(color: .black.opacity(isDragging ? 0.4 : 0), radius: 8, y: 4)
                        .offset(isDragging ? dragOffset : .zero)
                        .zIndex(isDragging ? 1 : 0)
                        .onTapGesture {
                            store.selectedClipID = clip.id
                            store.previewMode = .clip
                        }
                        .gesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                .onChanged { v in dragChanged(clip, v) }
                                .onEnded { v in dragEnded(clip, v) }
                        )
                        .contextMenu { menu(for: clip) }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()   // 拖出這一列時縮圖不要被裁掉
        .frame(height: size.height + 12)
    }

    private var dropHint: String? {
        if overTrash { return String(localized: "放開：丟到垃圾桶") }
        if !staged, dragOffset.height > switchThreshold { return String(localized: "放開：移到暫存") }
        if staged, dragOffset.height < -switchThreshold { return String(localized: "放開：加回剪輯") }
        return nil
    }

    private func dragChanged(_ clip: Clip, _ v: DragGesture.Value) {
        if draggingID != clip.id {
            draggingID = clip.id
            consumedX = 0
        }
        dragOffset = CGSize(width: v.translation.width - consumedX, height: v.translation.height)
        overTrash = trashFrame.insetBy(dx: -6, dy: -6).contains(v.location)
        if overTrash { return }   // 停在垃圾桶上時不排序

        // 垂直拖遠了＝要換區，不做排序
        guard abs(v.translation.height) < switchThreshold,
              let current = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let shift = Int((dragOffset.width / step).rounded())
        let target = min(max(current + shift, 0), clips.count - 1)
        if target != current {
            withAnimation(.easeOut(duration: 0.15)) {
                store.moveClip(clip.id, toIndex: target)
            }
            consumedX += CGFloat(target - current) * step
            dragOffset.width = v.translation.width - consumedX
        }
    }

    private func dragEnded(_ clip: Clip, _ v: DragGesture.Value) {
        let dropOnTrash = trashFrame.insetBy(dx: -6, dy: -6).contains(v.location)
        withAnimation(.easeOut(duration: 0.18)) {
            if dropOnTrash {
                store.trash(clip)
            } else if !staged, v.translation.height > switchThreshold {
                store.setStaged(clip.id, true)
            } else if staged, v.translation.height < -switchThreshold {
                store.setStaged(clip.id, false)
            }
            draggingID = nil
            dragOffset = .zero
            consumedX = 0
            overTrash = false
        }
    }

    @ViewBuilder
    private func menu(for clip: Clip) -> some View {
        if staged {
            Button("加回剪輯") { store.setStaged(clip.id, false) }
        } else {
            Button("移到暫存區") { store.setStaged(clip.id, true) }
        }
        Button("往前移") { store.moveClip(clip, by: -1) }
        Button("往後移") { store.moveClip(clip, by: 1) }
        Divider()
        Button("在 Finder 中顯示") { store.reveal(clip) }
        Button("丟到垃圾桶", role: .destructive) { store.trash(clip) }
    }
}

/// 片段列右邊的垃圾桶：把縮圖拖上來放開＝丟到垃圾桶
struct TrashDropZone: View {
    let height: CGFloat
    var active = false     // 正在拖曳片段
    var targeted = false   // 縮圖正停在上面

    var body: some View {
        Image(systemName: targeted ? "trash.fill" : "trash")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(targeted ? Color.white : (active ? Color.red : Color.secondary))
            .frame(width: 36, height: height)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(targeted ? Color.red.opacity(0.85) : Color.secondary.opacity(active ? 0.15 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(active ? Color.red.opacity(0.6) : Color.secondary.opacity(0.25),
                                  style: StrokeStyle(lineWidth: 1, dash: active ? [] : [3, 3]))
            )
            .scaleEffect(targeted ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: targeted)
            .animation(.easeOut(duration: 0.12), value: active)
            .help("把片段拖到這裡丟到垃圾桶")
    }
}

struct ClipThumb: View {
    let clip: Clip
    var size = ClipRow.mainSize
    var isSelected = false
    var dimmed = false
    var hint: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let img = clip.thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)   // 固定框、裁切置中
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .opacity(dimmed ? 0.6 : 1)

            Text(formatTime(clip.trimmedDuration))
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(clip.isTrimmed ? Color.yellow : Color.white)
                .padding(4)

            if let hint {
                Text(hint)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - 版本標示（開源版／免費版／付費版）

struct EditionBadge: View {
    @State private var showInfo = false
    #if APPSTORE
    @EnvironmentObject private var license: LicenseStore
    @State private var showPaywall = false
    #endif

    /// ⚠️ 不要用 `let`（原本是）。買斷成功後 `Licensing.edition` 會從
    /// `.free` 變成 `.pro`，存成常數的話這顆標示會一直停在「免費版」。
    private var edition: Edition { Licensing.edition }

    var body: some View {
        Button {
            showInfo.toggle()
        } label: {
            Text(edition.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.18)))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help("目前使用的版本")
        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Soon-Cut \(edition.label)").font(.headline)
                Text(edition.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #if APPSTORE
                if edition == .free {
                    Button("移除浮水印…") {
                        showInfo = false
                        showPaywall = true
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                #endif
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("版本 \(version)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(width: 260)
        }
        #if APPSTORE
        .sheet(isPresented: $showPaywall) { PaywallSheet() }
        #endif
    }

    private var color: Color {
        switch edition {
        case .openSource: return .green
        case .free: return .orange
        case .pro: return .accentColor
        }
    }
}

// MARK: - 收合／展開的小箭頭

struct CollapseChevron: View {
    @Binding var collapsed: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { collapsed.toggle() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(collapsed ? -90 : 0))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(collapsed ? "展開" : "收合")
    }
}

/// 預覽畫面上方的標題列：可以把預覽收起來，讓下方清單有更多空間
struct PreviewHeader: View {
    @Binding var collapsed: Bool

    var body: some View {
        HStack(spacing: 6) {
            CollapseChevron(collapsed: $collapsed)
            Text("預覽")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - 介面語言

/// 介面語言切換：寫入這個 app 自己的 AppleLanguages，重新開啟後生效。
/// 「跟隨系統」＝移除設定，回到「系統設定 › 一般 › 語言與地區」的選擇。
struct LanguageMenu: View {
    private static let key = "AppleLanguages"

    private var current: String? {
        // 只看這個 app 自己 domain 的設定，不看全域
        (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[Self.key] as? [String])?.first
    }

    var body: some View {
        Menu {
            option("跟隨系統", code: nil)
            Divider()
            option("繁體中文", code: "zh-Hant")
            option("English", code: "en")
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("介面語言")
    }

    private func option(_ title: LocalizedStringKey, code: String?) -> some View {
        Button {
            choose(code)
        } label: {
            if current == code {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func choose(_ code: String?) {
        guard code != current else { return }
        if let code {
            UserDefaults.standard.set([code], forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
        UserDefaults.standard.synchronize()

        let alert = NSAlert()
        alert.messageText = String(localized: "重新開啟 Soon-Cut 後套用新語言")
        alert.informativeText = String(localized: "錄影中的工作請先存好。")
        alert.addButton(withTitle: String(localized: "立即重新開啟"))
        alert.addButton(withTitle: String(localized: "稍後"))
        if alert.runModal() == .alertFirstButtonReturn {
            Self.relaunch()
        }
    }

    /// 沙盒裡不能跑 shell，所以用 NSWorkspace 開一個新的 instance，
    /// 帶上 relaunch 參數讓它略過「只允許一個 SoonCut」的檢查，然後自己結束。
    static let relaunchArgument = "--soon-cut-relaunch"

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = [relaunchArgument]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) }
            }
        }
    }
}
