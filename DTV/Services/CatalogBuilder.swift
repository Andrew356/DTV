import Foundation

/// Turns a parsed M3U playlist into a structured catalog (Live / Movies / Series).
enum CatalogBuilder {
    static let videoExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "wmv", "flv", "webm", "mpg", "mpeg"]

    static func build(from playlist: M3UPlaylist, sourceID: UUID, settings: AppSettings) -> Catalog {
        var catalog = Catalog(sourceID: sourceID)
        catalog.epgURL = playlist.epgURL.flatMap(URL.init(string:))

        var liveGroups = OrderedSet()
        var movieGroups = OrderedSet()
        var seriesGroups = OrderedSet()
        var usedIDs = Set<String>()
        var seriesIndex: [String: Int] = [:]   // series key -> index in catalog.series

        func uniqueID(_ base: String) -> String {
            var id = base
            var n = 2
            while usedIDs.contains(id) { id = "\(base)-\(n)"; n += 1 }
            usedIDs.insert(id)
            return id
        }

        for entry in playlist.entries {
            guard let url = makeURL(entry.url) else { continue }
            let group = entry.groupTitle ?? "Uncategorized"
            let path = url.path.lowercased()
            let ext = url.pathExtension.lowercased()

            let isSeriesPath = path.contains("/series/")
            let isMoviePath = path.contains("/movie/")
            let episodeInfo = parseEpisode(entry.title)

            if isSeriesPath || (episodeInfo != nil && videoExtensions.contains(ext)) {
                let info = episodeInfo ?? (show: entry.title, season: 1, episode: 0)
                let seriesKey = "\(group)|\(info.show.lowercased())"
                let seriesID = "s-" + StableHash.fnv1a(seriesKey)
                if seriesIndex[seriesKey] == nil {
                    seriesIndex[seriesKey] = catalog.series.count
                    _ = usedIDs.insert(seriesID)
                    catalog.series.append(Series(id: seriesID, remoteID: nil, name: info.show, group: group,
                                                 coverURL: entry.logo.flatMap(URL.init(string:))))
                    seriesGroups.append(group)
                }
                let epID = uniqueID("e-" + StableHash.fnv1a(seriesKey + "|\(info.season)|\(info.episode)|" + entry.title))
                catalog.m3uEpisodes[seriesID, default: []].append(
                    Episode(id: epID, seriesID: seriesID, title: entry.title, season: info.season,
                            number: info.episode, streamURL: url, imageURL: entry.logo.flatMap(URL.init(string:)))
                )
            } else if isMoviePath || videoExtensions.contains(ext) {
                let id = uniqueID("m-" + StableHash.fnv1a(group + "|" + entry.title))
                catalog.movies.append(Movie(id: id, name: entry.title, group: group,
                                            posterURL: entry.logo.flatMap(URL.init(string:)), streamURL: url))
                movieGroups.append(group)
            } else {
                let base = entry.tvgID.map { "l-" + StableHash.fnv1a($0 + "|" + entry.title) }
                    ?? "l-" + StableHash.fnv1a(group + "|" + entry.title)
                let id = uniqueID(base)
                let streamURL = settings.preferHLS ? preferHLS(url) : url
                catalog.live.append(Channel(id: id, name: entry.title, number: entry.channelNumber ?? (catalog.live.count + 1),
                                            group: group, logoURL: entry.logo.flatMap(URL.init(string:)),
                                            streamURL: streamURL, epgID: entry.tvgID ?? entry.tvgName,
                                            hasArchive: entry.hasCatchup))
                liveGroups.append(group)
            }
        }

        for key in catalog.m3uEpisodes.keys {
            catalog.m3uEpisodes[key]?.sort { ($0.season, $0.number) < ($1.season, $1.number) }
        }
        catalog.liveGroups = liveGroups.items
        catalog.movieGroups = movieGroups.items
        catalog.seriesGroups = seriesGroups.items
        return catalog
    }

    static func makeURL(_ raw: String) -> URL? {
        // Strip Kodi-style "|User-Agent=..." suffixes.
        let trimmed = raw.split(separator: "|", maxSplits: 1).first.map(String.init) ?? raw
        if let url = URL(string: trimmed) { return url }
        return trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
    }

    /// Xtream-style `/live/user/pass/123.ts` (or `/user/pass/123`) → `.m3u8`, which AVPlayer can play natively.
    static func preferHLS(_ url: URL) -> URL {
        let ext = url.pathExtension.lowercased()
        let comps = url.pathComponents
        let looksXtream = comps.count >= 4 && Int(url.deletingPathExtension().lastPathComponent) != nil
        guard looksXtream, ext == "ts" || ext.isEmpty else { return url }
        return url.deletingPathExtension().appendingPathExtension("m3u8")
    }

    private static let episodeRegex = try! NSRegularExpression(
        pattern: #"^(.*?)[\s\.\-_:]*\bS(\d{1,2})\s*[\.\-_]?\s*E(\d{1,3})\b"#, options: [.caseInsensitive])

    /// "Show Name S01 E02 - Title" → ("Show Name", 1, 2)
    static func parseEpisode(_ title: String) -> (show: String, season: Int, episode: Int)? {
        let range = NSRange(title.startIndex..., in: title)
        guard let m = episodeRegex.firstMatch(in: title, range: range),
              let showR = Range(m.range(at: 1), in: title),
              let sR = Range(m.range(at: 2), in: title),
              let eR = Range(m.range(at: 3), in: title),
              let s = Int(title[sR]), let e = Int(title[eR]) else { return nil }
        var show = String(title[showR]).trimmingCharacters(in: CharacterSet(charactersIn: " -_.:|"))
        if show.isEmpty { show = title }
        return (show, s, e)
    }
}

/// Minimal insertion-ordered set of strings.
struct OrderedSet {
    private(set) var items: [String] = []
    private var seen = Set<String>()
    mutating func append(_ s: String) {
        if seen.insert(s).inserted { items.append(s) }
    }
}
