import Foundation
import Observation

struct PlaybackRequest: Identifiable {
    let id = UUID()
    var kind: MediaKind
    var itemID: String
    var parentID: String?
    var title: String
    var subtitle: String?
    var url: URL
    var imageURL: URL?
    var resumeFrom: Double?
    /// For live TV: the channel list the user can zap through, and the current index.
    var channels: [Channel] = []
    var channelIndex: Int = 0
}

enum LoadState: Equatable {
    case idle
    case loading(String)
    case failed(String)
    case loaded
}

@MainActor
@Observable
final class AppModel {
    let sync = SyncStore()

    var catalog: Catalog?
    var epg = EPGData()
    var loadState: LoadState = .idle
    var epgLoading = false
    var nowPlaying: PlaybackRequest?

    var activeSourceID: UUID? {
        didSet { UserDefaults.standard.set(activeSourceID?.uuidString, forKey: "dtv.activeSource") }
    }

    var activeSource: Source? {
        sync.sources.first { $0.id == activeSourceID } ?? sync.sources.first
    }

    @ObservationIgnored private var episodeCache: [String: [Episode]] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadingSourceID: UUID?

    init() {
        activeSourceID = UserDefaults.standard.string(forKey: "dtv.activeSource").flatMap(UUID.init(uuidString:))
    }

    // MARK: Loading

    /// Called on launch and whenever the synced source list changes.
    func ensureLoaded() {
        guard let source = activeSource else { catalog = nil; loadState = .idle; return }
        if catalog?.sourceID == source.id || loadingSourceID == source.id { return }
        load(source: source, force: false)
    }

    func select(_ source: Source) {
        activeSourceID = source.id
        load(source: source, force: false)
    }

    func refresh() {
        guard let source = activeSource else { return }
        load(source: source, force: true)
    }

    private func load(source: Source, force: Bool) {
        loadTask?.cancel()
        episodeCache = [:]
        if !force, let cached = CatalogCache.loadCatalog(source.id) {
            catalog = cached
            epg = CatalogCache.loadEPG(source.id) ?? EPGData()
            loadState = .loaded
            // Refresh stale catalogs (older than 12h) silently in the background.
            if Date().timeIntervalSince(cached.loadedAt) < 12 * 3600 {
                refreshEPGIfNeeded(source: source)
                return
            }
        } else {
            if catalog?.sourceID != source.id { catalog = nil; epg = EPGData() }
            loadState = .loading("Connecting to \(source.name)…")
        }

        let settings = sync.settings
        loadingSourceID = source.id
        loadTask = Task { [weak self] in
            defer { if self?.loadingSourceID == source.id { self?.loadingSourceID = nil } }
            do {
                let catalog = try await Self.fetchCatalog(source: source, settings: settings) { message in
                    Task { @MainActor in
                        if case .loading = self?.loadState { self?.loadState = .loading(message) }
                    }
                }
                try Task.checkCancellation()
                guard let self else { return }
                self.catalog = catalog
                self.loadState = .loaded
                CatalogCache.saveCatalog(catalog)
                self.refreshEPGIfNeeded(source: source, force: force)
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                if self.catalog == nil { self.loadState = .failed(error.localizedDescription) }
            }
        }
    }

    nonisolated static func fetchCatalog(source: Source, settings: AppSettings,
                                         progress: @escaping @Sendable (String) -> Void) async throws -> Catalog {
        switch source.kind {
        case .xtream:
            let client = try xtreamClient(for: source)
            return try await client.loadCatalog(sourceID: source.id, settings: settings, progress: progress)
        case .m3u:
            guard let raw = source.m3uURL, let url = URL(string: raw.trimmingCharacters(in: .whitespaces)) else {
                throw URLError(.badURL)
            }
            progress("Downloading playlist…")
            var req = URLRequest(url: url, timeoutInterval: 120)
            req.setValue("DTV/1.0 (tvOS)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw XtreamError.badResponse(http.statusCode)
            }
            progress("Parsing playlist…")
            let text = String(decoding: data, as: UTF8.self)
            let playlist = M3UParser.parse(text)
            guard !playlist.entries.isEmpty else {
                throw NSError(domain: "DTV", code: 1, userInfo: [NSLocalizedDescriptionKey: "The playlist is empty or isn't a valid M3U file."])
            }
            return CatalogBuilder.build(from: playlist, sourceID: source.id, settings: settings)
        }
    }

    nonisolated static func xtreamClient(for source: Source) throws -> XtreamClient {
        guard let password = Keychain.get(account: source.keychainAccount) else {
            throw NSError(domain: "DTV", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "No password saved on this Apple TV for “\(source.name)”. Edit the source in Settings and re-enter it."])
        }
        return try XtreamClient(server: source.serverURL ?? "", username: source.username ?? "", password: password)
    }

    func refreshEPGIfNeeded(source: Source? = nil, force: Bool = false) {
        guard let source = source ?? activeSource, !epgLoading else { return }
        if !force, Date().timeIntervalSince(epg.loadedAt) < 6 * 3600 { return }
        let override = source.epgURL.nonEmpty.flatMap(URL.init(string:))
        guard let url = override ?? catalog?.epgURL else { return }
        let hours = sync.settings.epgHours
        epgLoading = true
        Task { [weak self] in
            let data = try? await EPGLoader.load(from: url, hours: hours)
            guard let self else { return }
            self.epgLoading = false
            guard let data, self.activeSource?.id == source.id else { return }
            self.epg = data
            CatalogCache.saveEPG(data, for: source.id)
        }
    }

    // MARK: Series

    func episodes(for series: Series) async throws -> [Episode] {
        if let cached = episodeCache[series.id] { return cached }
        guard let source = activeSource else { return [] }
        let eps: [Episode]
        switch source.kind {
        case .m3u: eps = catalog?.m3uEpisodes[series.id] ?? []
        case .xtream: eps = try await Self.xtreamClient(for: source).episodes(for: series)
        }
        episodeCache[series.id] = eps
        return eps
    }

    // MARK: Favorites

    func isFavorite(_ kind: MediaKind, _ id: String) -> Bool {
        guard let sid = activeSource?.id else { return false }
        return sync.isFavorite(sourceID: sid, kind: kind, itemID: id)
    }

    func toggleFavorite(kind: MediaKind, id: String, name: String, image: URL?) {
        guard let sid = activeSource?.id else { return }
        sync.toggleFavorite(FavoriteRef(sourceID: sid, kind: kind, itemID: id, name: name, imageURL: image?.absoluteString))
    }

    var favoriteChannels: [Channel] {
        guard let catalog else { return [] }
        let ids = Set(sync.favorites.filter { $0.sourceID == catalog.sourceID && $0.kind == .live }.map(\.itemID))
        return catalog.live.filter { ids.contains($0.id) }
    }
    var favoriteMovies: [Movie] {
        guard let catalog else { return [] }
        let ids = Set(sync.favorites.filter { $0.sourceID == catalog.sourceID && $0.kind == .movie }.map(\.itemID))
        return catalog.movies.filter { ids.contains($0.id) }
    }
    var favoriteSeries: [Series] {
        guard let catalog else { return [] }
        let ids = Set(sync.favorites.filter { $0.sourceID == catalog.sourceID && $0.kind == .series }.map(\.itemID))
        return catalog.series.filter { ids.contains($0.id) }
    }

    // MARK: Progress

    var continueWatching: [PlaybackProgress] {
        guard let sid = activeSource?.id else { return [] }
        return sync.progress.values
            .filter { $0.sourceID == sid && !$0.isFinished && $0.position > 30 }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func progress(for itemID: String) -> PlaybackProgress? {
        guard let sid = activeSource?.id else { return nil }
        return sync.progress[PlaybackProgress.key(sourceID: sid, itemID: itemID)]
    }

    func saveProgress(for request: PlaybackRequest, position: Double, duration: Double) {
        guard let sid = activeSource?.id, request.kind != .live, duration.isFinite, duration > 0 else { return }
        sync.updateProgress(PlaybackProgress(sourceID: sid, kind: request.kind, itemID: request.itemID,
                                             parentID: request.parentID, name: request.title,
                                             imageURL: request.imageURL?.absoluteString,
                                             position: position, duration: duration))
    }

    // MARK: Playback

    func play(channel: Channel, in list: [Channel]) {
        let index = list.firstIndex(of: channel) ?? 0
        nowPlaying = PlaybackRequest(kind: .live, itemID: channel.id, title: channel.name,
                                     subtitle: epg.current(for: channel)?.title,
                                     url: channel.streamURL, imageURL: channel.logoURL,
                                     channels: list.isEmpty ? [channel] : list, channelIndex: index)
    }

    func play(movie: Movie, resume: Bool = true) {
        let saved = progress(for: movie.id)
        nowPlaying = PlaybackRequest(kind: .movie, itemID: movie.id, title: movie.name, subtitle: movie.plot,
                                     url: movie.streamURL, imageURL: movie.posterURL,
                                     resumeFrom: resume && saved?.isFinished == false ? saved?.position : nil)
    }

    func play(episode: Episode, of series: Series, resume: Bool = true) {
        let saved = progress(for: episode.id)
        nowPlaying = PlaybackRequest(kind: .episode, itemID: episode.id, parentID: series.id,
                                     title: "\(series.name) – S\(episode.season)E\(episode.number)",
                                     subtitle: episode.title, url: episode.streamURL,
                                     imageURL: episode.imageURL ?? series.coverURL,
                                     resumeFrom: resume && saved?.isFinished == false ? saved?.position : nil)
    }

    /// Resume an item from the "Continue watching" row.
    func resume(_ entry: PlaybackProgress) async {
        guard let catalog else { return }
        switch entry.kind {
        case .movie:
            if let m = catalog.movie(id: entry.itemID) { play(movie: m) }
        case .episode:
            guard let sid = entry.parentID, let s = catalog.seriesItem(id: sid),
                  let eps = try? await episodes(for: s), let ep = eps.first(where: { $0.id == entry.itemID }) else { return }
            play(episode: ep, of: s)
        default: break
        }
    }

    // MARK: Sources

    func save(source: Source, password: String?) {
        if let password, source.kind == .xtream { Keychain.set(password, account: source.keychainAccount) }
        let isNew = !sync.sources.contains { $0.id == source.id }
        sync.upsert(source)
        if isNew {
            select(source)
        } else if source.id == activeSource?.id {
            load(source: source, force: true)
        }
    }

    func delete(source: Source) {
        let wasActive = source.id == activeSource?.id
        sync.remove(source)
        if wasActive {
            activeSourceID = sync.sources.first?.id
            catalog = nil
            ensureLoaded()
        }
    }
}
