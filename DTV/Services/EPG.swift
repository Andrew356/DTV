import Foundation
import Compression

struct Programme: Codable, Hashable, Identifiable {
    var title: String
    var desc: String?
    var start: Date
    var stop: Date

    var id: Date { start }
    func isAiring(at date: Date = Date()) -> Bool { start <= date && date < stop }
    func progress(at date: Date = Date()) -> Double {
        let total = stop.timeIntervalSince(start)
        return total > 0 ? min(1, max(0, date.timeIntervalSince(start) / total)) : 0
    }
}

/// Guide data keyed by normalized XMLTV channel id.
struct EPGData: Codable {
    var programmes: [String: [Programme]] = [:]
    /// Lower-cased display-name → channel id, for M3U entries without tvg-id.
    var nameIndex: [String: String] = [:]
    var loadedAt: Date = .distantPast

    static func normalize(_ id: String) -> String { id.lowercased().trimmingCharacters(in: .whitespaces) }

    func listings(for channel: Channel) -> [Programme] {
        if let epgID = channel.epgID, let p = programmes[Self.normalize(epgID)] { return p }
        if let id = nameIndex[Self.normalize(channel.name)], let p = programmes[id] { return p }
        return []
    }

    func current(for channel: Channel, at date: Date = Date()) -> Programme? {
        listings(for: channel).first { $0.isAiring(at: date) }
    }

    func upcoming(for channel: Channel, after date: Date = Date(), limit: Int = 6) -> [Programme] {
        Array(listings(for: channel).filter { $0.stop > date }.prefix(limit))
    }
}

// MARK: - XMLTV parsing (streaming, works on very large guides)

final class XMLTVParser: NSObject, XMLParserDelegate {
    private let windowStart: Date
    private let windowEnd: Date
    private var result = EPGData()

    private var currentChannelID: String?
    private var currentProgramme: (channel: String, start: Date, stop: Date)?
    private var title: String?
    private var desc: String?
    private var text = ""
    private var capture = false

    init(windowStart: Date, windowEnd: Date) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }

    static func parse(stream: InputStream, hours: Int) -> EPGData {
        let now = Date()
        let handler = XMLTVParser(windowStart: now.addingTimeInterval(-3 * 3600),
                                  windowEnd: now.addingTimeInterval(TimeInterval(hours) * 3600))
        let parser = XMLParser(stream: stream)
        parser.delegate = handler
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return handler.finish()
    }

    static func parse(data: Data, hours: Int) -> EPGData {
        parse(stream: InputStream(data: data), hours: hours)
    }

    private func finish() -> EPGData {
        for key in result.programmes.keys {
            result.programmes[key]?.sort { $0.start < $1.start }
        }
        result.loadedAt = Date()
        return result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "channel":
            currentChannelID = attributes["id"].map(EPGData.normalize)
        case "display-name":
            capture = currentChannelID != nil
            text = ""
        case "programme":
            guard let ch = attributes["channel"],
                  let start = attributes["start"].flatMap(Self.parseDate),
                  let stop = attributes["stop"].flatMap(Self.parseDate),
                  stop > windowStart, start < windowEnd else { currentProgramme = nil; return }
            currentProgramme = (EPGData.normalize(ch), start, stop)
            title = nil; desc = nil
        case "title", "desc":
            capture = currentProgramme != nil
            text = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "display-name":
            if let id = currentChannelID {
                let key = EPGData.normalize(text)
                if !key.isEmpty, result.nameIndex[key] == nil { result.nameIndex[key] = id }
            }
            capture = false
        case "channel":
            currentChannelID = nil
        case "title":
            if currentProgramme != nil, title == nil { title = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            capture = false
        case "desc":
            if currentProgramme != nil, desc == nil { desc = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            capture = false
        case "programme":
            if let p = currentProgramme {
                result.programmes[p.channel, default: []].append(
                    Programme(title: title ?? "Untitled", desc: desc, start: p.start, stop: p.stop))
            }
            currentProgramme = nil
        default: break
        }
    }

    /// Parses XMLTV dates: "20240131183000 +0100" (offset optional, seconds optional).
    /// Hand-rolled because DateFormatter is far too slow for guides with 100k+ programmes.
    static func parseDate(_ s: String) -> Date? {
        let bytes = Array(s.utf8)
        guard bytes.count >= 12 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= bytes.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                let b = bytes[i]
                guard b >= 48 && b <= 57 else { return nil }
                v = v * 10 + Int(b - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2),
              let h = num(8, 2), let mi = num(10, 2) else { return nil }
        let sec = num(12, 2) ?? 0

        var offset = 0
        if let signIdx = bytes.firstIndex(where: { $0 == 43 || $0 == 45 }), signIdx >= 12 { // '+' or '-'
            if let oh = num(signIdx + 1, 2), let om = num(signIdx + 3, 2) {
                offset = (oh * 3600 + om * 60) * (bytes[signIdx] == 45 ? -1 : 1)
            }
        }
        // Days from civil (Howard Hinnant's algorithm).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        let epoch = days * 86400 + h * 3600 + mi * 60 + sec - offset
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }
}

// MARK: - Loading

enum EPGLoader {
    static func load(from url: URL, hours: Int) async throws -> EPGData {
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.setValue("DTV/1.0 (tvOS)", forHTTPHeaderField: "User-Agent")
        let (fileURL, response) = try await URLSession.shared.download(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XtreamError.badResponse(http.statusCode)
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        return try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: fileURL)
            let magic = try handle.read(upToCount: 2) ?? Data()
            try handle.close()
            if magic == Data([0x1f, 0x8b]) {
                let compressed = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                let xml = try Gzip.decompress(compressed)
                return XMLTVParser.parse(data: xml, hours: hours)
            }
            guard let stream = InputStream(url: fileURL) else { throw CocoaError(.fileReadUnknown) }
            return XMLTVParser.parse(stream: stream, hours: hours)
        }.value
    }
}

enum Gzip {
    enum GzipError: Error { case invalidHeader, decompressionFailed }

    /// Decompresses a gzip (.gz) payload using Apple's Compression framework (raw DEFLATE).
    static func decompress(_ data: Data) throws -> Data {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b,
              data[data.startIndex + 2] == 8 else { throw GzipError.invalidHeader }
        let flags = data[data.startIndex + 3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            let xlen = Int(data[data.startIndex + offset]) | Int(data[data.startIndex + offset + 1]) << 8
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 { while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }; offset += 1 } // FNAME
        if flags & 0x10 != 0 { while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }; offset += 1 } // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < data.count - 8 else { throw GzipError.invalidHeader }

        let payload = data.subdata(in: (data.startIndex + offset)..<(data.endIndex - 8))
        var output = Data()
        let bufferSize = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }

        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GzipError.decompressionFailed
        }
        defer { compression_stream_destroy(streamPtr) }

        try payload.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { throw GzipError.decompressionFailed }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = src.count
            while true {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = bufferSize
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - streamPtr.pointee.dst_size
                if produced > 0 { output.append(dst, count: produced) }
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return
                default: throw GzipError.decompressionFailed
                }
            }
        }
        return output
    }
}
