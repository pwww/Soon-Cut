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
    var needsTranslation: Bool?              // 背景轉完、還沒翻譯成字幕語言
}

// MARK: - 背景工作：產生字幕、輸出影片各自排隊；切換專案時照樣進行

enum JobKind: Equatable {
    case transcribe, export
}

struct BackgroundJob: Identifiable, Equatable {
    let id = UUID()
    let kind: JobKind
    let projectID: UUID
    var projectName: String
    var isRunning = false
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
        didSet {
            guard !isSwitchingProject else { return }
            pruneUnrelatedSubtitles()
            restoreStashedSubtitles()
        }
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
        setUpProjects()
        loadClips()
        loadSubtitles()
        CaptionWorkspace.ensureFiles()
        captionFileChanged()          // 關著 App 時在外面改過的話，先套回來
        syncCaptionFile()
        watchCaptionFolder()
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

    // MARK: - 專案

    @Published private(set) var projects: [ProjectInfo] = []
    @Published private(set) var currentProjectID = UUID()
    /// 切換專案中：暫停「片段變了就清字幕」之類的連動
    private var isSwitchingProject = false

    var currentProject: ProjectInfo? { projects.first { $0.id == currentProjectID } }
    /// 產生字幕、輸出在背景照跑，切換專案只在錄影中不行
    var canSwitchProject: Bool { !isRecording && !isBusy }

    private func setUpProjects() {
        projects = Projects.migrateIfNeeded()
        let saved = UserDefaults.standard.string(forKey: "currentProjectID").flatMap(UUID.init(uuidString:))
        currentProjectID = projects.first { $0.id == saved }?.id ?? projects[0].id
        ClipStorage.currentProjectDir = Projects.folder(currentProjectID)
        loadSubtitleStash()
        // 舊版只有一份 Captions/captions.srt：改名成目前專案的校正檔
        let legacy = CaptionWorkspace.dir.appendingPathComponent("captions.srt")
        let fm = FileManager.default
        if currentProject != nil, fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: captionFileURL.path) {
            try? fm.moveItem(at: legacy, to: captionFileURL)
        }
    }

    func switchProject(to id: UUID) {
        guard id != currentProjectID, canSwitchProject, projects.contains(where: { $0.id == id }) else { return }
        touchCurrentProject()
        if translatingProjectID == currentProjectID {
            // 翻譯是在字幕畫面跑的：先停下，下次打開這個專案會接著翻（已記在 subtitles.json）
            translatingProjectID = nil
            translationConfig = nil
        }
        isSwitchingProject = true
        clearEditHistory()
        subtitles = []
        sourceSubtitles = []
        spokenLanguage = nil
        subtitlesKey = nil
        selectedClipID = nil
        clips = []

        currentProjectID = id
        UserDefaults.standard.set(id.uuidString, forKey: "currentProjectID")
        ClipStorage.currentProjectDir = Projects.folder(id)
        loadSubtitles()
        loadSubtitleStash()
        exports = OutputLibrary.load()
        // 新專案的校正檔：先當作「跟 App 一致」，再看外面有沒有改過
        lastSyncedSRT = SRTWriter.srt(from: subtitles)
        lastCaptionModified = captionFileModified()
        if FileManager.default.fileExists(atPath: captionFileURL.path) {
            captionFileChanged()
        }
        syncCaptionFile()
        Task {
            let loaded = await ClipStorage.loadClips()
            clips = loaded
            selectedClipID = loaded.first(where: { !$0.isStaged })?.id ?? loaded.first?.id
            isSwitchingProject = false
        }
    }

    func newProject(named name: String) {
        guard canSwitchProject else { return }
        let p = Projects.create(name: name)
        projects.insert(p, at: 0)
        Projects.saveIndex(projects)
        switchProject(to: p.id)
        appTab = .record
    }

    func renameCurrentProject(_ name: String) {
        guard let i = projects.firstIndex(where: { $0.id == currentProjectID }) else { return }
        let oldURL = captionFileURL
        projects[i].name = name
        projects[i].updatedAt = Date()
        Projects.saveIndex(projects)
        let newURL = captionFileURL
        if oldURL != newURL, FileManager.default.fileExists(atPath: oldURL.path) {
            try? FileManager.default.moveItem(at: oldURL, to: newURL)
            lastCaptionModified = captionFileModified()
        }
    }

    /// 刪除專案：資料夾丟到垃圾桶；只有這個專案用到的影片檔也一起丟（都可以從垃圾桶救回）
    func deleteCurrentProject() {
        guard projects.count > 1, canSwitchProject,
              !jobs.contains(where: { $0.projectID == currentProjectID }),
              let doomed = projects.first(where: { $0.id == currentProjectID }) else { return }
        let ownFiles = Set(clips.map { $0.url.lastPathComponent })
        let captionFile = captionFileURL
        let othersUse = Projects.filesUsed(excluding: doomed.id)
        let next = projects.first { $0.id != doomed.id }!
        switchProject(to: next.id)
        projects.removeAll { $0.id == doomed.id }
        Projects.saveIndex(projects)
        let fm = FileManager.default
        try? fm.trashItem(at: Projects.dir.appendingPathComponent(doomed.id.uuidString), resultingItemURL: nil)
        if fm.fileExists(atPath: captionFile.path) { try? fm.trashItem(at: captionFile, resultingItemURL: nil) }
        for file in ownFiles.subtracting(othersUse) {
            try? fm.trashItem(at: ClipStorage.rawDir.appendingPathComponent(file), resultingItemURL: nil)
        }
    }

    /// 把這個片段（目前的黃色區段與速度）另存成新專案，並切過去準備上字幕
    func saveClipAsNewProject(_ clipID: UUID, name: String) {
        guard canSwitchProject, let clip = clips.first(where: { $0.id == clipID }) else { return }
        let p = Projects.create(name: name)
        Projects.writeLibrary([LibraryEntry(id: UUID().uuidString, file: clip.url.lastPathComponent,
                                            trimStart: clip.trimStart, trimEnd: clip.trimEnd, staged: false,
                                            ranges: clip.ranges, speed: clip.speed == 1 ? nil : clip.speed)],
                              for: p.id)
        projects.insert(p, at: 0)
        Projects.saveIndex(projects)
        switchProject(to: p.id)
        appTab = .edit
        previewMode = .subtitle
    }

    private func touchCurrentProject() {
        guard let i = projects.firstIndex(where: { $0.id == currentProjectID }) else { return }
        projects[i].updatedAt = Date()
        Projects.saveIndex(projects)
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
                || Projects.filesUsed(excluding: currentProjectID).contains(clip.url.lastPathComponent)
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
        clearEditHistory()   // 手動剪過就不能再復原／重做字幕剪輯，避免把這次的修改蓋掉
        let startChanged = abs(clips[i].trimStart - cleaned[0].start) > 0.05
        clips[i].ranges = cleaned
        ClipStorage.saveLibrary(clips)
        if startChanged { refreshThumbnail(clipID) }
    }

    /// 片段速度（預覽與輸出都照這個）。改了之後字幕時間會對不上，會提示重新產生
    func setSpeed(clipID: UUID, _ speed: Double) {
        guard let i = clips.firstIndex(where: { $0.id == clipID }), clips[i].speed != speed else { return }
        clearEditHistory()
        clips[i].speed = speed
        ClipStorage.saveLibrary(clips)
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
        clearEditHistory()
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
                + (clip.speed == 1 ? "" : "x\(clip.speed)")
        }.joined(separator: "|")
    }

    // MARK: - 背景工作佇列

    @Published private(set) var jobs: [BackgroundJob] = []
    private var jobWork: [UUID: () async -> Void] = [:]
    /// 正在轉寫的是哪個專案（進度畫面只在那個專案顯示）
    @Published private(set) var transcribeProjectID: UUID?
    /// 正在輸出的是哪個專案
    @Published private(set) var exportProjectID: UUID?
    /// 正在翻譯字幕的專案（翻譯在字幕畫面進行，只限目前專案）
    @Published private(set) var translatingProjectID: UUID?

    private func enqueue(_ kind: JobKind, work: @escaping () async -> Void) {
        let job = BackgroundJob(kind: kind, projectID: currentProjectID,
                                projectName: currentProject?.name ?? "")
        jobs.append(job)
        jobWork[job.id] = work
        runNext(kind)
    }

    private func runNext(_ kind: JobKind) {
        guard !jobs.contains(where: { $0.kind == kind && $0.isRunning }),
              let i = jobs.firstIndex(where: { $0.kind == kind }) else { return }
        jobs[i].isRunning = true
        let id = jobs[i].id
        let work = jobWork.removeValue(forKey: id)
        Task {
            await work?()
            jobs.removeAll { $0.id == id }
            runNext(kind)
        }
    }

    /// 取消目前專案還在排隊（尚未開始）的工作
    func cancelQueued(_ kind: JobKind) {
        let ids = jobs.filter { $0.kind == kind && $0.projectID == currentProjectID && !$0.isRunning }.map(\.id)
        jobs.removeAll { ids.contains($0.id) }
        ids.forEach { jobWork[$0] = nil }
    }

    func job(_ kind: JobKind, for project: UUID) -> BackgroundJob? {
        jobs.first { $0.kind == kind && $0.projectID == project }
    }

    /// 這個專案的工作排在第幾個（1＝下一個），以及前面正在做的是哪個專案
    func queueInfo(_ kind: JobKind) -> (position: Int, runningProject: String)? {
        let list = jobs.filter { $0.kind == kind }
        guard let mine = list.firstIndex(where: { $0.projectID == currentProjectID }), !list[mine].isRunning else { return nil }
        let running = list.first(where: \.isRunning)?.projectName ?? ""
        return (mine, running)
    }

    /// 別的專案正在做這類工作（這個專案按下去會排隊）
    func otherProjectBusy(_ kind: JobKind) -> String? {
        jobs.first { $0.kind == kind && $0.isRunning && $0.projectID != currentProjectID }?.projectName
    }

    private func projectName(_ id: UUID) -> String { projects.first { $0.id == id }?.name ?? "" }

    // MARK: - 字幕

    /// 目前專案有字幕工作（排隊、轉寫中或翻譯中）
    var isTranscribing: Bool {
        job(.transcribe, for: currentProjectID) != nil || translatingProjectID == currentProjectID
    }
    /// 進度畫面要不要在這個專案顯示
    var transcribeRunningHere: Bool { subtitleStatus != nil && transcribeProjectID == currentProjectID }

    /// 有字幕，但片段在轉寫後又被剪過或重排
    var subtitlesOutdated: Bool {
        !subtitles.isEmpty && subtitlesKey != sequenceKey
    }

    func transcribeSequence() {
        guard !isTranscribing, !activeClips.isEmpty else { return }
        clearEditHistory()
        let projectID = currentProjectID
        let key = sequenceKey
        let currentClips = activeClips
        let speech = speechLanguage.whisperCode
        let target = subtitleLanguage
        enqueue(.transcribe) { [weak self] in
            await self?.runTranscription(projectID: projectID, key: key, clips: currentClips,
                                         speech: speech, target: target)
        }
    }

    private func runTranscription(projectID: UUID, key: String, clips: [Clip],
                                  speech: String?, target: SubtitleLanguage) async {
        transcribeProjectID = projectID
        let modelReady = await transcriber.isModelLoaded
        let firstTime = !modelReady
        if firstTime {
            if Transcriber.isModelDownloaded { showPreparing() } else { showDownloading() }
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
            let result = try await Composer.build(clips: clips)
            let transcript = try await transcriber.transcribe(asset: result.composition,
                                                              pieces: result.pieces,
                                                              language: speech)
            let display = Self.localized(transcript.segments, spoken: transcript.language, target: target)
            let needsTranslation = target.needsTranslation(from: transcript.language)
            if projectID == currentProjectID {
                sourceSubtitles = transcript.segments
                spokenLanguage = transcript.language
                subtitlesKey = key
                subtitles = display
                errorMessage = nil
                saveSubtitles()
                if needsTranslation { startTranslation() }
            } else {
                // 使用者已經切到別的專案：直接存進原專案，回去時就看得到
                let file = SubtitleFile(sequenceKey: key, segments: display, sourceSegments: transcript.segments,
                                        spokenLanguage: transcript.language,
                                        needsTranslation: needsTranslation ? true : nil)
                if let data = try? JSONEncoder().encode(file) {
                    try? data.write(to: Projects.folder(projectID).appendingPathComponent("subtitles.json"), options: .atomic)
                }
                if let p = projects.first(where: { $0.id == projectID }) {
                    try? SRTWriter.srt(from: display).write(to: CaptionWorkspace.fileURL(for: p, among: projects),
                                                            atomically: true, encoding: .utf8)
                }
            }
        } catch {
            let name = projectName(projectID)
            errorMessage = projectID == currentProjectID
                ? String(localized: "轉寫失敗：\(Self.describe(error))")
                : String(localized: "「\(name)」轉寫失敗：\(Self.describe(error))")
        }
        stopDownloadMonitor()
        subtitleStatus = nil
        subtitleStep = nil
        subtitleDetail = nil
        subtitleStatusStart = nil
        transcribeProjectID = nil
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
        Self.localized(segments, spoken: spokenLanguage, target: subtitleLanguage)
    }

    static func localized(_ segments: [SubtitleSegment], spoken: String?, target: SubtitleLanguage) -> [SubtitleSegment] {
        guard spoken == "zh", target == .zhHans else { return segments }
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
        translatingProjectID = currentProjectID
        saveSubtitles()   // 先記下「還沒翻譯」，中途切走專案也不會忘
        if translationConfig == config {
            translationConfig?.invalidate()   // 同樣的設定也要重新跑一次
        } else {
            translationConfig = config
        }
    }

    /// 字幕畫面翻譯完成後呼叫
    func applyTranslations(_ translated: [String: String]) {
        guard translatingProjectID == currentProjectID else { return }   // 翻譯途中切走了專案
        translatingProjectID = nil
        subtitles = sourceSubtitles.map { seg in
            var s = seg
            if let t = translated[seg.id.uuidString] { s.text = t }
            return s
        }
        saveSubtitles()
        finishSubtitleStatus()
    }

    func translationFailed(_ error: Error) {
        guard translatingProjectID == currentProjectID else { return }
        translatingProjectID = nil
        errorMessage = String(localized: "翻譯失敗：\(Self.describe(error))（字幕先保留原文）")
        subtitles = sourceSubtitles
        saveSubtitles()
        finishSubtitleStatus()
    }

    private func finishSubtitleStatus() {
        translatingProjectID = nil
    }

    func updateSubtitle(id: UUID, text: String) {
        guard let i = subtitles.firstIndex(where: { $0.id == id }) else { return }
        subtitles[i].text = text
        saveSubtitles()
    }

    func deleteSubtitle(id: UUID) {
        if let seg = subtitles.first(where: { $0.id == id }) {
            recordEdit(String(localized: "刪除字幕「\(seg.text)」"))
        }
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
            stashCurrentSubtitles()   // 先收起來，片段拉回來時可以還原
            clearSubtitles()
        }
    }

    // MARK: 字幕暫存：片段拉去暫存區時字幕先收起來，原樣拉回來就還原（不用重新產生、校正也不會不見）

    private var stashURL: URL { ClipStorage.currentProjectDir.appendingPathComponent("subtitle-stash.json") }
    private var subtitleStash: [String: SubtitleFile] = [:]

    private func loadSubtitleStash() {
        guard let data = try? Data(contentsOf: stashURL),
              let stash = try? JSONDecoder().decode([String: SubtitleFile].self, from: data) else {
            subtitleStash = [:]
            return
        }
        subtitleStash = stash
    }

    private func stashCurrentSubtitles() {
        guard let key = subtitlesKey, !key.isEmpty, !subtitles.isEmpty else { return }
        subtitleStash[key] = SubtitleFile(sequenceKey: key, segments: subtitles,
                                          sourceSegments: sourceSubtitles, spokenLanguage: spokenLanguage)
        if subtitleStash.count > 20, let oldest = subtitleStash.keys.first { subtitleStash[oldest] = nil }
        if let data = try? JSONEncoder().encode(subtitleStash) { try? data.write(to: stashURL, options: .atomic) }
    }

    private func restoreStashedSubtitles() {
        guard subtitles.isEmpty, !isTranscribing, !activeClips.isEmpty,
              let file = subtitleStash[sequenceKey] else { return }
        subtitles = file.segments
        sourceSubtitles = file.sourceSegments ?? file.segments
        spokenLanguage = file.spokenLanguage
        subtitlesKey = file.sequenceKey
        saveSubtitles()
    }

    func clearSubtitles() {
        subtitles = []
        sourceSubtitles = []
        spokenLanguage = nil
        subtitlesKey = nil
        saveSubtitles()
    }

    private var subtitlesURL: URL { ClipStorage.currentProjectDir.appendingPathComponent("subtitles.json") }

    private func saveSubtitles() {
        let file = SubtitleFile(sequenceKey: subtitlesKey ?? "", segments: subtitles,
                                sourceSegments: sourceSubtitles, spokenLanguage: spokenLanguage,
                                needsTranslation: translatingProjectID == currentProjectID ? true : nil)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: subtitlesURL, options: .atomic)
        }
        syncCaptionFile()
    }

    // MARK: - 字幕校正資料夾（給本機 LLM 改字）

    /// 目前專案的校正檔
    var captionFileURL: URL {
        guard let p = currentProject else { return CaptionWorkspace.dir.appendingPathComponent("captions.srt") }
        return CaptionWorkspace.fileURL(for: p, among: projects)
    }
    var captionFileName: String { captionFileURL.lastPathComponent }

    /// 最後一次跟目前專案校正檔同步的內容；拿來分辨「自己寫的」和「外面改的」
    private var lastSyncedSRT: String?
    private var captionWatcher: DispatchSourceFileSystemObject?
    /// 從資料夾套用修正後的短暫提示
    @Published var captionNote: String?

    func openCaptionFolder() {
        CaptionWorkspace.ensureFiles()
        syncCaptionFile()
        Self.revealInFinder(captionFileURL)
    }

    /// 把目前字幕寫成目前專案的校正檔（內容沒變就不寫）
    private func syncCaptionFile() {
        let text = SRTWriter.srt(from: subtitles)
        guard text != lastSyncedSRT else { return }
        lastSyncedSRT = text
        try? text.write(to: captionFileURL, atomically: true, encoding: .utf8)
        lastCaptionModified = captionFileModified()
    }

    /// 「重新整理」按鈕：立刻讀一次目前專案的校正檔
    func reloadCaptionFile() {
        let changed = captionFileChanged()
        if changed == 0 {
            captionNote = String(localized: "\(captionFileName) 沒有新的修改")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if self?.captionNote == String(localized: "\(captionFileName) 沒有新的修改") { self?.captionNote = nil }
            }
        }
    }

    private var captionPollTimer: Timer?
    private var lastCaptionModified: Date?

    private func captionFileModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: captionFileURL.path))?[.modificationDate] as? Date
    }

    private func watchCaptionFolder() {
        // 有些編輯器是直接覆寫檔案內容（不是換一個新檔），資料夾不會發出通知，
        // 所以另外每 2 秒看一次檔案的修改時間
        lastCaptionModified = captionFileModified()
        captionPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let modified = self.captionFileModified()
                if modified != self.lastCaptionModified {
                    self.lastCaptionModified = modified
                    self.captionFileChanged()
                }
            }
        }
        let fd = open(CaptionWorkspace.dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { _ = self?.captionFileChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        captionWatcher = source
    }

    /// 校正檔被外部改過：只套用文字，時間軸與句數以 App 為準
    @discardableResult
    private func captionFileChanged() -> Int {
        guard !isTranscribing,
              let text = try? String(contentsOf: captionFileURL, encoding: .utf8),
              text != lastSyncedSRT else { return 0 }
        let parsed = SRTWriter.parse(text)
        guard !parsed.isEmpty, !subtitles.isEmpty else { return 0 }
        lastSyncedSRT = text

        var changed = 0
        func apply(_ i: Int, _ newText: String) {
            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, subtitles[i].text != trimmed else { return }
            let old = subtitles[i].text
            subtitles[i].text = trimmed
            // 沒有翻譯（字幕＝原文）時，原文也一起改，之後切換語言才不會把修正蓋掉
            if let k = sourceSubtitles.firstIndex(where: { $0.id == subtitles[i].id }), sourceSubtitles[k].text == old {
                sourceSubtitles[k].text = trimmed
            }
            changed += 1
        }
        if parsed.count == subtitles.count {
            for (i, p) in parsed.enumerated() { apply(i, p.text) }
        } else {
            // 句數對不上：用開始時間配對，配不到的略過
            for p in parsed {
                if let i = subtitles.firstIndex(where: { abs($0.start - p.start) < 0.15 }) { apply(i, p.text) }
            }
        }
        guard changed > 0 else { return 0 }
        saveSubtitles()
        captionNote = String(localized: "已從字幕校正資料夾套用 \(changed) 句修正")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.captionNote = nil
        }
        return changed
    }

    // MARK: - 用字幕剪影片：刪掉一句＝把那段畫面與聲音從片段剪掉

    /// 復原／重做用的狀態快照（片段的剪輯點與字幕）
    struct EditSnapshot {
        let clips: [Clip]
        let subtitles: [SubtitleSegment]
        let sourceSubtitles: [SubtitleSegment]
        let subtitlesKey: String?
        let label: String
    }
    @Published private(set) var undoStack: [EditSnapshot] = []
    @Published private(set) var redoStack: [EditSnapshot] = []
    private static let historyLimit = 50

    var canUndoEdit: Bool { !undoStack.isEmpty && !isTranscribing && !isExporting }
    var canRedoEdit: Bool { !redoStack.isEmpty && !isTranscribing && !isExporting }

    private func snapshot(_ label: String) -> EditSnapshot {
        EditSnapshot(clips: clips, subtitles: subtitles, sourceSubtitles: sourceSubtitles,
                     subtitlesKey: subtitlesKey, label: label)
    }

    /// 做一個可以復原的動作之前呼叫
    private func recordEdit(_ label: String) {
        undoStack.append(snapshot(label))
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func restore(_ s: EditSnapshot) {
        clips = s.clips
        ClipStorage.saveLibrary(clips)
        subtitles = s.subtitles
        sourceSubtitles = s.sourceSubtitles
        subtitlesKey = s.subtitlesKey
        saveSubtitles()
    }

    func undoEdit() {
        guard canUndoEdit, let last = undoStack.popLast() else { return }
        redoStack.append(snapshot(last.label))
        restore(last)
    }

    func redoEdit() {
        guard canRedoEdit, let next = redoStack.popLast() else { return }
        undoStack.append(snapshot(next.label))
        restore(next)
    }

    func clearEditHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    var canCutBySubtitle: Bool { !subtitlesOutdated && !isTranscribing && !isExporting && !subtitles.isEmpty }

    func cutSentence(id: UUID) {
        guard canCutBySubtitle, let seg = subtitles.first(where: { $0.id == id }) else { return }
        cutSequence(from: seg.start, to: seg.end, label: seg.text)
    }

    /// 把全片時間軸上的 [from, to) 從各片段的黃色區段剪掉，字幕跟著往前移
    func cutSequence(from a: Double, to b: Double, label: String) {
        guard b - a > 0.05 else { return }
        let before = snapshot(String(localized: "剪掉「\(label)」"))
        let wasInSync = !subtitlesOutdated
        let minLen = ClipStorage.minClipLength

        var removed: [ClipRange] = []          // 全片時間軸上實際剪掉的區間
        var newRanges: [UUID: [ClipRange]] = [:]
        var cursor = 0.0
        for clip in activeClips {
            var kept: [ClipRange] = []
            let speed = max(clip.speed, 0.1)
            for r in clip.ranges {
                let segStart = cursor
                let segEnd = cursor + r.length / speed
                cursor = segEnd
                let os = max(a, segStart), oe = min(b, segEnd)
                guard oe - os > 0.01 else { kept.append(r); continue }
                var cutS = r.start + (os - segStart) * speed
                var cutE = r.start + (oe - segStart) * speed
                // 剩下的頭尾太短（不到最短長度）就一起剪掉，時間才算得準
                if cutS - r.start < minLen { cutS = r.start }
                if r.end - cutE < minLen { cutE = r.end }
                if cutS > r.start { kept.append(ClipRange(start: r.start, end: cutS)) }
                if cutE < r.end { kept.append(ClipRange(start: cutE, end: r.end)) }
                removed.append(ClipRange(start: segStart + (cutS - r.start) / speed,
                                         end: segStart + (cutE - r.start) / speed))
            }
            newRanges[clip.id] = kept
        }
        guard !removed.isEmpty else { return }

        // 套用到片段；整段都被剪掉的片段移到暫存區（不刪檔）
        for (id, kept) in newRanges {
            guard let i = clips.firstIndex(where: { $0.id == id }) else { continue }
            if kept.isEmpty {
                clips[i].isStaged = true
            } else if kept != clips[i].ranges {
                clips[i].ranges = kept
            }
        }
        // 暫存的片段排到最後，維持原本的排列規則
        clips = clips.filter { !$0.isStaged } + clips.filter { $0.isStaged }
        ClipStorage.saveLibrary(clips)

        // 字幕：被剪掉的句子拿掉，後面的往前移
        func shift(_ t: Double) -> Double {
            var total = 0.0
            for iv in removed {
                if t >= iv.end { total += iv.length }
                else if t > iv.start { return iv.start - total }
                else { break }
            }
            return t - total
        }
        func remap(_ list: [SubtitleSegment]) -> [SubtitleSegment] {
            list.compactMap { seg in
                let inside = removed.contains { seg.start >= $0.start - 0.05 && seg.end <= $0.end + 0.05 }
                if inside { return nil }
                var s = seg
                s.start = shift(seg.start)
                s.end = shift(seg.end)
                return s.end - s.start >= 0.15 ? s : nil
            }
        }
        subtitles = remap(subtitles)
        sourceSubtitles = remap(sourceSubtitles)
        if wasInSync { subtitlesKey = sequenceKey }
        saveSubtitles()
        undoStack.append(before)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        for id in newRanges.keys { refreshThumbnail(id) }
    }


    private func loadSubtitles() {
        guard let data = try? Data(contentsOf: subtitlesURL),
              let file = try? JSONDecoder().decode(SubtitleFile.self, from: data) else { return }
        subtitles = file.segments
        sourceSubtitles = file.sourceSegments ?? file.segments
        spokenLanguage = file.spokenLanguage
        subtitlesKey = file.sequenceKey.isEmpty ? nil : file.sequenceKey
        // 在背景轉完、還沒翻譯的：打開專案時接著翻
        if file.needsTranslation == true, let spoken = spokenLanguage, subtitleLanguage.needsTranslation(from: spoken) {
            startTranslation()
        }
    }

    // MARK: - 輸出

    /// 目前專案有輸出工作（排隊或輸出中）
    var isExporting: Bool { job(.export, for: currentProjectID) != nil }
    /// 進度要不要在這個專案顯示
    var exportRunningHere: Bool { exportStatus != nil && exportProjectID == currentProjectID }

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

    /// - Parameter burnCaptions: false＝只輸出影片，不把字幕燒進畫面（字幕稿 .srt 仍會放在旁邊）
    func exportVideo(burnCaptions: Bool = true) {
        guard !isExporting, !activeClips.isEmpty else { return }
        let projectID = currentProjectID
        let clips = activeClips
        let format = outputFormat
        let quality = exportQuality
        let style = subtitleStyle
        let captions = effectiveSubtitles
        enqueue(.export) { [weak self] in
            await self?.runExport(projectID: projectID, clips: clips, captions: captions, burn: burnCaptions,
                                  style: style, format: format, quality: quality)
        }
    }

    private func runExport(projectID: UUID, clips: [Clip], captions: [SubtitleSegment], burn: Bool,
                           style: SubtitleStyle, format: OutputFormat, quality: ExportQuality) async {
        let url = OutputLibrary.newExportURL()
        exportProjectID = projectID
        exportStatus = String(localized: "輸出中…")
        exportProgress = 0
        do {
            let duration = try await Exporter.export(
                clips: clips, subtitles: burn ? captions : [], style: style,
                format: format, quality: quality, to: url,
                progress: { [weak self] p in
                    Task { @MainActor in
                        if self?.exportStatus != nil { self?.exportProgress = p }
                    }
                })
            let item = ExportItem(file: url.lastPathComponent, status: .latest,
                                  createdAt: Date(), duration: duration,
                                  format: burn || captions.isEmpty
                                      ? "\(format.label) · \(quality.label)"
                                      : "\(format.label) · \(quality.label) · \(String(localized: "無字幕"))")
            // 同名 .srt 字幕稿（失敗不影響影片本身）
            try? SRTWriter.write(captions, nextTo: url)
            if projectID == currentProjectID {
                exports.insert(item, at: 0)
                OutputLibrary.save(exports)
                outputTab = .latest
                previewMode = .output
                errorMessage = nil
            } else {
                // 已經切到別的專案：加進原專案的輸出清單
                let indexURL = Projects.folder(projectID).appendingPathComponent("exports.json")
                var list = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([ExportItem].self, from: $0) } ?? []
                list.insert(item, at: 0)
                if let data = try? JSONEncoder().encode(list) { try? data.write(to: indexURL, options: .atomic) }
                captionNote = String(localized: "「\(projectName(projectID))」的影片輸出完成")
            }
        } catch {
            errorMessage = projectID == currentProjectID
                ? String(localized: "輸出失敗：\(Self.describe(error))")
                : String(localized: "「\(projectName(projectID))」輸出失敗：\(Self.describe(error))")
        }
        exportStatus = nil
        exportProgress = nil
        exportProjectID = nil
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
