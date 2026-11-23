import Foundation

// MARK: - Sources

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case m3u
    case xtream

    var id: String { rawValue }
    var label: String {
        switch self {
        case .m3u: return "M3U Playlist"
        case .xtream: return "Xtream Codes"
        }
    }
}

/// A playlist provider. Synced through iCloud Key-Value storage.
/// Xtream passwords are NOT stored here – they live in the (iCloud) Keychain.
struct Source: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: SourceKind
    /// M3U: playlist URL.
    var m3uURL: String?
    /// Xtream: server base URL, e.g. http://host:8080
    var serverURL: String?
    /// Xtream: username.
    var username: String?
    /// Optional XMLTV EPG override (otherwise taken from playlist / Xtream server).
    var epgURL: String?
    var updatedAt: Date = Date()

    var keychainAccount: String { "source-\(id.uuidString)" }
}

// MARK: - Catalog

enum MediaKind: String, Codable, Hashable {
    case live, movie, series, episode
}

struct Channel: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var number: Int?
    var group: String
    var logoURL: URL?
    var streamURL: URL
    var epgID: String?
    var hasArchive: Bool = false
}

struct Movie: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var group: String
    var posterURL: URL?
    var streamURL: URL
    var rating: String?
    var plot: String?
    var year: String?
}

struct Series: Identifiable, Hashable, Codable {
    var id: String
    /// Xtream series_id; nil for M3U-derived series.
    var remoteID: Int?
    var name: String
    var group: String
    var coverURL: URL?
    var plot: String?
    var rating: String?
    var genre: String?
    var releaseDate: String?
}

struct Episode: Identifiable, Hashable, Codable {
    var id: String
    var seriesID: String
    var title: String
    var season: Int
    var number: Int
    var streamURL: URL
    var imageURL: URL?
    var plot: String?
    var durationSeconds: Int?
}

struct Catalog: Codable {
    var sourceID: UUID
    var live: [Channel] = []
    var movies: [Movie] = []
    var series: [Series] = []
    var liveGroups: [String] = []
    var movieGroups: [String] = []
    var seriesGroups: [String] = []
    /// Episodes for M3U-derived series (keyed by Series.id). Xtream episodes are fetched on demand.
    var m3uEpisodes: [String: [Episode]] = [:]
    /// EPG URL discovered from the playlist header or Xtream server.
    var epgURL: URL?
    var loadedAt: Date = Date()

    func channel(id: String) -> Channel? { live.first { $0.id == id } }
    func movie(id: String) -> Movie? { movies.first { $0.id == id } }
    func seriesItem(id: String) -> Series? { series.first { $0.id == id } }
}

// MARK: - Synced user data

struct FavoriteRef: Codable, Hashable, Identifiable {
    var sourceID: UUID
    var kind: MediaKind
    var itemID: String
    var name: String
    var imageURL: String?
    var addedAt: Date = Date()

    var id: String { "\(sourceID.uuidString)|\(kind.rawValue)|\(itemID)" }
}

struct PlaybackProgress: Codable, Hashable, Identifiable {
    var sourceID: UUID
    var kind: MediaKind
    var itemID: String
    /// For episodes: the parent series id, so "Continue watching" can reopen the show.
    var parentID: String?
    var name: String
    var imageURL: String?
    var position: Double
    var duration: Double
    var updatedAt: Date = Date()

    var id: String { Self.key(sourceID: sourceID, itemID: itemID) }
    static func key(sourceID: UUID, itemID: String) -> String { "\(sourceID.uuidString)|\(itemID)" }

    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
    var isFinished: Bool { duration > 0 && position > duration - 90 }
}

enum PlayerEngine: String, Codable, CaseIterable, Identifiable {
    case automatic, avPlayer, vlc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .avPlayer: return "Apple (AVPlayer)"
        case .vlc: return "VLC"
        }
    }
}

struct AppSettings: Codable, Hashable {
    /// Rewrite Xtream-style `.ts` live URLs to `.m3u8` so AVPlayer can play them.
    var preferHLS: Bool = true
    var playerEngine: PlayerEngine = .automatic
    /// Hours of guide data to keep.
    var epgHours: Int = 24
    var showChannelNumbers: Bool = true
    var updatedAt: Date = Date()
}
