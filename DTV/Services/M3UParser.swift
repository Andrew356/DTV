import Foundation

struct M3UEntry: Hashable {
    var title: String
    var attributes: [String: String]
    var url: String
    var group: String?

    var tvgID: String? { attributes["tvg-id"].nonEmpty }
    var tvgName: String? { attributes["tvg-name"].nonEmpty }
    var logo: String? { attributes["tvg-logo"].nonEmpty ?? attributes["logo"].nonEmpty }
    var groupTitle: String? { attributes["group-title"].nonEmpty ?? group.nonEmpty }
    var channelNumber: Int? { (attributes["tvg-chno"] ?? attributes["channel-number"]).flatMap { Int($0) } }
    var hasCatchup: Bool { attributes["catchup"] != nil || attributes["tvg-rec"].map { $0 != "0" } == true }
}

struct M3UPlaylist {
    var entries: [M3UEntry]
    var epgURL: String?
}

enum M3UParser {
    static func parse(_ text: String) -> M3UPlaylist {
        var entries: [M3UEntry] = []
        entries.reserveCapacity(4096)
        var epgURL: String?
        var pending: M3UEntry?
        var pendingGroup: String?

        text.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return }

            if line.hasPrefix("#EXTM3U") {
                let attrs = parseAttributes(Substring(line.dropFirst(7)))
                epgURL = (attrs["url-tvg"] ?? attrs["x-tvg-url"] ?? attrs["tvg-url"])?
                    .split(separator: ",").first.map(String.init)
            } else if line.hasPrefix("#EXTINF:") {
                let body = line.dropFirst(8)
                let (attrPart, title) = splitTitle(body)
                // attrPart starts with duration, e.g. "-1 tvg-id=..."
                let attrs = parseAttributes(attrPart)
                pending = M3UEntry(title: title.trimmingCharacters(in: .whitespaces),
                                   attributes: attrs, url: "", group: pendingGroup)
            } else if line.hasPrefix("#EXTGRP:") {
                let g = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                if pending != nil { pending?.group = g } else { pendingGroup = g }
            } else if line.hasPrefix("#") {
                return // #EXTVLCOPT, #KODIPROP, comments...
            } else {
                if var entry = pending {
                    entry.url = line
                    if entry.title.isEmpty { entry.title = entry.tvgName ?? line }
                    entries.append(entry)
                } else {
                    entries.append(M3UEntry(title: line, attributes: [:], url: line, group: pendingGroup))
                }
                pending = nil
                pendingGroup = nil
            }
        }
        return M3UPlaylist(entries: entries, epgURL: epgURL)
    }

    /// Splits `-1 key="a,b",Title, with comma` at the first comma outside quotes.
    static func splitTitle(_ body: Substring) -> (Substring, String) {
        var inQuotes = false
        var idx = body.startIndex
        while idx < body.endIndex {
            let c = body[idx]
            if c == "\"" { inQuotes.toggle() }
            else if c == "," && !inQuotes {
                return (body[body.startIndex..<idx], String(body[body.index(after: idx)...]))
            }
            idx = body.index(after: idx)
        }
        return (body, "")
    }

    /// Parses `key="value" key2=value2` pairs.
    static func parseAttributes(_ s: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var i = s.startIndex
        func skipSpaces() { while i < s.endIndex, s[i] == " " || s[i] == "\t" { i = s.index(after: i) } }
        while i < s.endIndex {
            skipSpaces()
            let keyStart = i
            while i < s.endIndex, s[i] != "=", s[i] != " " { i = s.index(after: i) }
            let key = s[keyStart..<i]
            guard i < s.endIndex, s[i] == "=" else { continue }
            i = s.index(after: i)
            var value: Substring
            if i < s.endIndex, s[i] == "\"" {
                i = s.index(after: i)
                let vStart = i
                while i < s.endIndex, s[i] != "\"" { i = s.index(after: i) }
                value = s[vStart..<i]
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                let vStart = i
                while i < s.endIndex, s[i] != " " { i = s.index(after: i) }
                value = s[vStart..<i]
            }
            if !key.isEmpty { result[key.lowercased()] = String(value) }
        }
        return result
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }
}
