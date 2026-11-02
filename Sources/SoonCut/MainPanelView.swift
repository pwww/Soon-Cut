import SwiftUI

struct MainPanelView: View {
    @EnvironmentObject var store: AppStore

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
        .overlay(alignment: .top) {
            // 拖動提示：視窗只能從最上方這條拖動
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
            }
            .disabled(store.isRecording)
            .help("在畫面上拖曳框選錄影範圍")

            Button {
                store.toggleRecording()
            } label: {
                Label(store.isRecording ? formatTime(store.elapsed) : "錄影",
                      systemImage: store.isRecording ? "stop.circle.fill" : "record.circle")
                    .monospacedDigit()
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy)
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Spacer()

            Toggle(isOn: $store.shortsMode) {
                Text("9:16")
            }
            .toggleStyle(.button)
            .disabled(store.isRecording)
            .help("Shorts 模式：框選鎖定 9:16")

            Toggle(isOn: $store.captureSystemAudio) {
                Image(systemName: store.captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .toggleStyle(.button)
            .disabled(store.isRecording)
            .help("錄系統聲音")

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
                Text("剪輯片段").font(.headline)
                Text("\(active.count) 段 · \(formatTime(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.openRawFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("打開片段資料夾")
            }

            if active.isEmpty {
                emptyRow(staged.isEmpty ? "錄完的片段會出現在這裡" : "把暫存區的片段往上拖回來",
                         height: ClipRow.mainSize.height)
            } else {
                ClipRow(clips: active, staged: false)
            }

            HStack {
                Text("暫存區").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(staged.count)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text("往下拖＝暫存，不放進這次輸出")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)

            if staged.isEmpty {
                emptyRow("沒有暫存的片段", height: ClipRow.stagedSize.height)
            } else {
                ClipRow(clips: staged, staged: true)
            }
        }
    }

    private func emptyRow(_ text: String, height: CGFloat) -> some View {
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
            Picker("", selection: $store.previewMode) {
                ForEach(PreviewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func placeholder(_ title: String, _ note: String) -> some View {
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

    @State private var draggingID: URL?
    @State private var dragOffset: CGSize = .zero
    @State private var consumedX: CGFloat = 0   // 已經換過位置的水平距離

    private var size: CGSize { staged ? Self.stagedSize : Self.mainSize }
    private var step: CGFloat { size.width + Self.spacing }
    private var switchThreshold: CGFloat { size.height * 0.75 }

    var body: some View {
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
                            DragGesture(minimumDistance: 4)
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
        if !staged, dragOffset.height > switchThreshold { return "放開：移到暫存" }
        if staged, dragOffset.height < -switchThreshold { return "放開：加回剪輯" }
        return nil
    }

    private func dragChanged(_ clip: Clip, _ v: DragGesture.Value) {
        if draggingID != clip.id {
            draggingID = clip.id
            consumedX = 0
        }
        dragOffset = CGSize(width: v.translation.width - consumedX, height: v.translation.height)

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
        withAnimation(.easeOut(duration: 0.18)) {
            if !staged, v.translation.height > switchThreshold {
                store.setStaged(clip.id, true)
            } else if staged, v.translation.height < -switchThreshold {
                store.setStaged(clip.id, false)
            }
            draggingID = nil
            dragOffset = .zero
            consumedX = 0
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
    private let edition = Licensing.edition

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
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("版本 \(version)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(width: 260)
        }
    }

    private var color: Color {
        switch edition {
        case .openSource: return .green
        case .free: return .orange
        case .pro: return .accentColor
        }
    }
}
