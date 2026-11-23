import Foundation
import Observation

/// User data that follows you across Apple TVs via iCloud Key-Value storage
/// (`NSUbiquitousKeyValueStore`). A local copy is kept in UserDefaults so the app
/// works offline or with iCloud disabled.
///
/// Synced: sources (without passwords), favorites, watch progress / continue watching, settings.
@MainActor
@Observable
final class SyncStore {
    private(set) var sources: [Source] = []
    private(set) var favorites: [FavoriteRef] = []
    private(set) var progress: [String: PlaybackProgress] = [:]
    private(set) var settings = AppSettings()
    private(set) var lastSync: Date?
    var iCloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    @ObservationIgnored private let cloud = NSUbiquitousKeyValueStore.default
    @ObservationIgnored private let local = UserDefaults.standard
    @ObservationIgnored private var observer: NSObjectProtocol?

    private enum Key: String, CaseIterable {
        case sources = "dtv.sources.v1"
        case favorites = "dtv.favorites.v1"
        case progress = "dtv.progress.v1"
        case settings = "dtv.settings.v1"
    }

    static let maxProgressEntries = 300

    init() {
        loadAll(preferCloud: true)
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self?.handleExternalChange(keys: keys) }
        }
        cloud.synchronize()
    }

    // MARK: Mutations

    func upsert(_ source: Source) {
        var s = source
        s.updatedAt = Date()
        if let i = sources.firstIndex(where: { $0.id == s.id }) { sources[i] = s } else { sources.append(s) }
        save(.sources, sources)
    }

    func remove(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        favorites.removeAll { $0.sourceID == source.id }
        progress = progress.filter { $0.value.sourceID != source.id }
        Keychain.delete(account: source.keychainAccount)
        save(.sources, sources)
        save(.favorites, favorites)
        save(.progress, progress)
    }

    func isFavorite(sourceID: UUID, kind: MediaKind, itemID: String) -> Bool {
        favorites.contains { $0.sourceID == sourceID && $0.kind == kind && $0.itemID == itemID }
    }

    func toggleFavorite(_ ref: FavoriteRef) {
        if let i = favorites.firstIndex(where: { $0.id == ref.id }) { favorites.remove(at: i) }
        else { favorites.append(ref) }
        save(.favorites, favorites)
    }

    func updateProgress(_ entry: PlaybackProgress) {
        var e = entry
        e.updatedAt = Date()
        progress[e.id] = e
        if progress.count > Self.maxProgressEntries {
            let keep = progress.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maxProgressEntries)
            progress = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }
        save(.progress, progress)
    }

    func clearProgress(id: String) {
        progress[id] = nil
        save(.progress, progress)
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        settings.updatedAt = Date()
        save(.settings, settings)
    }

    func syncNow() {
        cloud.synchronize()
        loadAll(preferCloud: true)
    }

    // MARK: Persistence

    private func save<T: Encodable>(_ key: Key, _ value: T) {
        guard let data = try? JSONEncoder.dtv.encode(value) else { return }
        local.set(data, forKey: key.rawValue)
        cloud.set(data, forKey: key.rawValue)
        lastSync = Date()
    }

    private func read<T: Decodable>(_ key: Key, preferCloud: Bool) -> T? {
        let cloudData = cloud.data(forKey: key.rawValue)
        let localData = local.data(forKey: key.rawValue)
        let data = preferCloud ? (cloudData ?? localData) : (localData ?? cloudData)
        guard let data else { return nil }
        return try? JSONDecoder.dtv.decode(T.self, from: data)
    }

    private func loadAll(preferCloud: Bool) {
        let cloudSources: [Source]? = cloud.data(forKey: Key.sources.rawValue)
            .flatMap { try? JSONDecoder.dtv.decode([Source].self, from: $0) }
        let localSources: [Source]? = local.data(forKey: Key.sources.rawValue)
            .flatMap { try? JSONDecoder.dtv.decode([Source].self, from: $0) }
        // First launch on a device that already had local data but iCloud is empty → seed iCloud.
        if cloudSources == nil, let localSources, !localSources.isEmpty {
            sources = localSources
            pushAllToCloud()
            return
        }
        sources = (preferCloud ? cloudSources : localSources) ?? localSources ?? []
        favorites = read(.favorites, preferCloud: preferCloud) ?? []
        progress = read(.progress, preferCloud: preferCloud) ?? [:]
        settings = read(.settings, preferCloud: preferCloud) ?? AppSettings()
        mirrorToLocal()
    }

    private func pushAllToCloud() {
        favorites = read(.favorites, preferCloud: false) ?? []
        progress = read(.progress, preferCloud: false) ?? [:]
        settings = read(.settings, preferCloud: false) ?? AppSettings()
        save(.sources, sources)
        save(.favorites, favorites)
        save(.progress, progress)
        save(.settings, settings)
    }

    private func mirrorToLocal() {
        for key in Key.allCases {
            if let data = cloud.data(forKey: key.rawValue) { local.set(data, forKey: key.rawValue) }
        }
    }

    private func handleExternalChange(keys: [String]?) {
        let changed = Set(keys ?? Key.allCases.map(\.rawValue))
        if changed.contains(Key.sources.rawValue) { sources = read(.sources, preferCloud: true) ?? sources }
        if changed.contains(Key.favorites.rawValue) { favorites = read(.favorites, preferCloud: true) ?? favorites }
        if changed.contains(Key.progress.rawValue) {
            // Merge progress per item: newest update wins, so two TVs watching different things don't clobber each other.
            let remote: [String: PlaybackProgress] = read(.progress, preferCloud: true) ?? [:]
            var merged = progress
            for (k, v) in remote where (merged[k]?.updatedAt ?? .distantPast) < v.updatedAt { merged[k] = v }
            progress = merged
        }
        if changed.contains(Key.settings.rawValue) { settings = read(.settings, preferCloud: true) ?? settings }
        mirrorToLocal()
        lastSync = Date()
    }
}

extension JSONEncoder {
    static let dtv: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}

extension JSONDecoder {
    static let dtv: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
