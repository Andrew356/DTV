import XCTest
@testable import DTV

final class M3UParserTests: XCTestCase {
    let sample = """
    #EXTM3U url-tvg="http://example.com/epg.xml.gz"
    #EXTINF:-1 tvg-id="bbc1.uk" tvg-name="BBC One" tvg-logo="http://logo/bbc1.png" group-title="UK, Entertainment",BBC One HD
    http://host:8080/live/user/pass/101.ts
    #EXTINF:-1 tvg-id="" group-title="Movies",The Matrix (1999)
    http://host:8080/movie/user/pass/555.mkv
    #EXTINF:-1 group-title="Series",Breaking Bad S01 E02
    http://host:8080/series/user/pass/9001.mp4
    #EXTINF:-1 group-title="Series",Breaking Bad S01 E01
    http://host:8080/series/user/pass/9000.mp4
    #EXTINF:-1,No Attributes, With Comma
    #EXTVLCOPT:http-user-agent=Foo
    http://other/stream.m3u8
    """

    func testParsesEntriesAndHeader() {
        let p = M3UParser.parse(sample)
        XCTAssertEqual(p.epgURL, "http://example.com/epg.xml.gz")
        XCTAssertEqual(p.entries.count, 5)
        let first = p.entries[0]
        XCTAssertEqual(first.title, "BBC One HD")
        XCTAssertEqual(first.tvgID, "bbc1.uk")
        XCTAssertEqual(first.groupTitle, "UK, Entertainment")   // comma inside quotes
        XCTAssertEqual(first.logo, "http://logo/bbc1.png")
        XCTAssertEqual(p.entries[4].title, "No Attributes, With Comma")
        XCTAssertEqual(p.entries[4].url, "http://other/stream.m3u8")
    }

    func testCatalogClassification() {
        let catalog = CatalogBuilder.build(from: M3UParser.parse(sample), sourceID: UUID(), settings: AppSettings())
        XCTAssertEqual(catalog.live.count, 2)
        XCTAssertEqual(catalog.movies.count, 1)
        XCTAssertEqual(catalog.series.count, 1)
        XCTAssertEqual(catalog.series.first?.name, "Breaking Bad")
        let eps = catalog.m3uEpisodes[catalog.series[0].id] ?? []
        XCTAssertEqual(eps.map(\.number), [1, 2])
        // preferHLS rewrites Xtream-style .ts live URLs
        XCTAssertEqual(catalog.live[0].streamURL.absoluteString, "http://host:8080/live/user/pass/101.m3u8")
    }

    func testStableIDsAreDeterministic() {
        let a = CatalogBuilder.build(from: M3UParser.parse(sample), sourceID: UUID(), settings: AppSettings())
        let b = CatalogBuilder.build(from: M3UParser.parse(sample), sourceID: UUID(), settings: AppSettings())
        XCTAssertEqual(a.live.map(\.id), b.live.map(\.id))
        XCTAssertEqual(StableHash.fnv1a("hello"), StableHash.fnv1a("hello"))
    }
}

final class XtreamTests: XCTestCase {
    func testNormalizeServer() {
        XCTAssertEqual(XtreamClient.normalizeServer("host.tv:8080")?.absoluteString, "http://host.tv:8080")
        XCTAssertEqual(XtreamClient.normalizeServer("https://host.tv/player_api.php?username=a")?.absoluteString, "https://host.tv")
        XCTAssertEqual(XtreamClient.normalizeServer("http://host.tv:80/")?.absoluteString, "http://host.tv:80")
        XCTAssertNil(XtreamClient.normalizeServer("   "))
    }

    func testLenientDecoding() throws {
        let json = """
        [{"num":1,"name":"CNN","stream_id":"42","stream_icon":null,"epg_channel_id":"cnn.us","category_id":7,"tv_archive":0},
         {"num":"2","name":"Fox","stream_id":43,"category_id":"7","tv_archive":"1"}]
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let streams = try d.decode([XLiveStream].self, from: json)
        XCTAssertEqual(streams.map { $0.streamId?.string }, ["42", "43"])
        XCTAssertEqual(streams.map { $0.categoryId?.string }, ["7", "7"])
        XCTAssertEqual(streams[1].tvArchive?.int, 1)
    }

    func testSeriesInfoShapes() throws {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let dict = #"{"episodes":{"2":[{"id":"10","episode_num":3,"title":"Ep","container_extension":"mkv","info":[]}]}}"#
        let info = try d.decode(XSeriesInfo.self, from: Data(dict.utf8))
        XCTAssertEqual(info.episodes.count, 1)
        XCTAssertEqual(info.episodes[0].season?.int, 2)
        let nested = #"{"episodes":[[{"id":11,"episode_num":"1","season":1,"info":{"duration_secs":1800}}]]}"#
        let info2 = try d.decode(XSeriesInfo.self, from: Data(nested.utf8))
        XCTAssertEqual(info2.episodes.first?.info?.durationSecs?.int, 1800)
    }
}

final class EPGTests: XCTestCase {
    func testDateParsing() {
        let d = XMLTVParser.parseDate("20240131183000 +0100")
        XCTAssertEqual(d?.timeIntervalSince1970, 1706722200) // 2024-01-31 17:30:00 UTC
        XCTAssertEqual(XMLTVParser.parseDate("202401311830")?.timeIntervalSince1970, 1706725800)
        XCTAssertNil(XMLTVParser.parseDate("garbage"))
    }

    func testParsesProgrammesInWindow() {
        let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss Z"; f.timeZone = TimeZone(identifier: "UTC")
        let start = f.string(from: Date().addingTimeInterval(-600))
        let stop = f.string(from: Date().addingTimeInterval(1800))
        let xml = """
        <?xml version="1.0"?><tv>
        <channel id="BBC1.uk"><display-name>BBC One</display-name></channel>
        <programme start="\(start)" stop="\(stop)" channel="BBC1.uk"><title>News</title><desc>Headlines</desc></programme>
        <programme start="20000101000000 +0000" stop="20000101010000 +0000" channel="BBC1.uk"><title>Old</title></programme>
        </tv>
        """
        let epg = XMLTVParser.parse(data: Data(xml.utf8), hours: 24)
        let ch = Channel(id: "x", name: "BBC One", group: "", streamURL: URL(string: "http://x")!, epgID: nil)
        XCTAssertEqual(epg.listings(for: ch).map(\.title), ["News"])
        XCTAssertEqual(epg.current(for: ch)?.desc, "Headlines")
    }
}
