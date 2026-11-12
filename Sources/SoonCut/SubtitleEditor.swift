import SwiftUI
import AVKit
import Translation

// MARK: - 字幕：拼接預覽（依輸出比例）＋字幕＋逐句編輯＋輸出

struct SubtitleEditor: View {
    @EnvironmentObject var store: AppStore
    let isRecording: Bool

    @State private var player = AVPlayer()
    @State private var overlay = OverlayState()
    @State private var canvas: CGSize = .zero
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?
    @AppStorage("subtitlePlayerFraction") private var playerFraction: Double = 0.42
    @Environment(\.previewAreaHeight) private var areaHeight
    @State private var confirmRegenerate = false
    @AppStorage("previewCollapsed") private var previewCollapsed = false

    @State private var width: CGFloat = 0
    /// 視窗拉到螢幕一半寬時，字幕稿移到右側欄（像 RWD 網頁）
    private var isWide: Bool {
        let screenWidth = FloatingPanel.current?.screen?.visibleFrame.width
            ?? NSScreen.main?.visibleFrame.width ?? 1440
        let windowWidth = FloatingPanel.current?.frame.width ?? (width + 36)
        return windowWidth >= screenWidth / 2
    }

    var body: some View {
        Group {
            if isWide {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        controls
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        transcriptHeader
                        subtitleList
                    }
                    .frame(width: min(440, max(300, width * 0.36)))
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    controls
                    transcriptHeader
                    subtitleList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: "\(store.sequenceKey)#\(store.outputFormat.rawValue)") { await rebuild() }
        .onAppear { addObserver() }
        .onDisappear {
            removeObserver()
            player.pause()
        }
        .onChange(of: isRecording) {
            if isRecording { player.pause() }
        }
        .onChange(of: previewCollapsed) {
            if previewCollapsed { player.pause() }
        }
        .onChange(of: store.subtitles) { refreshOverlay() }
        .onChange(of: store.subtitlesOutdated) { refreshOverlay() }
        .onChange(of: store.subtitleStyle) { refreshOverlay() }
        .translationTask(store.translationConfig) { session in
            await translate(with: session)
        }
    }

    @ViewBuilder
    private var controls: some View {
            PreviewHeader(collapsed: $previewCollapsed)
            if !previewCollapsed {
                PlayerView(player: player)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(height: PreviewSizing.height(fraction: playerFraction, area: areaHeight))

                ResizeHandle(height: PreviewSizing.binding(fraction: $playerFraction, area: areaHeight),
                             defaultHeight: areaHeight * 0.42)
            }

            actionBar

            formatBar
            qualityBar
            platformBar

            languageBar
            styleBar

            if store.subtitlesOutdated && !store.isTranscribing {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("片段在轉寫後有變動，舊字幕先不套用到預覽和輸出。")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("重新轉寫") { store.transcribeSequence() }
                    Button("仍要套用") { store.keepOutdatedSubtitles() }
                        .help("只剪了一點點、字幕時間差不多時可以沿用")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .controlSize(.small)
            }

    }

    // MARK: 語言

    private var languageBar: some View {
        HStack(spacing: 10) {
            Picker("語音", selection: $store.speechLanguage) {
                ForEach(SpeechLanguage.allCases) { lang in
                    Text(lang.label).tag(lang)
                }
            }
            .help("影片裡說話的語言；不確定就選「自動偵測」。改了要重新轉寫")
            .disabled(store.isTranscribing)

            Picker("字幕", selection: $store.subtitleLanguage) {
                ForEach(SubtitleLanguage.allCases) { lang in
                    Text(lang.label).tag(lang)
                }
            }
            .help("跟語音不同時，用 macOS 內建翻譯在本機翻譯。切換會重新產生字幕，手動修改會被覆蓋")
            .disabled(store.isTranscribing)
        }
        .font(.caption)
        .controlSize(.small)
    }

    // MARK: 字幕外觀

    private var styleBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Picker("字色", selection: $store.subtitleStyle.textColor) {
                    ForEach(SubtitleStyle.TextColor.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                .fixedSize()

                Picker("外框", selection: $store.subtitleStyle.outline) {
                    ForEach(SubtitleStyle.Outline.allCases) { o in
                        Text(o.label).tag(o)
                    }
                }
                .fixedSize()

                Picker("大小", selection: $store.subtitleStyle.size) {
                    ForEach(SubtitleStyle.Size.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .fixedSize()
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text("位置").foregroundStyle(.secondary)
                Image(systemName: "arrow.down.to.line").foregroundStyle(.tertiary)
                Slider(value: $store.subtitleStyle.position, in: SubtitleStyle.positionRange)
                    .help("字幕上下位置，一律水平置中")
                Image(systemName: "arrow.up.to.line").foregroundStyle(.tertiary)
                Button("重設") {
                    store.subtitleStyle.position = SubtitleStyle.defaultPosition
                }
                .buttonStyle(.borderless)
                .disabled(abs(store.subtitleStyle.position - SubtitleStyle.defaultPosition) < 0.001)
            }
        }
        .font(.caption)
        .controlSize(.small)
    }

    /// 用 Apple 內建翻譯把原文翻成字幕語言
    private func translate(with session: TranslationSession) async {
        let items = await MainActor.run { store.sourceSubtitles }
        guard !items.isEmpty else { return }
        do {
            let requests = items.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
            }
            let responses = try await session.translations(from: requests)
            var map: [String: String] = [:]
            for r in responses {
                if let id = r.clientIdentifier { map[id] = r.targetText }
            }
            await MainActor.run { store.applyTranslations(map) }
        } catch {
            await MainActor.run { store.translationFailed(error) }
        }
    }

    // MARK: 輸出比例

    private var formatBar: some View {
        HStack(spacing: 8) {
            Text("比例").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $store.outputFormat) {
                ForEach(OutputFormat.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// 輸出畫質與預估檔案大小
    private var qualityBar: some View {
        HStack(spacing: 8) {
            Text("畫質").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $store.exportQuality) {
                ForEach(ExportQuality.allCases) { q in
                    Text(q.label).tag(q)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)
            Text("\(store.exportQuality.note) · 約 \(ByteCountFormatter.string(fromByteCount: store.exportQuality.estimatedBytes(duration: duration), countStyle: .file))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// 這個比例適合的平台，以及長度是否超過上限
    private var platformBar: some View {
        HStack(spacing: 6) {
            ForEach(store.outputFormat.platforms) { platform in
                let over = platform.maxDuration.map { duration > $0 } ?? false
                HStack(spacing: 3) {
                    Image(systemName: over ? "exclamationmark.triangle.fill" : "checkmark")
                    Text(platform.label)
                    if over, let max = platform.maxDuration {
                        Text("超過 \(formatTime(max))")
                    }
                }
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(over ? Color.orange.opacity(0.2) : Color.green.opacity(0.15)))
                .foregroundStyle(over ? Color.orange : Color.green)
            }
            Spacer(minLength: 0)
            let outSize = store.exportQuality.scaled(canvas)
            Text("\(formatTime(duration)) · 輸出 \(Int(outSize.width))×\(Int(outSize.height))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 按鈕列

    private var actionBar: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 10) {
                if store.transcribeRunningHere, let status = store.subtitleStatus {
                    TranscribeStatusView(status: status)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let queue = store.queueInfo(.transcribe) {
                    QueueNotice(kind: .transcribe, position: queue.position, runningProject: queue.runningProject)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if store.translatingProjectID == store.currentProjectID {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("翻譯成\(store.subtitleLanguage.label)中…（macOS 本機翻譯）")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button {
                        if store.subtitles.isEmpty {
                            store.transcribeSequence()
                        } else {
                            confirmRegenerate = true
                        }
                    } label: {
                        Label(store.subtitles.isEmpty ? "產生字幕" : "重新產生字幕", systemImage: "captions.bubble")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isExporting)
                    .help(store.otherProjectBusy(.transcribe).map { String(localized: "「\($0)」正在產生字幕，按下後會排在它後面") }
                          ?? (store.subtitles.isEmpty ? String(localized: "用本機 Whisper 轉寫字幕")
                                                      : String(localized: "重新產生會覆蓋目前的字幕與手動修改")))
                }

                Button {
                    store.exportVideo()
                } label: {
                    Group {
                        if store.exportRunningHere {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("輸出中 \(Int((store.exportProgress ?? 0) * 100))%")
                                    .monospacedDigit()
                            }
                        } else if let queue = store.queueInfo(.export) {
                            Label(String(localized: "排隊輸出中（第 \(queue.position) 個）"), systemImage: "hourglass")
                        } else {
                            Label("合成字幕輸出", systemImage: "square.and.arrow.up")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isExporting || store.isTranscribing)
                .help(store.otherProjectBusy(.export).map { String(localized: "「\($0)」正在輸出，按下後會排在它後面") } ?? "")

                // 其他輸出方式
                Menu {
                    Button {
                        store.exportVideo(burnCaptions: false)
                    } label: {
                        Label("只輸出影片（不加字幕）", systemImage: "film")
                    }
                    .disabled(store.isExporting || store.isTranscribing)

                    Button {
                        store.exportSubtitlesOnly()
                    } label: {
                        Label("只輸出字幕（SRT）", systemImage: "captions.bubble")
                    }
                    .disabled(store.effectiveSubtitles.isEmpty)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(store.isExporting || store.isTranscribing)
                .help("其他輸出方式：只輸出影片（不加字幕），或只輸出字幕檔（SRT）")
            }
            .controlSize(.large)

            if let queue = store.queueInfo(.export) {
                QueueNotice(kind: .export, position: queue.position, runningProject: queue.runningProject)
            }
            #if APPSTORE
            // 預覽畫面此刻就有浮水印，是唯一「想移除它」的動機已經存在的時刻。
            WatermarkNoticeButton()
            #endif
        }
        .confirmationDialog("重新產生字幕？", isPresented: $confirmRegenerate) {
            Button("重新產生", role: .destructive) { store.transcribeSequence() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("目前的字幕和你手動修改的內容都會被覆蓋。")
        }
    }

    // MARK: 字幕清單

    private var transcriptHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("字幕稿").font(.headline)
                Spacer()
                Button {
                    store.reloadCaptionFile()
                } label: {
                    Label("重新整理", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(String(localized: "重新讀取字幕校正資料夾裡的「\(store.captionFileName)」，套用外部的修改"))
                Button {
                    store.openCaptionFolder()
                } label: {
                    Label("校正資料夾", systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(String(localized: "「\(store.captionFileName)」會一直跟著這個專案的字幕更新。讓本機 LLM 連這個資料夾校正術語、人名、錯別字，存檔後 Soon-Cut 會自動套回來"))
            }
            ProjectNoteField()
            if let note = store.captionNote {
                Label(note, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if !store.undoStack.isEmpty || !store.redoStack.isEmpty {
                HStack(spacing: 6) {
                    Button {
                        store.undoEdit()
                    } label: {
                        Label("復原", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!store.canUndoEdit)
                    .keyboardShortcut("z", modifiers: [.command, .option])
                    .help(store.undoStack.last.map { String(localized: "復原：\($0.label)（⌥⌘Z）") } ?? "")

                    Button {
                        store.redoEdit()
                    } label: {
                        Label("重做", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!store.canRedoEdit)
                    .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                    .help(store.redoStack.last.map { String(localized: "重做：\($0.label)（⌥⇧⌘Z）") } ?? "")

                    if let last = store.undoStack.last {
                        Text(last.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .controlSize(.small)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            }
        }
    }

    /// 這一句之前超過 3 秒沒有字幕：可能是漏抓，給一個「重新辨識」的入口
    private func gapBefore(_ seg: SubtitleSegment) -> ClipRange? {
        guard store.canFillGaps, !store.isTranscribing,
              let i = store.subtitles.firstIndex(where: { $0.id == seg.id }) else { return nil }
        let prevEnd = i == 0 ? 0 : store.subtitles[..<i].map(\.end).max() ?? 0
        guard seg.start - prevEnd > Transcriber.holeThreshold else { return nil }
        return ClipRange(start: prevEnd, end: seg.start)
    }

    private var subtitleList: some View {
        // 校正說明和貼文放在捲動區裡，展開很長時也能捲到下面的字幕
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ProofreadGuide()
                ProjectPostCard()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
            if store.subtitles.isEmpty && !store.isTranscribing {
                Text(Transcriber.isModelDownloaded
                     ? "選好語音與字幕語言，按「產生字幕」；不加字幕也可以直接輸出"
                     : "選好語音與字幕語言，按「產生字幕」。第一次需要下載語音模型（約 1.6 GB，只需要一次）；不加字幕也可以直接輸出")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(store.subtitles) { seg in
                    if let gap = gapBefore(seg) {
                        GapRow(start: gap.start, end: gap.end)
                    }
                    SubtitleRow(
                        segment: seg,
                        isCurrent: currentTime >= seg.start && currentTime < seg.end,
                        onSeek: {
                            player.pause()
                            player.seek(to: cmTime(seg.start + 0.01), toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    )
                }
            }
            .opacity(store.subtitlesOutdated ? 0.45 : 1)
        }
        .frame(minHeight: 70, maxHeight: .infinity)
    }

    // MARK: 播放器

    private func rebuild() async {
        let clips = store.activeClips
        guard !clips.isEmpty else {
            player.replaceCurrentItem(with: nil)
            return
        }
        do {
            let result = try await Composer.build(clips: clips)
            // 片段在合成途中又改了：這個結果已經過時，交給新的那次重建，免得舊畫面蓋掉新的
            if Task.isCancelled { return }
            let newCanvas = store.outputFormat.canvas(base: result.renderSize)
            canvas = newCanvas
            duration = result.duration
            Renderer.prepareOverlay(overlay, subtitles: store.effectiveSubtitles, style: store.subtitleStyle, canvas: newCanvas,
                                    watermark: Licensing.showsWatermark)
            let item = AVPlayerItem(asset: result.composition)
            item.audioTimePitchAlgorithm = .spectral   // 變速片段保持音高
            item.videoComposition = Renderer.videoComposition(for: result.composition, canvas: newCanvas, overlay: overlay)
            let resumeAt = player.currentTime()
            player.replaceCurrentItem(with: item)
            if CMTimeGetSeconds(resumeAt) < result.duration {
                _ = await player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } catch {
            player.replaceCurrentItem(with: nil)
            store.errorMessage = error.localizedDescription
        }
    }

    /// 字幕改了：更新疊圖；暫停中的畫面重畫一次
    private func refreshOverlay() {
        guard canvas.width > 0 else { return }
        Renderer.prepareOverlay(overlay, subtitles: store.effectiveSubtitles, style: store.subtitleStyle, canvas: canvas,
                                watermark: Licensing.showsWatermark)
        if player.rate == 0 {
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func addObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { t in
            currentTime = CMTimeGetSeconds(t)
        }
    }

    private func removeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }
}

struct SubtitleRow: View {
    @EnvironmentObject var store: AppStore
    let segment: SubtitleSegment
    let isCurrent: Bool
    let onSeek: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onSeek) {
                Text(formatTime(segment.start))
                    .font(.caption.monospacedDigit())
            }
            .buttonStyle(.borderless)
            .help("跳到這一句")

            TextField("", text: Binding(
                get: { segment.text },
                set: { store.updateSubtitle(id: segment.id, text: $0) }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.callout)

            Button {
                store.cutSentence(id: segment.id)
            } label: {
                Image(systemName: "scissors")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!store.canCutBySubtitle)
            .help(store.subtitlesOutdated ? "字幕跟目前的片段對不上，先重新產生字幕才能用字幕剪影片"
                                          : "從影片剪掉這一句（畫面和聲音都會剪掉，可以復原）")

            Button {
                store.deleteSubtitle(id: segment.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("只刪掉這句字幕，影片不變")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        // 點這一句的任何地方（包含點進文字開始編輯）預覽就跳到這一句
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onSeek() })
        .help("點一下跳到這一句；點文字可以直接修改")
    }
}

// MARK: - 輸出區（最新／已上傳／封存）

struct OutputView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedID: String?
    @AppStorage("outputPreviewFraction") private var previewFraction: Double = 0.45
    @Environment(\.previewAreaHeight) private var areaHeight
    @AppStorage("previewCollapsed") private var previewCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $store.outputTab) {
                ForEach(OutputStatus.allCases) { status in
                    Text("\(status.label) \(store.exports(in: status).count)").tag(status)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let items = store.exports(in: store.outputTab)
            // 預覽：選取的影片；沒選就預覽這一層最新的一支
            if let current = items.first(where: { $0.id == selectedID }) ?? items.first {
                PreviewHeader(collapsed: $previewCollapsed)
                if !previewCollapsed {
                    ExportPreview(url: current.url)
                        .frame(height: PreviewSizing.height(fraction: previewFraction, area: areaHeight))
                    ResizeHandle(height: PreviewSizing.binding(fraction: $previewFraction, area: areaHeight),
                                 defaultHeight: areaHeight * 0.45)
                }
            }
            if items.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            let isSelected = item.id == (items.first(where: { $0.id == selectedID }) ?? items.first)?.id
                            ExportRow(item: item, isSelected: isSelected)
                                .onTapGesture { selectedID = item.id }
                        }
                    }
                }
                .frame(minHeight: 90, maxHeight: .infinity)   // 清單拿剩下的空間
            }

            HStack {
                Label("把卡片直接拖進 Threads 等網頁的上傳框", systemImage: "hand.draw")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.open(OutputLibrary.exportsDir)
                } label: {
                    Label("輸出資料夾", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private var emptyText: LocalizedStringKey {
        switch store.outputTab {
        case .latest: return "在「字幕」分頁按「合成字幕輸出」，影片會出現在這裡"
        case .uploaded: return "上傳後把影片標記為「已上傳」"
        case .archived: return "不常用的影片可以封存在這裡"
        }
    }
}

struct ExportRow: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    let item: ExportItem
    var isSelected = false
    @State private var thumb: NSImage?
    @State private var postCopied = false

    private func askRename() {
        TextPrompt.ask(title: String(localized: "重新命名影片"),
                       message: String(localized: "同名的字幕稿（SRT）也會一起改名"),
                       defaultText: item.hasDefaultName ? (store.currentProject?.name ?? item.name) : item.name) { name in
            store.rename(item, to: name)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 56, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if item.hasDefaultName {
                        Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                    } else {
                        Text(item.name)
                    }
                }
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help("點兩下重新命名")
                .onTapGesture(count: 2) { askRename() }
                HStack(spacing: 6) {
                    if !item.hasDefaultName {
                        Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                    }
                    Text(formatTime(item.duration)).monospacedDigit()
                    if let format = item.format {
                        // 舊紀錄存的是輸出當下的語言，顯示時換成目前語言
                        Text(format.replacingOccurrences(of: "原始", with: OutputFormat.original.label)
                                   .replacingOccurrences(of: "Original", with: OutputFormat.original.label))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("🤏可直接拖曳來上傳到網頁")
                    .font(.caption2.weight(.medium))
                    // 深色模式用淺藍、淺色模式用深藍，兩邊都有足夠對比
                    .foregroundStyle(colorScheme == .dark
                                     ? Color(red: 0.58, green: 0.80, blue: 1.0)
                                     : Color(red: 0.0, green: 0.36, blue: 0.78))
                    .padding(.top, 1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let post = store.currentPost {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(post, forType: .string)
                        postCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            postCopied = false
                        }
                    } label: {
                        Label(postCopied ? "已複製" : "複製貼文", systemImage: postCopied ? "checkmark" : "text.bubble")
                    }
                    .controlSize(.small)
                    .help("複製這個專案的社群貼文，搭配影片一起上傳")
                }
                if item.status == .latest {
                    Button("標記已上傳") { store.setStatus(item, .uploaded) }
                        .controlSize(.small)
                }
            }

            Menu {
                ForEach(OutputStatus.allCases.filter { $0 != item.status }) { status in
                    Button("移到「\(status.label)」") { store.setStatus(item, status) }
                }
                Divider()
                Button("重新命名…") { askRename() }
                Button("在 Finder 中顯示") { store.reveal(item) }
                if FileManager.default.fileExists(atPath: SRTWriter.url(for: item.url).path) {
                    Button("拷貝字幕稿（SRT）") {
                        if let text = try? String(contentsOf: SRTWriter.url(for: item.url), encoding: .utf8) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                }
                Button("丟到垃圾桶", role: .destructive) { store.trash(item) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onDrag {
            // 以檔案 URL（public.file-url）拖出：瀏覽器上傳框與 Finder 都直接收到影片檔。
            // 不用檔案承諾（file promise），因為 Chrome 等瀏覽器不接受。
            NSItemProvider(object: item.url as NSURL)
        }
        .task(id: item.id) {
            thumb = await ClipStorage.frame(of: AVURLAsset(url: item.url), at: 0.5, maxSize: 160)
        }
    }
}

// MARK: - 轉寫進度（步驟、說明、經過時間、下載量）

struct TranscribeStatusView: View {
    @EnvironmentObject var store: AppStore
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if let step = store.subtitleStep {
                    Text(step)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(status)
                    .font(.caption.weight(.semibold))
                // 每秒更新經過時間，讓人知道沒有卡住
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // ⚠️ 用插值不要用字串相加：相加的話「已過 」是裸 String，抽不進字串目錄
                    Text("已過 \(formatTime(context.date.timeIntervalSince(store.subtitleStatusStart ?? context.date)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let bytes = store.downloadedBytes, bytes > 1_000_000 {
                let total = Transcriber.modelDownloadBytes
                HStack(spacing: 6) {
                    ProgressView(value: min(1, Double(bytes) / Double(total)))
                        .frame(maxWidth: 160)
                    Text(downloadText(bytes: bytes, total: total))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let detail = store.subtitleDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func downloadText(bytes: Int64, total: Int64) -> String {
        let done = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let all = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        var text = "\(done) / \(all)"
        if let eta = store.downloadETA {
            text += eta < 60 ? String(localized: "，剩不到 1 分鐘")
                             : String(localized: "，約剩 \(Int((eta / 60).rounded(.up))) 分鐘")
        }
        return text
    }
}

// MARK: - 輸出影片預覽

struct ExportPreview: View {
    let url: URL
    @State private var player = AVPlayer()

    var body: some View {
        PlayerView(player: player)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear { load() }
            .onChange(of: url) { load() }
            .onDisappear { player.pause() }
    }

    private func load() {
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }
}

// MARK: - 用 LLM 校正字幕：說明＋可直接複製的 prompts（可收合）

struct ProofreadGuide: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("proofreadGuideExpanded") private var expanded = false
    @State private var copiedTitle: String?
    @State private var emptyNote = false

    private struct Prompt {
        var title: String
        var preview: String
        var make: () -> String?
    }

    /// 這個專案的指令（後面自動帶上備註）
    private var projectPrompts: [Prompt] {
        let file = store.captionFileName
        let list: [(String, String)] = [
            (String(localized: "快速校正"),
             String(localized: "照 README 校正「\(file)」，存回原檔")),
            (String(localized: "完整校正（附修改清單）"),
             String(localized: "讀這個資料夾的 README.md 和 glossary.md，校正「\(file)」的錯別字、同音字、人名、機構與專有名詞（不確定的請上網查證）。不要改編號、時間軸和句數。改完直接存回「\(file)」，最後列出你改了哪些句子，以及沒把握所以沒改的地方。")),
            (String(localized: "整理術語表"),
             String(localized: "讀「\(file)」，把影片裡出現的人名、機構、地名和專有名詞整理成正確寫法的清單，加到 glossary.md 最後面（保留原本的內容）。")),
            (String(localized: "寫社群貼文"),
             String(localized: "讀「\(file)」，幫我寫一則 Threads 貼文：開頭一句抓注意力、三個重點、結尾一個提問，500 字以內，語氣口語。存成「\(store.postFileURL.lastPathComponent)」，只放貼文內文。")),
        ]
        return list.map { title, text in
            Prompt(title: title, preview: store.withNote(text), make: { store.withNote(text) })
        }
    }

    /// 所有專案一起：互相參考前後文
    private var allPrompts: [Prompt] {
        [
            Prompt(title: String(localized: "校正所有專案"),
                   preview: String(localized: "一次校正所有專案的字幕檔，互相參考前後文、人名與術語，並帶上各專案的備註"),
                   make: { store.proofreadAllPrompt() }),
            Prompt(title: String(localized: "所有專案寫貼文"),
                   preview: String(localized: "幫每個專案各寫一則貼文，跨專案補足背景，並帶上各專案的備註；寫好會顯示在各專案的字幕頁"),
                   make: { store.postsAllPrompt() }),
        ]
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. 按右上「校正資料夾」\n2. 讓 Claude 或本機 LLM 連到這個資料夾\n3. 複製下面的指令貼給它\n4. 它存檔後，字幕稿會自動更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("這個專案").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(projectPrompts, id: \.title) { row($0) }

                Text("所有專案").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(allPrompts, id: \.title) { row($0) }
                if emptyNote {
                    Text("還沒有任何專案有字幕，先產生字幕再試")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("用 LLM 校正字幕、寫貼文", systemImage: "sparkles")
                .font(.caption.weight(.medium))
        }
    }

    private func row(_ prompt: Prompt) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.title).font(.caption.weight(.semibold))
                Text(prompt.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button {
                guard let text = prompt.make() else {
                    emptyNote = true
                    return
                }
                emptyNote = false
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copiedTitle = prompt.title
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copiedTitle == prompt.title { copiedTitle = nil }
                }
            } label: {
                Label(copiedTitle == prompt.title ? "已複製" : "複製",
                      systemImage: copiedTitle == prompt.title ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
    }
}

// MARK: - 專案備註：給 LLM 的背景（場合、日期、人物）

struct ProjectNoteField: View {
    @EnvironmentObject var store: AppStore
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "note.text").foregroundStyle(.secondary).font(.caption)
            TextField("備註（例如：11/11 某某立院質詢國防部長），複製指令時會一起帶上", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.caption)
                .lineLimit(1...4)
                .onSubmit { store.setCurrentNote(text) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .onAppear { text = store.currentNote }
        .onChange(of: store.currentProjectID) { text = store.currentNote }
        .onChange(of: text) { store.setCurrentNote(text) }
    }
}

// MARK: - LLM 寫好的社群貼文

struct ProjectPostCard: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("postCardExpanded") private var expanded = true
    @State private var copied = false

    var body: some View {
        if let post = store.currentPost {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(post)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(post, forType: .string)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copied = false
                            }
                        } label: {
                            Label(copied ? "已複製" : "複製貼文", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Button {
                            store.revealPost()
                        } label: {
                            Label("在 Finder 顯示", systemImage: "folder")
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                .padding(.top, 4)
            } label: {
                Label("社群貼文", systemImage: "text.bubble")
                    .font(.caption.weight(.medium))
            }
        }
    }
}

// MARK: - 字幕稿裡的空白段

struct GapRow: View {
    @EnvironmentObject var store: AppStore
    let start: Double
    let end: Double

    private var isFilling: Bool {
        guard let g = store.fillingGap else { return false }
        return abs(g.start - start) < 0.01 && abs(g.end - end) < 0.01
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.badge.xmark").foregroundStyle(.orange)
            Text("\(formatTime(start))–\(formatTime(end)) 沒有字幕")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if isFilling {
                ProgressView().controlSize(.small)
                Text("辨識中…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button {
                    store.fillGap(start: start, end: end)
                } label: {
                    Label("重新辨識", systemImage: "waveform.badge.magnifyingglass")
                }
                .controlSize(.small)
                .disabled(store.fillingGap != nil || store.isExporting)
                .help("漏抓字幕時按這裡，只重新辨識這一段，其他字幕不動")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

// MARK: - 排隊提示

struct QueueNotice: View {
    @EnvironmentObject var store: AppStore
    let kind: JobKind
    let position: Int
    let runningProject: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass")
            VStack(alignment: .leading, spacing: 1) {
                Text(kind == .transcribe ? "排隊產生字幕中" : "排隊輸出中")
                    .font(.caption.weight(.semibold))
                Text(kind == .transcribe
                     ? String(localized: "「\(runningProject)」正在產生字幕，這個專案排第 \(position) 個，輪到時會自動開始")
                     : String(localized: "「\(runningProject)」正在輸出，這個專案排第 \(position) 個，輪到時會自動開始"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("取消排隊") { store.cancelQueued(kind) }
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}
