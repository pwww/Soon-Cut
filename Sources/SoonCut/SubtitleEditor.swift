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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlayerView(player: player)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 140, maxHeight: .infinity)

            formatBar
            qualityBar
            platformBar

            languageBar
            actionBar

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

            subtitleList
        }
        .task(id: "\(store.sequenceKey)#\(store.outputFormat.rawValue)") { await rebuild() }
        .onAppear { addObserver() }
        .onDisappear {
            removeObserver()
            player.pause()
        }
        .onChange(of: isRecording) {
            if isRecording { player.pause() }
        }
        .onChange(of: store.subtitles) { refreshOverlay() }
        .onChange(of: store.subtitlesOutdated) { refreshOverlay() }
        .translationTask(store.translationConfig) { session in
            await translate(with: session)
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
                    Text(platform.rawValue)
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
        HStack(spacing: 8) {
            if let status = store.subtitleStatus {
                TranscribeStatusView(status: status)
            } else {
                Button {
                    store.transcribeSequence()
                } label: {
                    Label(store.subtitles.isEmpty ? "產生字幕" : "重新轉寫", systemImage: "captions.bubble")
                }
                .disabled(store.isExporting)
                .help(store.subtitles.isEmpty ? "用本機 Whisper 轉寫字幕" : "重新轉寫會覆蓋目前的字幕修改")
            }
            Spacer()
            #if APPSTORE
            // 預覽畫面此刻就有浮水印，是唯一「想移除它」的動機已經存在的時刻。
            WatermarkNoticeButton()
            #endif
            Button {
                store.exportVideo()
            } label: {
                if store.isExporting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("輸出中 \(Int((store.exportProgress ?? 0) * 100))%")
                            .monospacedDigit()
                    }
                } else {
                    Label("輸出影片", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isExporting || store.isTranscribing)
        }
    }

    // MARK: 字幕清單

    private var subtitleList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(store.subtitles) { seg in
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
        .overlay {
            if store.subtitles.isEmpty && store.subtitleStatus == nil {
                Text(Transcriber.isModelDownloaded
                     ? "選好語音與字幕語言，按「產生字幕」；不加字幕也可以直接輸出"
                     : "選好語音與字幕語言，按「產生字幕」。第一次需要下載語音模型（約 1.6 GB，只需要一次）；不加字幕也可以直接輸出")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
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
            let newCanvas = store.outputFormat.canvas(base: result.renderSize)
            canvas = newCanvas
            duration = result.duration
            Renderer.prepareOverlay(overlay, subtitles: store.effectiveSubtitles, canvas: newCanvas,
                                    watermark: Licensing.showsWatermark)
            let item = AVPlayerItem(asset: result.composition)
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
        Renderer.prepareOverlay(overlay, subtitles: store.effectiveSubtitles, canvas: canvas,
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
                store.deleteSubtitle(id: segment.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("刪除這一句")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }
}

// MARK: - 輸出區（最新／已上傳／封存）

struct OutputView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $store.outputTab) {
                ForEach(OutputStatus.allCases) { status in
                    Text("\(status.rawValue) \(store.exports(in: status).count)").tag(status)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let items = store.exports(in: store.outputTab)
            // 預覽：選取的影片；沒選就預覽這一層最新的一支
            if let current = items.first(where: { $0.id == selectedID }) ?? items.first {
                ExportPreview(url: current.url)
                    .frame(minHeight: 140, maxHeight: .infinity)
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
                .frame(minHeight: 90, maxHeight: 240)   // 預覽拿剩下的空間
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

    private var emptyText: String {
        switch store.outputTab {
        case .latest: return "在「字幕」分頁按「輸出影片」，影片會出現在這裡"
        case .uploaded: return "上傳後把影片標記為「已上傳」"
        case .archived: return "不常用的影片可以封存在這裡"
        }
    }
}

struct ExportRow: View {
    @EnvironmentObject var store: AppStore
    let item: ExportItem
    var isSelected = false
    @State private var thumb: NSImage?

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
                Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.callout.weight(.semibold))
                HStack(spacing: 6) {
                    Text(formatTime(item.duration)).monospacedDigit()
                    if let format = item.format { Text(format) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if item.status == .latest {
                Button("已上傳") { store.setStatus(item, .uploaded) }
                    .controlSize(.small)
            }

            Menu {
                ForEach(OutputStatus.allCases.filter { $0 != item.status }) { status in
                    Button("移到「\(status.rawValue)」") { store.setStatus(item, status) }
                }
                Divider()
                Button("在 Finder 中顯示") { store.reveal(item) }
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
                    Text("已過 " + formatTime(context.date.timeIntervalSince(store.subtitleStatusStart ?? context.date)))
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
            text += eta < 60 ? "，剩不到 1 分鐘" : "，約剩 \(Int((eta / 60).rounded(.up))) 分鐘"
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
