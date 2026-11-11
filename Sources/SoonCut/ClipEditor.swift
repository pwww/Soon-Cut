import SwiftUI
import AVKit

// MARK: - 單一片段：預覽＋膠卷條（多個黃色區段）

struct ClipEditor: View {
    @EnvironmentObject var store: AppStore
    let clip: Clip
    let isRecording: Bool

    @State private var player = AVPlayer()
    @State private var draftRanges: [ClipRange] = []
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?
    @AppStorage("clipPlayerFraction") private var playerFraction: Double = 0.6
    @Environment(\.previewAreaHeight) private var areaHeight
    @AppStorage("previewCollapsed") private var previewCollapsed = false

    private var keptLength: Double { draftRanges.reduce(0) { $0 + $1.length } }
    private var currentRangeIndex: Int? {
        draftRanges.firstIndex { currentTime >= $0.start && currentTime < $0.end }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if clip.isStaged {
                // 暫存區的片段不會出現在「全片」；改速度、剪輯都只影響它自己
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill")
                    Text("這個片段在暫存區，不會放進「全片」的預覽與輸出。")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("加回預排片段") { store.setStaged(clip.id, false) }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .controlSize(.small)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            PreviewHeader(collapsed: $previewCollapsed)
            if !previewCollapsed {
                PlayerView(player: player)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(height: PreviewSizing.height(fraction: playerFraction, area: areaHeight))

                ResizeHandle(height: PreviewSizing.binding(fraction: $playerFraction, area: areaHeight),
                             defaultHeight: areaHeight * 0.6)
            }

            FilmstripTrimmer(
                url: clip.url,
                duration: clip.duration,
                ranges: $draftRanges,
                activeIndex: currentRangeIndex,
                playhead: currentTime,
                onScrub: { t in
                    player.pause()
                    currentTime = t
                    player.seek(to: cmTime(toPlayer(t)), toleranceBefore: .zero, toleranceAfter: .zero)
                },
                onCommit: {
                    store.setRanges(clipID: clip.id, draftRanges)
                    applyRangesToPlayer()
                }
            )
            .frame(height: 48)
            .padding(.horizontal, 6)   // 把手離視窗縮放邊框遠一點

            HStack(spacing: 8) {
                Text("保留 \(draftRanges.count) 段　共 \(formatTime(keptLength / max(clip.speed, 0.1)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.splitRange(clip.id, at: currentTime)
                } label: {
                    Label("在這裡剪開", systemImage: "scissors")
                }
                .disabled(!store.canSplit(clip.id, at: currentTime))
                .keyboardShortcut("b", modifiers: .command)
                .help("在白色播放線的位置把黃色區段剪成兩段（⌘B），再拉把手留出要跳過的部分")

                Button {
                    store.removeRange(clip.id, at: currentTime)
                } label: {
                    Label("刪除這段", systemImage: "trash")
                }
                .disabled(!store.canRemoveRange(clip.id, at: currentTime))
                .help("刪掉播放線所在的黃色區段")

                if clip.isTrimmed {
                    Button("還原") {
                        store.setRanges(clipID: clip.id, [ClipRange(start: 0, end: clip.duration)])
                    }
                    .buttonStyle(.borderless)
                    .help("回到完整長度、只有一段")
                }
            }
            .controlSize(.small)
            .font(.caption)

            HStack(spacing: 8) {
                Text("速度").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { clip.speed },
                    set: { store.setSpeed(clipID: clip.id, $0) }
                )) {
                    ForEach(SpeedOption.all, id: \.self) { v in
                        Text(SpeedOption.label(v)).tag(v)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("這個片段的播放速度，預覽和輸出都照這個速度（聲音會保持原本音高）")
            }
            .controlSize(.small)
        }
        .onAppear {
            reload()
            addObserver()
        }
        .onChange(of: clip.speed) { reload(keepPosition: true) }
        .onChange(of: clip.id) { reload() }
        .onChange(of: clip.ranges) {
            // 剪開、刪除、還原後同步
            draftRanges = clip.ranges
            applyRangesToPlayer()
        }
        .onChange(of: isRecording) {
            if isRecording { player.pause() }
        }
        .onChange(of: previewCollapsed) {
            if previewCollapsed { player.pause() }
        }
        .onDisappear {
            player.pause()
            removeObserver()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            // 播完最後一段回到第一段開頭
            if let item = note.object as? AVPlayerItem, item === player.currentItem {
                seek(to: draftRanges.first?.start ?? 0)
            }
        }
    }

    // 播放器的時間是「變速後」的時間（播放器的時間軸、長度顯示都會跟著速度）；
    // 膠卷條、剪開、黃色區段用的是原始影片時間。兩者用速度換算。
    private var speed: Double { max(clip.speed, 0.1) }
    private func toPlayer(_ source: Double) -> Double { source / speed }
    private func fromPlayer(_ shown: Double) -> Double { shown * speed }

    private func reload(keepPosition: Bool = false) {
        draftRanges = clip.ranges
        let resumeAt = currentTime
        let wasPlaying = player.rate != 0
        player.pause()
        player.replaceCurrentItem(with: makeItem())
        applyRangesToPlayer()
        if keepPosition, draftRanges.contains(where: { resumeAt >= $0.start && resumeAt < $0.end }) {
            seek(to: resumeAt)
        } else {
            seek(to: draftRanges.first?.start ?? 0)
        }
        if wasPlaying && keepPosition { player.play() }
    }

    /// 原速直接播檔案；變速時把整個檔案包成一條縮放過的時間軸，預覽就是變速後的樣子
    private func makeItem() -> AVPlayerItem {
        let asset = AVURLAsset(url: clip.url)
        guard abs(clip.speed - 1) > 0.001 else { return AVPlayerItem(asset: asset) }
        let composition = AVMutableComposition()
        let full = CMTimeRange(start: .zero, duration: cmTime(clip.duration))
        do {
            try composition.insertTimeRange(full, of: asset, at: .zero)
            // 保留原影片的方向（直拍、旋轉過的匯入影片）
            for track in composition.tracks(withMediaType: .video) {
                if let source = asset.tracks(withMediaType: .video).first {
                    track.preferredTransform = source.preferredTransform
                }
            }
            composition.scaleTimeRange(full, toDuration: cmTime(clip.duration / speed))
        } catch {
            return AVPlayerItem(asset: asset)
        }
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .spectral   // 變速時保持音高
        return item
    }

    private func applyRangesToPlayer() {
        player.currentItem?.forwardPlaybackEndTime = cmTime(toPlayer(draftRanges.last?.end ?? clip.duration))
    }

    private func seek(to t: Double) {
        currentTime = t
        player.seek(to: cmTime(toPlayer(t)), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func addObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
            let now = fromPlayer(CMTimeGetSeconds(t))
            currentTime = now
            skipGapIfNeeded(at: now)
        }
    }

    /// 播放中走到沒選的空隙：跳到下一個黃色區段；後面沒有了就停在第一段開頭
    private func skipGapIfNeeded(at now: Double) {
        guard player.rate != 0, !draftRanges.isEmpty else { return }
        let inside = draftRanges.contains { now >= $0.start - 0.03 && now < $0.end }
        guard !inside else { return }
        if let next = draftRanges.first(where: { $0.start > now }) {
            seek(to: next.start)
        } else {
            player.pause()
            seek(to: draftRanges[0].start)
        }
    }

    private func removeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }
}

// MARK: - 膠卷條：多個黃色區段，各自有左右把手

struct FilmstripTrimmer: View {
    let url: URL
    let duration: Double
    @Binding var ranges: [ClipRange]
    var activeIndex: Int?
    var playhead: Double?
    var onScrub: (Double) -> Void
    var onCommit: () -> Void

    @State private var frames: [NSImage] = []
    private let frameCount = 10
    private let handleWidth: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack(alignment: .topLeading) {
                // 影格；拖動＝移動播放位置
                HStack(spacing: 0) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(frameCount), height: height)
                            .clipped()
                    }
                }
                .frame(width: width, height: height, alignment: .leading)
                .background(Color.gray.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { v in
                            onScrub(min(max(0, time(for: v.location.x, width: width)), duration))
                        }
                )

                // 沒選的空隙變暗
                ForEach(Array(gaps().enumerated()), id: \.offset) { _, gap in
                    Rectangle()
                        .fill(Color.black.opacity(0.62))
                        .frame(width: max(0, x(for: gap.end, width: width) - x(for: gap.start, width: width)),
                               height: height)
                        .offset(x: x(for: gap.start, width: width))
                        .allowsHitTesting(false)
                }

                // 黃色區段
                ForEach(ranges.indices, id: \.self) { i in
                    let xs = x(for: ranges[i].start, width: width)
                    let xe = x(for: ranges[i].end, width: width)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.yellow, lineWidth: activeIndex == i ? 4 : 2.5)
                        .frame(width: max(handleWidth * 2, xe - xs), height: height)
                        .offset(x: xs)
                        .allowsHitTesting(false)

                    handle(systemImage: "chevron.compact.left")
                        .offset(x: xs)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                                .onChanged { v in
                                    let lower = i > 0 ? ranges[i - 1].end : 0
                                    let upper = ranges[i].end - ClipStorage.minClipLength
                                    let t = min(max(time(for: v.location.x, width: width), lower), upper)
                                    ranges[i].start = t
                                    onScrub(t)
                                }
                                .onEnded { _ in onCommit() }
                        )

                    handle(systemImage: "chevron.compact.right")
                        .offset(x: max(0, xe - handleWidth))
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                                .onChanged { v in
                                    let lower = ranges[i].start + ClipStorage.minClipLength
                                    let upper = i < ranges.count - 1 ? ranges[i + 1].start : duration
                                    let t = min(max(time(for: v.location.x, width: width), lower), upper)
                                    ranges[i].end = t
                                    onScrub(t)
                                }
                                .onEnded { _ in onCommit() }
                        )
                }

                // 播放位置
                if let p = playhead, p >= 0, p <= duration {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: height + 8)
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                        .offset(x: x(for: p, width: width) - 1, y: -4)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "strip")
        }
        .task(id: url) { await loadFrames() }
    }

    /// 黃色區段以外的空隙（頭、中間、尾）
    private func gaps() -> [ClipRange] {
        var result: [ClipRange] = []
        var cursor: Double = 0
        for r in ranges {
            if r.start > cursor { result.append(ClipRange(start: cursor, end: r.start)) }
            cursor = max(cursor, r.end)
        }
        if cursor < duration { result.append(ClipRange(start: cursor, end: duration)) }
        return result
    }

    private func handle(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.yellow)
            .frame(width: handleWidth)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func x(for t: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(t / duration) * width
    }

    private func time(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(x / width) * duration
    }

    private func loadFrames() async {
        frames = []
        guard duration > 0 else { return }
        let asset = AVURLAsset(url: url)
        var loaded: [NSImage] = []
        for i in 0..<frameCount {
            let t = duration * (Double(i) + 0.5) / Double(frameCount)
            if let img = await ClipStorage.frame(of: asset, at: t, maxSize: 160) {
                loaded.append(img)
            }
        }
        frames = loaded
    }
}

// MARK: - 拖曳調整高度的把手（預覽畫面與下方清單之間）

/// 上下拖動調整上方區塊高度；雙擊回到預設。高度會記住。
// MARK: - 預覽高度：佔分頁區的比例，視窗變大變小時跟著縮放

private struct PreviewAreaHeightKey: EnvironmentKey {
    static let defaultValue: Double = 500
}

extension EnvironmentValues {
    /// 剪輯／字幕／輸出分頁內容可用的高度
    var previewAreaHeight: Double {
        get { self[PreviewAreaHeightKey.self] }
        set { self[PreviewAreaHeightKey.self] = newValue }
    }
}

enum PreviewSizing {
    static let minHeight: Double = 120
    static let fractionRange: ClosedRange<Double> = 0.2...0.85

    static func height(fraction: Double, area: Double) -> Double {
        max(minHeight, area * fraction)
    }

    /// 給 ResizeHandle 用：拖的是像素高度，存的是比例
    static func binding(fraction: Binding<Double>, area: Double) -> Binding<Double> {
        Binding(
            get: { height(fraction: fraction.wrappedValue, area: area) },
            set: { newHeight in
                let f = newHeight / max(area, 1)
                fraction.wrappedValue = min(max(f, fractionRange.lowerBound), fractionRange.upperBound)
            }
        )
    }
}

struct ResizeHandle: View {
    @Binding var height: Double
    var defaultHeight: Double
    var minHeight: Double = 100

    @State private var dragStart: Double?
    @State private var hovering = false

    /// 上限：螢幕可用高度的 6 成，避免把視窗撐出螢幕
    private var maxHeight: Double {
        Double((NSScreen.main?.visibleFrame.height ?? 900) * 0.6)
    }

    var body: some View {
        ZStack {
            Color.clear.frame(height: 12)
            Capsule()
                .fill(hovering || dragStart != nil ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 44, height: 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if dragStart == nil { dragStart = height }
                    let proposed = (dragStart ?? height) + Double(v.translation.height)
                    height = min(max(proposed, minHeight), maxHeight)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.2)) { height = defaultHeight }
        }
        .help("上下拖動調整高度，雙擊回到預設")
    }
}

// MARK: - AVPlayerView 包裝

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

func cmTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

// MARK: - 播放速度選項

enum SpeedOption {
    static let all: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    static func label(_ v: Double) -> String {
        let text = v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
        return text + "×"
    }
}
