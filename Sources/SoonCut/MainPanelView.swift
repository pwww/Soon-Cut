import SwiftUI
import UniformTypeIdentifiers

struct MainPanelView: View {
    @EnvironmentObject var store: AppStore
    @State private var windowDrag: (mouse: NSPoint, origin: NSPoint)?
    @AppStorage("clipsCollapsed") private var clipsCollapsed = false
    @AppStorage("stagingCollapsed") private var stagingCollapsed = false
    @AppStorage("tabsCollapsed") private var tabsCollapsed = false
    @StateObject private var clipDrag = ClipDragModel()

    /// 左側片段欄的寬度：縮圖寬再多一點
    static let clipColumnWidth: CGFloat = ClipRow.mainSize.width + 22

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            regionInfo
            Divider()
            // 左：片段欄（窄）；右：剪輯／字幕／輸出（其餘空間）
            HStack(alignment: .top, spacing: 12) {
                clipsColumn
                Divider()
                previewSection
            }
            .frame(maxHeight: .infinity)
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
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    /// 寬度夠：圖示＋文字；不夠：只剩圖示（文字不會被裁成半個字）
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(compact: false)
            toolbarRow(compact: true)
        }
    }

    private func toolbarRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            Button {
                store.selectRegion()
            } label: {
                Label("範圍", systemImage: "viewfinder")
                    .labelStyle(ToolbarLabelStyle(compact: compact))
            }
            .fixedSize()
            .disabled(store.isRecording)
            .help("在畫面上拖曳框選錄影範圍")

            Button {
                store.toggleRecording()
            } label: {
                Label(store.isRecording ? formatTime(store.elapsed) : String(localized: "錄影"),
                      systemImage: store.isRecording ? "stop.circle.fill" : "record.circle")
                    .monospacedDigit()
                    .labelStyle(ToolbarLabelStyle(compact: compact && !store.isRecording))
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

    // MARK: 片段欄（使用中＋暫存區＋垃圾桶，直向）

    private var clipsColumn: some View {
        let active = store.activeClips
        let staged = store.stagedClips
        let total = active.reduce(0) { $0 + $1.trimmedDuration }

        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    CollapseChevron(collapsed: $clipsCollapsed)
                    Text("剪輯片段").font(.headline).lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text("\(active.count) 段 · \(formatTime(total))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
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
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        if !clipsCollapsed {
                            if active.isEmpty {
                                emptyRow(staged.isEmpty ? "錄完或匯入的片段會出現在這裡" : "把暫存區的片段拖回這裡",
                                         height: ClipRow.mainSize.height)
                            } else {
                                ClipRow(clips: active, staged: false)
                            }
                        } else {
                            Color.clear.frame(height: 8)
                        }
                    }
                    .padding(4)
                    .background(dropHighlight(clipDrag.target == .unstage))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ClipDragModel.space)) } action: {
                        clipDrag.activeFrame = $0
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            CollapseChevron(collapsed: $stagingCollapsed)
                            Text("暫存區").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text("\(staged.count)").font(.caption).foregroundStyle(.tertiary)
                        }
                        .help("拖到這裡＝暫存，不放進這次輸出")

                        if !stagingCollapsed {
                            if staged.isEmpty {
                                emptyRow("拖到這裡暫存", height: ClipRow.stagedSize.height)
                            } else {
                                ClipRow(clips: staged, staged: true)
                            }
                        }
                    }
                    .padding(4)
                    .background(dropHighlight(clipDrag.target == .stage))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ClipDragModel.space)) } action: {
                        clipDrag.stagedFrame = $0
                    }
                }
                .padding(.vertical, 2)
            }

            TrashDropZone(height: 40, active: clipDrag.draggingID != nil, targeted: clipDrag.target == .trash)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ClipDragModel.space)) } action: {
                    clipDrag.trashFrame = $0
                }
        }
        .frame(width: Self.clipColumnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: ClipDragModel.space)
        // 拖曳中的縮圖畫在整欄最上層，不會被捲動區裁掉
        .overlay(alignment: .topLeading) { dragGhost }
        .environmentObject(clipDrag)
        // 從 Finder 拖影片進來＝匯入
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter { ClipStorage.videoExtensions.contains($0.pathExtension.lowercased()) }
            guard !videos.isEmpty else { return false }
            store.importFiles(videos)
            return true
        }
    }

    private func dropHighlight(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(on ? 0.18 : 0))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(on ? 0.7 : 0), lineWidth: 1.5))
            .animation(.easeOut(duration: 0.12), value: on)
    }

    @ViewBuilder
    private var dragGhost: some View {
        if let id = clipDrag.draggingID, let clip = store.clips.first(where: { $0.id == id }) {
            ClipThumb(clip: clip,
                      size: clipDrag.draggingStaged ? ClipRow.stagedSize : ClipRow.mainSize,
                      isSelected: true,
                      hint: clipDrag.hint)
                .scaleEffect(1.06)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                .position(clipDrag.ghostCenter)
                .allowsHitTesting(false)
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
            GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
            switch store.previewMode {
            case .clip:
                if let clip = store.selectedClip {
                    ClipEditor(clip: clip, isRecording: store.isRecording)
                } else {
                    placeholder("剪輯", store.clips.isEmpty ? "錄好片段後會在這裡預覽與剪輯" : "點左邊的片段就會在這裡播放與剪輯")
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.previewAreaHeight, geo.size.height)
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

// MARK: - 片段拖曳：排序、移進／移出暫存區、丟垃圾桶

enum ClipDropTarget: Equatable {
    case trash, stage, unstage
}

/// 片段欄共用的拖曳狀態；各區塊的位置都量在同一個座標空間
final class ClipDragModel: ObservableObject {
    static let space = "clipColumn"

    @Published var draggingID: UUID?
    @Published var draggingStaged = false
    @Published var ghostCenter: CGPoint = .zero
    @Published var target: ClipDropTarget?

    var trashFrame: CGRect = .zero
    var activeFrame: CGRect = .zero
    var stagedFrame: CGRect = .zero

    var hint: String? {
        switch target {
        case .trash: return String(localized: "放開：丟到垃圾桶")
        case .stage: return String(localized: "放開：移到暫存")
        case .unstage: return String(localized: "放開：加回剪輯")
        case nil: return nil
        }
    }

    func dropTarget(at point: CGPoint, staged: Bool) -> ClipDropTarget? {
        if trashFrame.insetBy(dx: -4, dy: -4).contains(point) { return .trash }
        if !staged, stagedFrame.contains(point) { return .stage }
        if staged, activeFrame.contains(point) { return .unstage }
        return nil
    }
}

/// 直向片段清單：上下拖動排序；拖到另一區＝換區；拖到垃圾桶＝丟掉
struct ClipRow: View {
    static let mainSize = CGSize(width: 96, height: 72)
    static let stagedSize = CGSize(width: 80, height: 60)
    static let spacing: CGFloat = 8

    @EnvironmentObject var store: AppStore
    @EnvironmentObject var drag: ClipDragModel
    let clips: [Clip]
    let staged: Bool

    @State private var consumedY: CGFloat = 0   // 已經換過位置的垂直距離

    private var size: CGSize { staged ? Self.stagedSize : Self.mainSize }
    private var step: CGFloat { size.height + Self.spacing }

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(clips) { clip in
                ClipThumb(clip: clip,
                          size: size,
                          isSelected: store.selectedClipID == clip.id,
                          dimmed: staged)
                    .opacity(drag.draggingID == clip.id ? 0.25 : 1)
                    .onTapGesture {
                        store.selectedClipID = clip.id
                        store.previewMode = .clip
                    }
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named(ClipDragModel.space))
                            .onChanged { v in dragChanged(clip, v) }
                            .onEnded { v in dragEnded(clip, v) }
                    )
                    .contextMenu { menu(for: clip) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func dragChanged(_ clip: Clip, _ v: DragGesture.Value) {
        if drag.draggingID != clip.id {
            drag.draggingID = clip.id
            drag.draggingStaged = staged
            consumedY = 0
        }
        drag.ghostCenter = v.location
        drag.target = drag.dropTarget(at: v.location, staged: staged)
        guard drag.target == nil,
              let current = clips.firstIndex(where: { $0.id == clip.id }) else { return }

        // 在同一區裡上下拖＝排序
        let dy = v.translation.height - consumedY
        let shift = Int((dy / step).rounded())
        let target = min(max(current + shift, 0), clips.count - 1)
        if target != current {
            withAnimation(.easeOut(duration: 0.15)) {
                store.moveClip(clip.id, toIndex: target)
            }
            consumedY += CGFloat(target - current) * step
        }
    }

    private func dragEnded(_ clip: Clip, _ v: DragGesture.Value) {
        let target = drag.dropTarget(at: v.location, staged: staged)
        withAnimation(.easeOut(duration: 0.18)) {
            switch target {
            case .trash: store.trash(clip)
            case .stage: store.setStaged(clip.id, true)
            case .unstage: store.setStaged(clip.id, false)
            case nil: break
            }
            drag.draggingID = nil
            drag.target = nil
            consumedY = 0
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

/// 片段欄底部的垃圾桶：把縮圖拖上來放開＝丟到垃圾桶
struct TrashDropZone: View {
    let height: CGFloat
    var active = false     // 正在拖曳片段
    var targeted = false   // 縮圖正停在上面

    var body: some View {
        Image(systemName: targeted ? "trash.fill" : "trash")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(targeted ? Color.white : (active ? Color.red : Color.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(targeted ? Color.red.opacity(0.85) : Color.secondary.opacity(active ? 0.15 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(active ? Color.red.opacity(0.6) : Color.secondary.opacity(0.25),
                                  style: StrokeStyle(lineWidth: 1, dash: active ? [] : [3, 3]))
            )
            .scaleEffect(targeted ? 1.05 : 1)
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

/// 工具列按鈕：寬版顯示圖示＋文字，窄版只顯示圖示
struct ToolbarLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 5) {
                configuration.icon
                configuration.title
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}

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
