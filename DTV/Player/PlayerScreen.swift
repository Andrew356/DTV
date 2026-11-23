import SwiftUI

/// Full-screen player. Picks AVPlayer (HLS / MP4) or VLC (MKV, raw TS, …) when VLC is linked.
struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var request: PlaybackRequest
    @State private var errorMessage: String?
    @State private var forceVLC = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let errorMessage {
                VStack(spacing: 30) {
                    Image(systemName: "exclamationmark.tv").font(.system(size: 90))
                    Text("Can't play “\(request.title)”").font(.title2.bold())
                    Text(errorMessage).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 1200)
                    HStack(spacing: 40) {
                        if request.kind == .live && request.channels.count > 1 {
                            Button("Previous Channel") { zap(-1) }
                            Button("Next Channel") { zap(1) }
                        }
                        Button("Close") { dismiss() }
                    }
                }
            } else if PlayerEngineChooser.useVLC(for: request.url, settings: model.sync.settings) || forceVLC {
                VLCPlayerView(request: request, onError: handleError, onZap: zap,
                              onProgress: { model.saveProgress(for: request, position: $0, duration: $1) })
                    .id(request.id)
                    .ignoresSafeArea()
            } else {
                AVPlayerView(request: request, epg: model.epg, onError: handleError, onZap: zap, onJump: jump,
                             onProgress: { model.saveProgress(for: request, position: $0, duration: $1) })
                    .id(request.id)
                    .ignoresSafeArea()
            }
        }
    }

    private func handleError(_ message: String) {
        if PlayerEngineChooser.vlcAvailable && !forceVLC && model.sync.settings.playerEngine == .automatic {
            forceVLC = true   // AVPlayer couldn't handle it – retry with VLC.
        } else {
            errorMessage = message
        }
    }

    private func zap(_ delta: Int) {
        guard request.kind == .live, !request.channels.isEmpty else { return }
        let count = request.channels.count
        jump((request.channelIndex + delta + count) % count)
    }

    private func jump(_ index: Int) {
        guard request.channels.indices.contains(index) else { return }
        let ch = request.channels[index]
        let next = PlaybackRequest(kind: .live, itemID: ch.id, title: ch.name,
                               subtitle: model.epg.current(for: ch)?.title, url: ch.streamURL,
                               imageURL: ch.logoURL, channels: request.channels, channelIndex: index)
        errorMessage = nil
        forceVLC = false
        request = next
    }
}

enum PlayerEngineChooser {
    static let vlcExtensions: Set<String> = ["mkv", "avi", "ts", "flv", "wmv", "mpg", "mpeg", "webm", "divx", "xvid"]

    static var vlcAvailable: Bool {
        #if canImport(TVVLCKit)
        return true
        #else
        return false
        #endif
    }

    static func useVLC(for url: URL, settings: AppSettings) -> Bool {
        guard vlcAvailable else { return false }
        switch settings.playerEngine {
        case .vlc: return true
        case .avPlayer: return false
        case .automatic: return vlcExtensions.contains(url.pathExtension.lowercased())
        }
    }
}
