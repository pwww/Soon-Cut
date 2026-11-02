import SwiftUI
import AVKit

// MARK: - 單一片段：預覽＋膠卷條剪頭尾

struct ClipEditor: View {
    @EnvironmentObject var store: AppStore
    let clip: Clip
    let isRecording: Bool

    @State private var player = AVPlayer()
    @State private var draftStart: Double = 0
    @State private var draftEnd: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlayerView(player: player)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 140, maxHeight: .infinity)

            FilmstripTrimmer(
                url: clip.url,
                duration: clip.duration,
                start: $draftStart,
                end: $draftEnd,
                onScrub: { t in
                    player.pause()
                    player.seek(to: cmTime(t), toleranceBefore: .zero, toleranceAfter: .zero)
                },
                onCommit: {
                    store.setTrim(clipID: clip.id, start: draftStart, end: draftEnd)
                    applyTrimToPlayer(seekToStart: true)
                }
            )
            .frame(height: 48)
            .padding(.horizontal, 6)   // 把手離視窗縮放邊框遠一點

            HStack {
                Text("\(formatTime(draftStart)) – \(formatTime(draftEnd))　長度 \(formatTime(draftEnd - draftStart))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if draftStart > 0.01 || draftEnd < clip.duration - 0.01 {
                    Button("還原") {
                        draftStart = 0
                        draftEnd = clip.duration
                        store.setTrim(clipID: clip.id, start: 0, end: clip.duration)
                        applyTrimToPlayer(seekToStart: true)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: clip.url) { reload() }
        .onChange(of: isRecording) {
            if isRecording { player.pause() }
        }
        .onDisappear { player.pause() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            // 播到剪輯終點後回到起點，下次按播放從頭開始
            if let item = note.object as? AVPlayerItem, item === player.currentItem {
                player.seek(to: cmTime(draftStart), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func reload() {
        draftStart = clip.trimStart
        draftEnd = clip.trimEnd > 0 ? clip.trimEnd : clip.duration
        player.replaceCurrentItem(with: AVPlayerItem(url: clip.url))
        applyTrimToPlayer(seekToStart: true)
    }

    private func applyTrimToPlayer(seekToStart: Bool) {
        player.currentItem?.forwardPlaybackEndTime = cmTime(draftEnd)
        if seekToStart {
            player.seek(to: cmTime(draftStart), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
}

// MARK: - 膠卷條（iPhone 相簿式剪頭尾）

struct FilmstripTrimmer: View {
    let url: URL
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    var onScrub: (Double) -> Void
    var onCommit: () -> Void

    @State private var frames: [NSImage] = []
    private let frameCount = 10
    private let handleWidth: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let xs = x(for: start, width: width)
            let xe = x(for: end, width: width)

            ZStack(alignment: .topLeading) {
                // 影格
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
                    // 在影格上拖動 = 預覽定位（限制在保留範圍內），不改剪輯點
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { v in
                            let t = time(for: v.location.x, width: width)
                            onScrub(min(max(t, start), end))
                        }
                )

                // 被剪掉的部分變暗
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: max(0, xs), height: height)
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: max(0, width - xe), height: height)
                    .offset(x: xe)

                // 保留範圍的黃框
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(handleWidth * 2, xe - xs), height: height)
                    .offset(x: xs)
                    .allowsHitTesting(false)

                // 左把手
                handle(systemImage: "chevron.compact.left")
                    .offset(x: xs)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                            .onChanged { v in
                                let t = time(for: v.location.x, width: width)
                                start = min(max(0, t), end - ClipStorage.minClipLength)
                                onScrub(start)
                            }
                            .onEnded { _ in onCommit() }
                    )

                // 右把手
                handle(systemImage: "chevron.compact.right")
                    .offset(x: max(0, xe - handleWidth))
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                            .onChanged { v in
                                let t = time(for: v.location.x, width: width)
                                end = max(min(duration, t), start + ClipStorage.minClipLength)
                                onScrub(end)
                            }
                            .onEnded { _ in onCommit() }
                    )
            }
            .coordinateSpace(name: "strip")
        }
        .task(id: url) { await loadFrames() }
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
