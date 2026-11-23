import Foundation

// MARK: - Tolerant JSON helpers
// Xtream panels are notoriously inconsistent: ids come back as strings or ints,
// objects are sometimes empty arrays, etc. Everything is decoded leniently.

struct FlexString: Decodable, Hashable {
    let value: String?
    init(_ value: String?) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = nil }
        else if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else if let b = try? c.decode(Bool.self) { value = b ? "1" : "0" }
        else { value = nil }
    }
    var string: String? { value.nonEmpty }
    var int: Int? { value.flatMap { Int($0) ?? Double($0).map { Int($0) } } }
}

struct XtreamUserInfo: Decodable {
    var username: FlexString?
    var auth: FlexString?
    var status: FlexString?
    var expDate: FlexString?
    var maxConnections: FlexString?
    var activeCons: FlexString?
    var allowedOutputFormats: [String]?

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        username = try? c.decodeIfPresent(FlexString.self, forKey: .username)
        auth = try? c.decodeIfPresent(FlexString.self, forKey: .auth)
        status = try? c.decodeIfPresent(FlexString.self, forKey: .status)
        expDate = try? c.decodeIfPresent(FlexString.self, forKey: .expDate)
        maxConnections = try? c.decodeIfPresent(FlexString.self, forKey: .maxConnections)
        activeCons = try? c.decodeIfPresent(FlexString.self, forKey: .activeCons)
        allowedOutputFormats = try? c.decodeIfPresent([String].self, forKey: .allowedOutputFormats)
    }
    enum CodingKeys: String, CodingKey { case username, auth, status, expDate, maxConnections, activeCons, allowedOutputFormats }

    var expiry: Date? { expDate?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

struct XtreamAccount: Decodable {
    var userInfo: XtreamUserInfo?
}

struct XCategory: Decodable {
    var categoryId: FlexString?
    var categoryName: FlexString?
}

struct XLiveStream: Decodable {
    var num: FlexString?
    var name: FlexString?
    var streamId: FlexString?
    var streamIcon: FlexString?
    var epgChannelId: FlexString?
    var categoryId: FlexString?
    var tvArchive: FlexString?
}

struct XVodStream: Decodable {
    var name: FlexString?
    var streamId: FlexString?
    var streamIcon: FlexString?
    var categoryId: FlexString?
    var containerExtension: FlexString?
    var rating: FlexString?
    var plot: FlexString?
    var year: FlexString?
}

struct XSeries: Decodable {
    var seriesId: FlexString?
    var name: FlexString?
    var cover: FlexString?
    var plot: FlexString?
    var categoryId: FlexString?
    var rating: FlexString?
    var genre: FlexString?
    var releaseDate: FlexString?
}

struct XEpisodeInfo: Decodable {
    var movieImage: FlexString?
    var plot: FlexString?
    var durationSecs: FlexString?

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        movieImage = try? c.decodeIfPresent(FlexString.self, forKey: .movieImage)
        plot = try? c.decodeIfPresent(FlexString.self, forKey: .plot)
        durationSecs = try? c.decodeIfPresent(FlexString.self, forKey: .durationSecs)
    }
    enum CodingKeys: String, CodingKey { case movieImage, plot, durationSecs }
}

struct XEpisode: Decodable {
    var id: FlexString?
    var episodeNum: FlexString?
    var title: FlexString?
    var containerExtension: FlexString?
    var season: FlexString?
    var info: XEpisodeInfo?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(FlexString.self, forKey: .id)
        episodeNum = try? c.decodeIfPresent(FlexString.self, forKey: .episodeNum)
        title = try? c.decodeIfPresent(FlexString.self, forKey: .title)
        containerExtension = try? c.decodeIfPresent(FlexString.self, forKey: .containerExtension)
        season = try? c.decodeIfPresent(FlexString.self, forKey: .season)
        info = try? c.decodeIfPresent(XEpisodeInfo.self, forKey: .info)
    }
    enum CodingKeys: String, CodingKey { case id, episodeNum, title, containerExtension, season, info }
}

struct XSeriesInfo: Decodable {
    var episodes: [XEpisode] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let dict = try? c.decode([String: [XEpisode]].self, forKey: .episodes) {
            // Keys are season numbers; fill missing season fields from the key.
            for (seasonKey, eps) in dict {
                for var ep in eps {
                    if ep.season?.int == nil { ep.season = FlexString(seasonKey) }
                    episodes.append(ep)
                }
            }
        } else if let nested = try? c.decode([[XEpisode]].self, forKey: .episodes) {
            episodes = nested.flatMap { $0 }
        } else if let flat = try? c.decode([XEpisode].self, forKey: .episodes) {
            episodes = flat
        }
    }
    enum CodingKeys: String, CodingKey { case episodes }
}

// MARK: - Client

enum XtreamError: LocalizedError {
    case invalidServer
    case authenticationFailed(String?)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "The server address isn't valid."
        case .authenticationFailed(let status):
            return "Login failed" + (status.map { " (\($0))" } ?? "") + ". Check your username and password."
        case .badResponse(let code): return "The server responded with HTTP \(code)."
        }
    }
}

struct XtreamClient {
    let server: URL
    let username: String
    let password: String
    var session: URLSession = .shared

    init(server: String, username: String, password: String) throws {
        guard let url = Self.normalizeServer(server) else { throw XtreamError.invalidServer }
        self.server = url
        self.username = username
        self.password = password
    }

    /// Accepts "host:port", "http://host:port/", ".../player_api.php", ".../get.php?..."
    static func normalizeServer(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        guard var comps = URLComponents(string: s), comps.host != nil else { return nil }
        comps.query = nil
        comps.fragment = nil
        var path = comps.path
        for suffix in ["/player_api.php", "/get.php", "/xmltv.php", "/panel_api.php"] where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
        }
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path
        return comps.url
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private func apiURL(_ action: String?, extra: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: server.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        comps.queryItems = items + extra
        return comps.url!
    }

    private func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("DTV/1.0 (tvOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XtreamError.badResponse(http.statusCode)
        }
        return data
    }

    private func list<T: Decodable>(_ action: String, as type: T.Type) async throws -> [T] {
        let data = try await fetch(apiURL(action))
        return (try? decoder.decode([T].self, from: data)) ?? []
    }

    func authenticate() async throws -> XtreamUserInfo {
        let data = try await fetch(apiURL(nil))
        guard let account = try? decoder.decode(XtreamAccount.self, from: data),
              let info = account.userInfo, info.auth?.int == 1 else {
            let status = (try? decoder.decode(XtreamAccount.self, from: data))?.userInfo?.status?.string
            throw XtreamError.authenticationFailed(status)
        }
        return info
    }

    // MARK: Stream URLs

    func liveURL(streamID: String, format: String) -> URL {
        server.appendingPathComponent("live").appendingPathComponent(username)
            .appendingPathComponent(password).appendingPathComponent("\(streamID).\(format)")
    }
    func movieURL(streamID: String, ext: String) -> URL {
        server.appendingPathComponent("movie").appendingPathComponent(username)
            .appendingPathComponent(password).appendingPathComponent("\(streamID).\(ext)")
    }
    func episodeURL(episodeID: String, ext: String) -> URL {
        server.appendingPathComponent("series").appendingPathComponent(username)
            .appendingPathComponent(password).appendingPathComponent("\(episodeID).\(ext)")
    }
    var xmltvURL: URL {
        var comps = URLComponents(url: server.appendingPathComponent("xmltv.php"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        return comps.url!
    }

    // MARK: Catalog

    func loadCatalog(sourceID: UUID, settings: AppSettings, progress: @escaping @Sendable (String) -> Void) async throws -> Catalog {
        let info = try await authenticate()
        let formats = info.allowedOutputFormats ?? []
        let liveFormat = (settings.preferHLS && (formats.isEmpty || formats.contains("m3u8"))) ? "m3u8" : "ts"

        progress("Loading categories…")
        async let liveCatsT = list("get_live_categories", as: XCategory.self)
        async let vodCatsT = list("get_vod_categories", as: XCategory.self)
        async let seriesCatsT = list("get_series_categories", as: XCategory.self)
        let (liveCats, vodCats, seriesCats) = try await (liveCatsT, vodCatsT, seriesCatsT)

        func names(_ cats: [XCategory]) -> [String: String] {
            Dictionary(cats.compactMap { c in c.categoryId?.string.map { ($0, c.categoryName?.string ?? "Uncategorized") } },
                       uniquingKeysWith: { a, _ in a })
        }
        let liveNames = names(liveCats), vodNames = names(vodCats), seriesNames = names(seriesCats)

        progress("Loading channels, movies and series…")
        async let liveT = list("get_live_streams", as: XLiveStream.self)
        async let vodT = list("get_vod_streams", as: XVodStream.self)
        async let seriesT = list("get_series", as: XSeries.self)
        let (live, vod, series) = try await (liveT, vodT, seriesT)

        var catalog = Catalog(sourceID: sourceID)
        catalog.epgURL = xmltvURL

        catalog.live = live.enumerated().compactMap { index, s in
            guard let id = s.streamId?.string else { return nil }
            return Channel(id: "l-\(id)", name: s.name?.string ?? "Channel \(id)", number: s.num?.int ?? index + 1,
                           group: s.categoryId?.string.flatMap { liveNames[$0] } ?? "Uncategorized",
                           logoURL: s.streamIcon?.string.flatMap(URL.init(string:)),
                           streamURL: liveURL(streamID: id, format: liveFormat),
                           epgID: s.epgChannelId?.string, hasArchive: s.tvArchive?.int == 1)
        }
        catalog.movies = vod.compactMap { s in
            guard let id = s.streamId?.string else { return nil }
            return Movie(id: "m-\(id)", name: s.name?.string ?? "Movie \(id)",
                         group: s.categoryId?.string.flatMap { vodNames[$0] } ?? "Uncategorized",
                         posterURL: s.streamIcon?.string.flatMap(URL.init(string:)),
                         streamURL: movieURL(streamID: id, ext: s.containerExtension?.string ?? "mp4"),
                         rating: s.rating?.string, plot: s.plot?.string, year: s.year?.string)
        }
        catalog.series = series.compactMap { s in
            guard let id = s.seriesId?.int else { return nil }
            return Series(id: "s-\(id)", remoteID: id, name: s.name?.string ?? "Series \(id)",
                          group: s.categoryId?.string.flatMap { seriesNames[$0] } ?? "Uncategorized",
                          coverURL: s.cover?.string.flatMap(URL.init(string:)), plot: s.plot?.string,
                          rating: s.rating?.string, genre: s.genre?.string, releaseDate: s.releaseDate?.string)
        }

        // Preserve the provider's category order, but only list categories that have content.
        func orderedGroups(_ cats: [XCategory], used: Set<String>) -> [String] {
            var set = OrderedSet()
            for c in cats { if let n = c.categoryName?.string, used.contains(n) { set.append(n) } }
            for n in used.sorted() { set.append(n) }
            return set.items
        }
        catalog.liveGroups = orderedGroups(liveCats, used: Set(catalog.live.map(\.group)))
        catalog.movieGroups = orderedGroups(vodCats, used: Set(catalog.movies.map(\.group)))
        catalog.seriesGroups = orderedGroups(seriesCats, used: Set(catalog.series.map(\.group)))
        return catalog
    }

    func episodes(for series: Series) async throws -> [Episode] {
        guard let remoteID = series.remoteID else { return [] }
        let data = try await fetch(apiURL("get_series_info", extra: [URLQueryItem(name: "series_id", value: String(remoteID))]))
        let info = try decoder.decode(XSeriesInfo.self, from: data)
        return info.episodes.compactMap { ep in
            guard let id = ep.id?.string else { return nil }
            return Episode(id: "e-\(id)", seriesID: series.id, title: ep.title?.string ?? "Episode",
                           season: ep.season?.int ?? 1, number: ep.episodeNum?.int ?? 0,
                           streamURL: episodeURL(episodeID: id, ext: ep.containerExtension?.string ?? "mp4"),
                           imageURL: ep.info?.movieImage?.string.flatMap(URL.init(string:)),
                           plot: ep.info?.plot?.string, durationSeconds: ep.info?.durationSecs?.int)
        }
        .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }
}
