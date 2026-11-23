import SwiftUI

#if canImport(TVVLCKit)
import TVVLCKit

/// VLC-based player for formats AVPlayer can't handle (MKV, raw MPEG-TS, AVI, …).
/// Enabled only when the TVVLCKit package is linked (see project.yml / README).
struct VLCPlayerView: View {
    let request: PlaybackRequest
    let onError: (String) -> Void
    let onZap: (Int) -> Void
    let onProgress: (Double, Double) -> Void

    @StateObject private var controller = VLCController()
    @State private var showOverlay = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            VLCVideoSurface(controller: controller)
            if controller.isBuffering {
                ProgressView().scaleEffect(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showOverlay {
                overlay.transition(.opacity)
            }
        }
        .focusable()
        .onAppear {
            controller.onError = onError
            controller.start(url: request.url, resumeFrom: request.resumeFrom)
            pokeOverlay()
        }
        .onDisappear {
            if request.kind != .live, controller.duration > 0 { onProgress(controller.position, controller.duration) }
            controller.stop()
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            if request.kind != .live, controller.duration > 0 { onProgress(controller.position, controller.duration) }
        }
        .onPlayPauseCommand { controller.togglePause(); pokeOverlay() }
        .onMoveCommand { dir in
            switch dir {
            case .left: if request.kind != .live { controller.jump(-10) }
            case .right: if request.kind != .live { controller.jump(30) }
            case .up: if request.kind == .live { onZap(1) }
            case .down: if request.kind == .live { onZap(-1) }
            @unknown default: break
            }
            pokeOverlay()
        }
        .onTapGesture { controller.togglePause(); pokeOverlay() }
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.title2.bold())
            if let subtitle = request.subtitle { Text(subtitle).foregroundStyle(.secondary).lineLimit(2) }
            if request.kind != .live, controller.duration > 0 {
                ProgressView(value: controller.position, total: controller.duration)
                HStack {
                    Text(format(controller.position))
                    Spacer()
                    Text("-" + format(controller.duration - controller.position))
                }
                .font(.caption).monospacedDigit()
                Text("◀︎ 10s · ▶︎ 30s · Play/Pause").font(.caption2).foregroundStyle(.secondary)
            } else if request.kind == .live {
                Text("Swipe up/down to change channel").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
    }

    private func pokeOverlay() {
        withAnimation { showOverlay = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation { showOverlay = false }
        }
    }

    private func format(_ t: Double) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

@MainActor
final class VLCController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var isBuffering = true
    var onError: ((String) -> Void)?
    private var pendingResume: Double?

    override init() {
        super.init()
        player.delegate = self
    }

    func start(url: URL, resumeFrom: Double?) {
        let media = VLCMedia(url: url)
        media.addOptions(["network-caching": 1500])
        player.media = media
        pendingResume = resumeFrom
        player.play()
    }

    func stop() { player.stop() }
    func togglePause() { player.isPlaying ? player.pause() : player.play() }
    func jump(_ seconds: Int32) { seconds >= 0 ? player.jumpForward(seconds) : player.jumpBackward(-seconds) }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            switch self.player.state {
            case .buffering, .opening: self.isBuffering = true
            case .playing:
                self.isBuffering = false
                if let resume = self.pendingResume, resume > 30 {
                    self.pendingResume = nil
                    self.player.time = VLCTime(int: Int32(resume * 1000))
                }
            case .error: self.onError?("VLC couldn't open this stream.")
            default: self.isBuffering = false
            }
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in
            self.isBuffering = false
            self.position = Double(self.player.time.intValue) / 1000
            if let len = self.player.media?.length.intValue, len > 0 { self.duration = Double(len) / 1000 }
        }
    }
}

private struct VLCVideoSurface: UIViewRepresentable {
    let controller: VLCController
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        controller.player.drawable = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

#else

/// Placeholder used when TVVLCKit isn't linked. `PlayerEngineChooser` never selects it in that case.
struct VLCPlayerView: View {
    let request: PlaybackRequest
    let onError: (String) -> Void
    let onZap: (Int) -> Void
    let onProgress: (Double, Double) -> Void

    var body: some View {
        Color.black.onAppear {
            onError("The VLC engine isn't included in this build. See the README to enable it.")
        }
    }
}

#endif
