import SwiftUI
import AVKit

/// Wraps AVPlayerViewController (native tvOS transport bar, Siri remote scrubbing, subtitles, audio tracks).
struct AVPlayerView: UIViewControllerRepresentable {
    let request: PlaybackRequest
    let epg: EPGData
    let onError: (String) -> Void
    let onZap: (Int) -> Void
    let onJump: (Int) -> Void
    let onProgress: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        context.coordinator.attach(to: vc)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: AVPlayerView
        private let player = AVPlayer()
        private var timeObserver: Any?
        private var statusObservation: NSKeyValueObservation?
        private var didResume = false

        init(_ parent: AVPlayerView) { self.parent = parent }

        func attach(to vc: AVPlayerViewController) {
            let request = parent.request
            let item = AVPlayerItem(url: request.url)
            item.externalMetadata = metadata(for: request)
            if request.kind == .live {
                item.preferredForwardBufferDuration = 4
                player.automaticallyWaitsToMinimizeStalling = true
            }
            player.replaceCurrentItem(with: item)
            vc.player = player
            vc.allowsPictureInPicturePlayback = true

            if request.kind == .live {
                vc.requiresLinearPlayback = false
                vc.transportBarCustomMenuItems = [
                    UIAction(title: "Previous Channel", image: UIImage(systemName: "chevron.down")) { [weak self] _ in
                        self?.parent.onZap(-1)
                    },
                    UIAction(title: "Next Channel", image: UIImage(systemName: "chevron.up")) { [weak self] _ in
                        self?.parent.onZap(1)
                    },
                ]
                vc.customInfoViewControllers = infoPanels(for: request)
            }

            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.statusChanged(item) }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1),
                                                          queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportProgress() }
            }
            player.play()
        }

        private func statusChanged(_ item: AVPlayerItem) {
            switch item.status {
            case .readyToPlay:
                if !didResume, let resume = parent.request.resumeFrom, resume > 30 {
                    didResume = true
                    player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
            case .failed:
                let msg = item.error?.localizedDescription ?? "Playback failed."
                parent.onError(msg + "\n\nThis format may not be supported by the Apple player. Try enabling HLS in Settings, or add the VLC engine (see README).")
            default: break
            }
        }

        private func reportProgress() {
            guard parent.request.kind != .live, let item = player.currentItem else { return }
            let pos = item.currentTime().seconds
            let dur = item.duration.seconds
            if pos.isFinite, dur.isFinite, dur > 0 { parent.onProgress(pos, dur) }
        }

        func teardown() {
            reportProgress()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
            statusObservation = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
        }

        private func metadata(for request: PlaybackRequest) -> [AVMetadataItem] {
            func item(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
                guard let value, !value.isEmpty else { return nil }
                let m = AVMutableMetadataItem()
                m.identifier = id
                m.value = value as NSString
                m.extendedLanguageTag = "und"
                return m.copy() as? AVMetadataItem
            }
            return [
                item(.commonIdentifierTitle, request.title),
                item(.iTunesMetadataTrackSubTitle, request.subtitle),
            ].compactMap { $0 }
        }

        private func infoPanels(for request: PlaybackRequest) -> [UIViewController] {
            var panels: [UIViewController] = []
            if let channel = request.channels[safe: request.channelIndex] {
                let upNext = UIHostingController(rootView: UpNextPanel(programmes: parent.epg.upcoming(for: channel)))
                upNext.title = "Guide"
                upNext.preferredContentSize = CGSize(width: 1700, height: 320)
                panels.append(upNext)
            }
            if request.channels.count > 1 {
                let list = UIHostingController(rootView: ChannelPanel(
                    channels: request.channels, current: request.channelIndex, epg: parent.epg,
                    onSelect: { [weak self] index in self?.parent.onJump(index) }))
                list.title = "Channels"
                list.preferredContentSize = CGSize(width: 1700, height: 420)
                panels.append(list)
            }
            return panels
        }
    }
}

/// Info panel (swipe down while playing): what's on now and next.
struct UpNextPanel: View {
    let programmes: [Programme]
    var body: some View {
        if programmes.isEmpty {
            Text("No guide data for this channel.").foregroundStyle(.secondary).padding(40)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 30) {
                    ForEach(programmes) { p in
                        Button {} label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(p.isAiring() ? "NOW" : p.start.formatted(date: .omitted, time: .shortened))
                                    .font(.caption.bold()).foregroundStyle(p.isAiring() ? .red : .secondary)
                                Text(p.title).font(.headline).lineLimit(1)
                                Text(p.desc ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            .frame(width: 480, height: 200, alignment: .topLeading)
                            .padding(20)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 40).padding(.vertical, 20)
            }
        }
    }
}

/// Info panel: zap to any channel in the current list without leaving the player.
struct ChannelPanel: View {
    let channels: [Channel]
    let current: Int
    let epg: EPGData
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 24) {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { index, ch in
                        Button { onSelect(index) } label: {
                            VStack(spacing: 10) {
                                ChannelLogo(url: ch.logoURL, name: ch.name).frame(width: 220, height: 130)
                                Text(ch.name).font(.caption).lineLimit(1)
                                Text(epg.current(for: ch)?.title ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 260)
                            .padding(12)
                        }
                        .buttonStyle(.card)
                        .id(index)
                    }
                }
                .padding(.horizontal, 40).padding(.vertical, 20)
            }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
