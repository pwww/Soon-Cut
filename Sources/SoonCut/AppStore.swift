import SwiftUI
import AppKit
import AVFoundation
import Translation

/// App 最上層的兩個分頁
enum AppTab: String, CaseIterable, Identifiable {
    case record, edit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .record: return String(localized: "錄製")
        case .edit: return String(localized: "編輯")
        }
    }
}

enum PreviewMode: String, CaseIterable, Identifiable {
    case clip = "剪輯"
    case subtitle = "字幕"
    case output = "輸出"
    var id: String { rawValue }

    /// 顯示用。⚠️ 不要直接顯示 `rawValue`。
    var label: String {
        switch self {
        case .clip: return String(localized: "剪輯")
        case .subtitle: return String(localized: "字幕")
        case .output: return String(localized: "輸出")
        }
    }
}

/// 字幕跟著「哪一版時間軸」轉寫的，存在 Raw/subtitles.json
private struct SubtitleFile: Codable {
    var sequenceKey: String
    var segments: [SubtitleSegment]
    var sourceSegments: [SubtitleSegment]?   // 原文（語音語言）
    var spokenLanguage: String?              // Whisper 語言代碼
}

@MainActor
final class AppStore: ObservableObject {
    // MARK: 錄影設定
    @Published var region: CaptureRegion? {
        didSet {
            saveRegion()
            refreshFrame()
        }
    }
    @Published var shortsMode: Bool = UserDefaults.standard.bool(forKey: "shortsMode") {
        didSet {
            UserDefaults.standard.set(shortsMode, forKey: "shortsMode")
            if shortsMode, let r = region { region = r.convertedToShorts() }
            if shortsMode { outputFormat = .vertical }
        }
    }
    @Published var captureSystemAudio: Bool = (UserDefaults.standard.object(forKey: "captureSystemAudio") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(captureSystemAudio, forKey: "captureSystemAudio") }
    }
    /// 浮動視窗固定在最上層（關掉就跟一般視窗一樣）
    @Published var pinned: Bool = (UserDefaults.standard.object(forKey: "panelPinned") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(pinned, forKey: "panelPinned") }
    }
    /// 同時錄麥克風（跟系統聲音各自獨立）
    @Published var captureMicrophone: Bool = UserDefaults.standard.bool(forKey: "captureMicrophone") {
        didSet { UserDefaults.standard.set(captureMicrophone, forKey: "captureMicrophone") }
    }
    /// 選用的麥克風；nil = 系統預設
    @Published var microphoneID: String? = UserDefaults.standard.string(forKey: "microphoneID") {
        didSet { UserDefaults.standard.set(microphoneID, forKey: "microphoneID") }
    }
    @Published private(set) var isRecording = false {
        didSet { refreshFrame() }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var elapsed: TimeInterval = 0

    // MARK: 片段
    @Published var clips: [Clip] = [] {
        didSet { pruneUnrelatedSubtitles() }
    }
    @Published var selectedClipID: UUID?
    @Published var previewMode: PreviewMode = .clip

    // MARK: 字幕
    @Published var subtitles: [SubtitleSegment] = []
    @Published private(set) var subtitlesKey: String?
    /// 轉寫出來的原文（語音語言）；切換字幕語言時從這裡重新翻譯
    @Published private(set) var sourceSubtitles: [SubtitleSegment] = []
    /// 實際的語音語言（Whisper 代碼，例如 zh、ja）
    @Published private(set) var spokenLanguage: String?
    @Published var speechLanguage: SpeechLanguage = SpeechLanguage(rawValue: UserDefaults.standard.string(forKey: "speechLanguage") ?? "") ?? .zh {
        didSet { UserDefaults.standard.set(speechLanguage.rawValue, forKey: "speechLanguage") }
    }
    @Published var subtitleLanguage: SubtitleLanguage = SubtitleLanguage(rawValue: UserDefaults.standard.string(forKey: "subtitleLanguage") ?? "") ?? .same {
        didSet {
            UserDefaults.standard.set(subtitleLanguage.rawValue, forKey: "subtitleLanguage")
            if oldValue != subtitleLanguage { applySubtitleLanguage() }
        }
    }
    /// 交給字幕畫面的 .translationTask 執行 Apple 本機翻譯
    @Published var translationConfig: TranslationSession.Configuration?
    @Published private(set) var subtitleStatus: String?        // 目前步驟標題
    @Published private(set) var subtitleStep: String?          // 例如「1/3」
    @Published private(set) var subtitleDetail: String?        // 這一步在做什麼
    @Published private(set) var subtitleStatusStart: Date?     // 這個步驟開始的時間（顯示經過秒數）
    @Published private(set) var downloadedBytes: Int64?        // 下載中：磁碟上已下載的大小
    @Published private(set) var downloadETA: TimeInterval?     // 下載中：預估剩餘時間

    // MARK: 輸出
    @Published private(set) var exports: [ExportItem] = []
    @Published var outputTab: OutputStatus = .latest
    @Published var outputFormat: OutputFormat = OutputFormat(rawValue: UserDefaults.standard.string(forKey: "outputFormat") ?? "") ?? .original {
        didSet { UserDefaults.standard.set(outputFormat.rawValue, forKey: "outputFormat") }
    }
    @Published var exportQuality: ExportQuality = ExportQuality(rawValue: UserDefaults.standard.string(forKey: "exportQuality") ?? "") ?? .standard {
        didSet { UserDefaults.standard.set(exportQuality.rawValue, forKey: "exportQuality") }
    }
    @Published private(set) var exportProgress: Double?
    /// 螢幕錄影權限沒生效（沒開，或開了但這個行程還沒重新啟動）
    @Published var needsScreenPermission = false
    @Published var appTab: AppTab = AppTab(rawValue: UserDefaults.standard.string(forKey: "appTab") ?? "") ?? .record {
        didSet { UserDefaults.standard.set(appTab.rawValue, forKey: "appTab") }
    }
    /// 字幕外觀（字色、外框、大小、位置），預覽與輸出共用
    @Published var subtitleStyle: SubtitleStyle = SubtitleStyle.load() {
        didSet { subtitleStyle.save() }
    }
    /// 新手引導（由 AppDelegate 設定）
    var showOnboarding: (() -> Void)?
    @Published private(set) var exportStatus: String?

    @Published var errorMessage: String?

    /// 浮動視窗顯示中才顯示淡色範圍框
    var panelVisible = true {
        didSet { refreshFrame() }
    }

    private let recorder = ScreenRecorder()
    private let selector = RegionSelector()
    private let transcriber = Transcriber()
    private var frameWindow: RecordingFrameWindow?
    private var frameStyle: FrameStyle?
    private var isSelecting = false
    private var timerTask: Task<Void, Never>?
    private var currentURL: URL?
    private var downloadMonitor: Task<Void, Never>?

    init() {
        region = Self.loadRegion()
    }

    /// App 啟動後呼叫：顯示上次的範圍框、載入片段、字幕、輸出
    func appDidLaunch() {
        refreshFrame()
        loadClips()
        loadSubtitles()
        exports = OutputLibrary.load()
        OutputLibrary.trashOrphanTranscripts()
        watchExportsFolder()
        // 模型下載過的話，開 App 時就在背景先載入，按「產生字幕」不用再等
        if Transcriber.isModelDownloaded {
            Task { _ = try? await transcriber.loadModel() }
        }
    }

    // MARK: 輸出資料夾監看：影片被拖到垃圾桶時，字幕稿跟著走、清單也更新

    private var exportsWatcher: DispatchSourceFileSystemObject?

    private func watchExportsFolder() {
        let fd = open(OutputLibrary.exportsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.exportsFolderChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        exportsWatcher = source
    }

    private func exportsFolderChanged() {
        OutputLibrary.trashOrphanTranscripts()
        let fm = FileManager.default
        let remaining = exports.filter { fm.fileExists(atPath: $0.url.path) }
        if remaining.count != exports.count {
            exports = remaining
            OutputLibrary.save(exports)
        }
    }

    var selectedClip: Clip? {
        clips.first { $0.id == selectedClipID }
    }

    /// 放進這次剪輯的片段（依順序）
    var activeClips: [Clip] { clips.filter { !$0.isStaged } }
    /// 暫存區的片段
    var stagedClips: [Clip] { clips.filter { $0.isStaged } }

    // MARK: - 框選

    func selectRegion() {
        guard !isRecording else { return }
        isSelecting = true
        refreshFrame()
        selector.begin(shortsMode: shortsMode) { [weak self] newRegion in
            guard let self else { return }
            self.isSelecting = false
            if let newRegion {
                self.region = newRegion
                self.errorMessage = nil
            }
            self.refreshFrame()
        }
    }

    // MARK: - 錄影

    func toggleRecording() {
        guard !isBusy else { return }
        Task {
            if isRecording { await stopRecording() } else { await startRecording() }
        }
    }

    private func startRecording() async {
        guard let region, let source = region.sourceRect() else {
            selectRegion()
            return
        }
        isBusy = true
        defer { isBusy = false }
        let url = ClipStorage.newClipURL()
        do {
            if captureMicrophone {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    errorMessage = String(localized: "沒有麥克風權限：請到「系統設定 › 隱私權與安全性 › 麥克風」允許 SoonCut，或先關掉麥克風。")
                    return
                }
            }
            let micID = microphoneID.flatMap { id in Self.microphones().contains { $0.id == id } ? id : nil }
            try await recorder.start(displayID: region.displayID,
                                     sourceRect: source,
                                     captureAudio: captureSystemAudio,
                                     captureMicrophone: captureMicrophone,
                                     microphoneID: micID,
                                     outputURL: url)
            currentURL = url
            isRecording = true
            errorMessage = nil
            needsScreenPermission = false
            startTimer()
        } catch {
            if Self.isScreenPermissionError(error) || !CGPreflightScreenCaptureAccess() {
                // 讓系統把 Soon-Cut 放進「螢幕與系統錄音」清單（第一次會跳系統對話框）。
                // ⚠️ 在系統設定打開權限後，這個執行中的行程仍然拿不到——要重新開啟 App 才生效，
                //    這就是「明明勾了還是不能錄」的原因，所以提示裡直接給「重新開啟」按鈕。
                CGRequestScreenCaptureAccess()
                needsScreenPermission = true
                errorMessage = nil
            } else {
                errorMessage = Self.describe(error)
            }
        }
    }

    static func isScreenPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func stopRecording() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await recorder.stop()
        } catch {
            errorMessage = Self.describe(error)
        }
        isRecording = false
        stopTimer()
        if let url = currentURL, FileManager.default.fileExists(atPath: url.path) {
            let clip = await ClipStorage.makeClip(url: url)
            let insertAt = clips.firstIndex(where: { $0.isStaged }) ?? clips.count
            clips.insert(clip, at: insertAt)   // 新片段放在使用中的最後
            selectedClipID = clip.id
            previewMode = .clip
            ClipStorage.saveLibrary(clips)
        }
        currentURL = nil
    }

    // MARK: - 片段

    func loadClips() {
        Task {
            let loaded = await ClipStorage.loadClips()
            clips = loaded
            if selectedClipID == nil { selectedClipID = loaded.last?.id }
        }
    }

    func reveal(_ clip: Clip) {
        Self.revealInFinder(clip.url)
    }

    func trash(_ clip: Clip) {
        do {
            // 同一個檔案剪開的其他片段還在用時，只移除這一段，不丟檔案
            let shared = clips.contains { $0.id != clip.id && $0.url == clip.url }
            if !shared {
                try FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
            }
            clips.removeAll { $0.id == clip.id }
            if selectedClipID == clip.id { selectedClipID = clips.last?.id }
            ClipStorage.saveLibrary(clips)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func openRawFolder() {
        NSWorkspace.shared.open(ClipStorage.rawDir)
    }

    /// 更新一個片段的保留區段（拖黃色把手、剪開、刪除區段都走這裡）
    func setRanges(clipID: UUID, _ ranges: [ClipRange]) {
        guard let i = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let cleaned = ClipStorage.sanitize(ranges, duration: clips[i].duration)
        guard !cleaned.isEmpty else { return }
        let startChanged = abs(clips[i].trimStart - cleaned[0].start) > 0.05
        clips[i].ranges = cleaned
        ClipStorage.saveLibrary(clips)
        if startChanged { refreshThumbnail(clipID) }
    }

    private func refreshThumbnail(_ id: UUID) {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        Task {
            let thumb = await ClipStorage.thumbnail(for: clip)
            if let i = clips.firstIndex(where: { $0.id == id }) { clips[i].thumbnail = thumb }
        }
    }

    /// 能不能在 time 把所在的黃色區段剪開（兩邊都至少要留最短長度）
    func canSplit(_ id: UUID, at time: Double) -> Bool {
        guard let c = clips.first(where: { $0.id == id }),
              let k = c.rangeIndex(containing: time) else { return false }
        let r = c.ranges[k]
        return time - r.start >= ClipStorage.minClipLength && r.end - time >= ClipStorage.minClipLength
    }

    /// 在 time 把所在的區段剪成兩段（同一個片段裡，膠卷條上變兩個黃色區塊）
    func splitRange(_ id: UUID, at time: Double) {
        guard canSplit(id, at: time),
              let c = clips.first(where: { $0.id == id }),
              let k = c.rangeIndex(containing: time) else { return }
        var ranges = c.ranges
        let r = ranges[k]
        ranges[k] = ClipRange(start: r.start, end: time)
        ranges.insert(ClipRange(start: time, end: r.end), at: k + 1)
        setRanges(clipID: id, ranges)
    }

    /// 能不能刪掉 time 所在的區段（至少要留一段）
    func canRemoveRange(_ id: UUID, at time: Double) -> Bool {
        guard let c = clips.first(where: { $0.id == id }) else { return false }
        return c.ranges.count > 1 && c.rangeIndex(containing: time) != nil
    }

    func removeRange(_ id: UUID, at time: Double) {
        guard canRemoveRange(id, at: time),
              let c = clips.first(where: { $0.id == id }),
              let k = c.rangeIndex(containing: time) else { return }
        var ranges = c.ranges
        ranges.remove(at: k)
        setRanges(clipID: id, ranges)
    }

    // MARK: - 匯入影片

    func importVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "匯入")
        panel.message = String(localized: "選擇要匯入的影片，會複製一份到 Soon-Cut 的片段資料夾，原檔不動")
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// 複製影片到片段資料夾並加到「剪輯片段」最後面
    func importFiles(_ urls: [URL]) {
        let videos = urls.filter { ClipStorage.videoExtensions.contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else {
            errorMessage = String(localized: "只能匯入 MP4、MOV、M4V 影片。")
            return
        }
        Task {
            var lastID: UUID?
            var failed: [String] = []
            for source in videos {
                let target = ClipStorage.importedClipURL(for: source)
                let copied = await Task.detached { () -> Bool in
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    return (try? FileManager.default.copyItem(at: source, to: target)) != nil
                }.value
                guard copied else { failed.append(source.lastPathComponent); continue }
                let clip = await ClipStorage.makeClip(url: target)
                guard clip.duration > 0 else { failed.append(source.lastPathComponent); continue }
                let insertAt = clips.firstIndex(where: { $0.isStaged }) ?? clips.count
                clips.insert(clip, at: insertAt)
                lastID = clip.id
            }
            if let lastID {
                selectedClipID = lastID
                previewMode = .clip
                ClipStorage.saveLibrary(clips)
            }
            errorMessage = failed.isEmpty ? nil : String(localized: "無法匯入：\(failed.joined(separator: "、"))")
        }
    }

    // MARK: - 麥克風

    struct Microphone: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static func microphones() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio,
                                         position: .unspecified)
            .devices
            .map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// 在同一區（使用中或暫存）裡把片段移到指定位置
    func moveClip(_ id: UUID, toIndex target: Int) {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        let staged = clip.isStaged
        var group = clips.filter { $0.isStaged == staged }
        let others = clips.filter { $0.isStaged != staged }
        guard let from = group.firstIndex(where: { $0.id == id }) else { return }
        let moved = group.remove(at: from)
        group.insert(moved, at: min(max(0, target), group.count))
        clips = staged ? others + group : group + others
        ClipStorage.saveLibrary(clips)
    }

    func moveClip(_ clip: Clip, by offset: Int) {
        let group = clip.isStaged ? stagedClips : activeClips
        guard let from = group.firstIndex(where: { $0.id == clip.id }) else { return }
        moveClip(clip.id, toIndex: from + offset)
    }

    /// 移進／移出暫存區。移回使用中時放在最後面
    func setStaged(_ id: UUID, _ staged: Bool) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].isStaged != staged else { return }
        var clip = clips.remove(at: i)
        clip.isStaged = staged
        if staged {
            clips.append(clip)
        } else {
            let insertAt = clips.firstIndex(where: { $0.isStaged }) ?? clips.count
            clips.insert(clip, at: insertAt)
        }
        ClipStorage.saveLibrary(clips)
    }

    /// 片段順序或剪輯點改變時，拼接預覽要重建、字幕可能要重轉
    var sequenceKey: String {
        activeClips.map { clip in
            clip.url.lastPathComponent + "@" + clip.ranges.map { "\($0.start)-\($0.end)" }.joined(separator: ",")
        }.joined(separator: "|")
    }

    // MARK: - 字幕

    var isTranscribing: Bool { subtitleStatus != nil }

    /// 有字幕，但片段在轉寫後又被剪過或重排
    var subtitlesOutdated: Bool {
        !subtitles.isEmpty && subtitlesKey != sequenceKey
    }

    func transcribeSequence() {
        guard !isTranscribing, !activeClips.isEmpty else { return }
        let key = sequenceKey
        let currentClips = activeClips
        Task {
            let modelReady = await transcriber.isModelLoaded
            let firstTime = !modelReady
            if firstTime {
                if Transcriber.isModelDownloaded {
                    showPreparing()
                } else {
                    showDownloading()
                }
            }
            do {
                if firstTime {
                    _ = try await transcriber.loadModel { [weak self] phase in
                        Task { @MainActor in self?.apply(phase) }
                    }
                }
                stopDownloadMonitor()
                setStep(firstTime ? "3/3" : nil,
                        String(localized: "轉寫字幕"),
                        firstTime ? String(localized: "模型準備好了，正在轉寫，通常比影片長度快很多。") : nil)
                let result = try await Composer.build(clips: currentClips)
                let transcript = try await transcriber.transcribe(asset: result.composition,
                                                                  pieces: result.pieces,
                                                                  language: speechLanguage.whisperCode)
                sourceSubtitles = transcript.segments
                spokenLanguage = transcript.language
                subtitlesKey = key
                errorMessage = nil
                stopDownloadMonitor()
                if subtitleLanguage.needsTranslation(from: transcript.language) {
                    startTranslation()   // 翻譯完才結束進度顯示
                    return
                }
                subtitles = localized(sourceSubtitles)
                saveSubtitles()
            } catch {
                errorMessage = String(localized: "轉寫失敗：\(Self.describe(error))")
            }
            stopDownloadMonitor()
            subtitleStatus = nil
            subtitleStep = nil
            subtitleDetail = nil
            subtitleStatusStart = nil
        }
    }

    private func apply(_ phase: ModelLoadPhase) {
        guard subtitleStatus != nil else { return }
        switch phase {
        case .downloading:
            if subtitleStep != "1/3" { showDownloading() }
        case .preparing:
            if subtitleStep != "2/3" { showPreparing() }
        }
    }

    private func showDownloading() {
        let size = ByteCountFormatter.string(fromByteCount: Transcriber.modelDownloadBytes, countStyle: .file)
        setStep("1/3", String(localized: "下載語音模型"),
                String(localized: "約 \(size)，只需要下載一次。一般網路約 5 分鐘，咖啡廳等較慢的網路可能要 15–20 分鐘，可以先去做別的事。"))
        startDownloadMonitor()
    }

    private func showPreparing() {
        stopDownloadMonitor()
        let note = Transcriber.isModelDownloaded && subtitleStep == nil
            ? String(localized: "載入已下載的語音模型。第一次使用需要把模型轉成這台 Mac 能用的格式，約 1–2 分鐘；完成後會自動開始轉寫。")
            : String(localized: "下載完成。正在把模型轉成這台 Mac 能用的格式，只有第一次需要，約 1–2 分鐘；完成後會自動開始轉寫，不用再按一次。")
        setStep("2/3", String(localized: "準備語音模型"), note)
    }

    private func setStep(_ step: String?, _ title: String, _ detail: String?) {
        subtitleStep = step
        subtitleStatus = title
        subtitleDetail = detail
        subtitleStatusStart = Date()
    }

    /// 每秒量一次模型資料夾大小，算出已下載多少、預估剩多久
    private func startDownloadMonitor() {
        stopDownloadMonitor()
        let base = Transcriber.modelsBase
        let total = Transcriber.modelDownloadBytes
        downloadMonitor = Task { [weak self] in
            var first: (time: Date, bytes: Int64)?
            while !Task.isCancelled {
                let bytes = await Task.detached { AppStore.directorySize(base) }.value
                guard let self else { return }
                self.downloadedBytes = bytes
                if bytes > 1_000_000 {
                    if let f = first {
                        let elapsed = Date().timeIntervalSince(f.time)
                        let rate = Double(bytes - f.bytes) / max(elapsed, 1)
                        if elapsed > 5, rate > 1_000 {
                            self.downloadETA = Double(max(0, total - bytes)) / rate
                        }
                    } else {
                        first = (Date(), bytes)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopDownloadMonitor() {
        downloadMonitor?.cancel()
        downloadMonitor = nil
        downloadedBytes = nil
        downloadETA = nil
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            if let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - 字幕語言與翻譯

    /// 語音是中文時，依字幕語言決定繁簡；其他情況原文照用
    private func localized(_ segments: [SubtitleSegment]) -> [SubtitleSegment] {
        guard spokenLanguage == "zh", subtitleLanguage == .zhHans else { return segments }
        return segments.map { var s = $0; s.text = ChineseScript.toSimplified(s.text); return s }
    }

    /// 切換字幕語言：已經有原文就直接重新產生（會覆蓋手動修改）
    private func applySubtitleLanguage() {
        guard !sourceSubtitles.isEmpty, let spoken = spokenLanguage, !isTranscribing else { return }
        if subtitleLanguage.needsTranslation(from: spoken) {
            startTranslation()
        } else {
            subtitles = localized(sourceSubtitles)
            saveSubtitles()
        }
    }

    private func startTranslation() {
        guard let spoken = spokenLanguage, let target = subtitleLanguage.localeIdentifier else { return }
        // 中文原文已經是繁體
        let source = Locale.Language(identifier: spoken == "zh" ? "zh-Hant" : spoken)
        let config = TranslationSession.Configuration(source: source, target: Locale.Language(identifier: target))
        setStep(nil, String(localized: "翻譯成\(subtitleLanguage.label)"),
                String(localized: "使用 macOS 內建的本機翻譯，不會上傳。第一次翻譯某種語言時，系統會請你下載語言包。"))
        if translationConfig == config {
            translationConfig?.invalidate()   // 同樣的設定也要重新跑一次
        } else {
            translationConfig = config
        }
    }

    /// 字幕畫面翻譯完成後呼叫
    func applyTranslations(_ translated: [String: String]) {
        subtitles = sourceSubtitles.map { seg in
            var s = seg
            if let t = translated[seg.id.uuidString] { s.text = t }
            return s
        }
        saveSubtitles()
        finishSubtitleStatus()
    }

    func translationFailed(_ error: Error) {
        errorMessage = String(localized: "翻譯失敗：\(Self.describe(error))（字幕先保留原文）")
        subtitles = sourceSubtitles
        saveSubtitles()
        finishSubtitleStatus()
    }

    private func finishSubtitleStatus() {
        subtitleStatus = nil
        subtitleStep = nil
        subtitleDetail = nil
        subtitleStatusStart = nil
    }

    func updateSubtitle(id: UUID, text: String) {
        guard let i = subtitles.firstIndex(where: { $0.id == id }) else { return }
        subtitles[i].text = text
        saveSubtitles()
    }

    func deleteSubtitle(id: UUID) {
        subtitles.removeAll { $0.id == id }
        saveSubtitles()
    }

    /// 預覽與輸出實際使用的字幕：片段改過、字幕對不上時先不套用
    var effectiveSubtitles: [SubtitleSegment] {
        subtitlesOutdated ? [] : subtitles
    }

    /// 片段改過但仍要沿用舊字幕
    func keepOutdatedSubtitles() {
        subtitlesKey = sequenceKey
        saveSubtitles()
    }

    /// 字幕對應的片段都不在「剪輯片段」裡了（刪掉或移到暫存）→ 清掉舊字幕
    private func pruneUnrelatedSubtitles() {
        guard !subtitles.isEmpty || !sourceSubtitles.isEmpty, !isTranscribing else { return }
        let subtitleFiles = Set((subtitlesKey ?? "").split(separator: "|").compactMap {
            $0.split(separator: "@").first.map(String.init)
        })
        let currentFiles = Set(activeClips.map { $0.url.lastPathComponent })
        if subtitleFiles.isDisjoint(with: currentFiles) {
            clearSubtitles()
        }
    }

    func clearSubtitles() {
        subtitles = []
        sourceSubtitles = []
        spokenLanguage = nil
        subtitlesKey = nil
        saveSubtitles()
    }

    private var subtitlesURL: URL { ClipStorage.rawDir.appendingPathComponent("subtitles.json") }

    private func saveSubtitles() {
        let file = SubtitleFile(sequenceKey: subtitlesKey ?? "", segments: subtitles,
                                sourceSegments: sourceSubtitles, spokenLanguage: spokenLanguage)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: subtitlesURL, options: .atomic)
        }
    }

    private func loadSubtitles() {
        guard let data = try? Data(contentsOf: subtitlesURL),
              let file = try? JSONDecoder().decode(SubtitleFile.self, from: data) else { return }
        subtitles = file.segments
        sourceSubtitles = file.sourceSegments ?? file.segments
        spokenLanguage = file.spokenLanguage
        subtitlesKey = file.sequenceKey.isEmpty ? nil : file.sequenceKey
    }

    // MARK: - 輸出

    var isExporting: Bool { exportStatus != nil }

    /// 只輸出字幕檔（SRT），不合成影片。讓使用者選存放位置。
    func exportSubtitlesOnly() {
        let captions = effectiveSubtitles
        let text = SRTWriter.srt(from: captions)
        guard !text.isEmpty else { return }

        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "soon-cut-\(f.string(from: Date())).srt"
        panel.directoryURL = ClipStorage.rootDir
        panel.canCreateDirectories = true
        panel.message = String(localized: "字幕時間對應目前預排片段接起來的全片")

        let save: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                Self.revealInFinder(url)
            } catch {
                self?.errorMessage = Self.describe(error)
            }
        }
        // 浮動視窗在最上層，用 sheet 掛在它上面，存檔視窗才不會被蓋住
        if let window = FloatingPanel.current {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }

    func exportVideo() {
        guard !isExporting, !activeClips.isEmpty else { return }
        let url = OutputLibrary.newExportURL()
        exportStatus = String(localized: "輸出中…")
        exportProgress = 0
        let format = outputFormat
        let quality = exportQuality
        let captions = effectiveSubtitles
        Task {
            do {
                let duration = try await Exporter.export(
                    clips: activeClips, subtitles: captions, style: subtitleStyle,
                    format: format, quality: quality, to: url,
                    progress: { [weak self] p in
                        Task { @MainActor in
                            if self?.exportStatus != nil { self?.exportProgress = p }
                        }
                    })
                let item = ExportItem(file: url.lastPathComponent, status: .latest,
                                      createdAt: Date(), duration: duration,
                                      format: "\(format.label) · \(quality.label)")
                // 同名 .srt 字幕稿（失敗不影響影片本身）
                try? SRTWriter.write(captions, nextTo: url)
                exports.insert(item, at: 0)
                OutputLibrary.save(exports)
                outputTab = .latest
                previewMode = .output
                errorMessage = nil
            } catch {
                errorMessage = String(localized: "輸出失敗：\(Self.describe(error))")
            }
            exportStatus = nil
            exportProgress = nil
        }
    }

    func exports(in status: OutputStatus) -> [ExportItem] {
        exports.filter { $0.status == status }
    }

    func setStatus(_ item: ExportItem, _ status: OutputStatus) {
        guard let i = exports.firstIndex(where: { $0.id == item.id }) else { return }
        exports[i].status = status
        OutputLibrary.save(exports)
    }

    func reveal(_ item: ExportItem) {
        Self.revealInFinder(item.url)
    }

    func trash(_ item: ExportItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            let srt = SRTWriter.url(for: item.url)
            if FileManager.default.fileExists(atPath: srt.path) {
                try? FileManager.default.trashItem(at: srt, resultingItemURL: nil)
            }
            exports.removeAll { $0.id == item.id }
            OutputLibrary.save(exports)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - 範圍框

    /// 錄影中：紅框；浮動視窗顯示中、沒在框選：淡色框；其他情況隱藏
    private func refreshFrame() {
        let wanted: FrameStyle?
        if isRecording {
            wanted = .recording
        } else if panelVisible, !isSelecting, region != nil {
            wanted = .idle
        } else {
            wanted = nil
        }

        guard let wanted, let rect = region?.rect else {
            frameWindow?.orderOut(nil)
            frameWindow = nil
            frameStyle = nil
            return
        }
        if frameStyle == wanted, let w = frameWindow,
           w.frame == rect.insetBy(dx: -RecordingFrameWindow.inset, dy: -RecordingFrameWindow.inset) {
            return
        }
        frameWindow?.orderOut(nil)
        let w = RecordingFrameWindow(rect: rect, style: wanted)
        w.orderFrontRegardless()
        frameWindow = w
        frameStyle = wanted
    }

    // MARK: - 計時

    private func startTimer() {
        let start = Date()
        elapsed = 0
        timerTask = Task {
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(start)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - 儲存

    private func saveRegion() {
        if let region, let data = try? JSONEncoder().encode(region) {
            UserDefaults.standard.set(data, forKey: "region")
        }
    }

    private static func loadRegion() -> CaptureRegion? {
        guard let data = UserDefaults.standard.data(forKey: "region") else { return nil }
        return try? JSONDecoder().decode(CaptureRegion.self, from: data)
    }

    /// 在 Finder 中選取檔案並把 Finder 帶到最前面。
    /// 浮動視窗不會讓本 App 變成作用中，所以要明確叫起 Finder。
    static func revealInFinder(_ url: URL) {
        // 浮動視窗是 nonactivating，App 本身不在前景；macOS 14 起非前景 App
        // 叫別的 App 跳到前面會被系統忽略，Finder 只會在背景開，看起來像沒反應。
        // 所以先讓自己成為前景，再把前景「讓給」Finder。
        NSApp.activate()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            NSApp.yieldActivation(to: finder)
            finder.activate(from: .current)
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801 {
            return String(localized: "沒有螢幕錄影權限：請到「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」允許，然後重新啟動 App。")
        }
        return error.localizedDescription
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = Int(max(0, t).rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
}
