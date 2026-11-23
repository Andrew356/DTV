import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.sync.sources.isEmpty {
                WelcomeView()
            } else {
                TabView {
                    LiveTVView().tabItem { Label("Live TV", systemImage: "tv") }
                    MoviesView().tabItem { Label("Movies", systemImage: "film") }
                    SeriesListView().tabItem { Label("Series", systemImage: "play.square.stack") }
                    FavoritesView().tabItem { Label("Favorites", systemImage: "heart") }
                    SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
                    SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
                }
                .overlay { LoadingOverlay() }
            }
        }
        .fullScreenCover(item: $model.nowPlaying) { request in
            PlayerScreen(request: request)
        }
        .onAppear { model.ensureLoaded() }
        .onChange(of: model.sync.sources) { model.ensureLoaded() }
    }
}

private struct LoadingOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.loadState {
        case .loading(let message) where model.catalog == nil:
            VStack(spacing: 30) {
                ProgressView().scaleEffect(2)
                Text(message).font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.7))
        case .failed(let message):
            VStack(spacing: 30) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 80))
                Text("Couldn't load \(model.activeSource?.name ?? "playlist")").font(.title2.bold())
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 1200)
                Button("Try Again") { model.refresh() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.85))
        default:
            EmptyView()
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: "play.tv.fill").font(.system(size: 140)).foregroundStyle(.tint)
            Text("Welcome to DTV").font(.largeTitle.bold())
            Text("Add an M3U playlist or Xtream Codes login to get started.\nYour sources, favorites and watch progress sync through iCloud.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { adding = true } label: { Label("Add Source", systemImage: "plus") }
            if model.sync.iCloudAvailable {
                Text("Already set up DTV on another Apple TV? Your sources will appear here automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(100)
        .sheet(isPresented: $adding) { SourceEditorView(existing: nil) }
    }
}
