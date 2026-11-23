import Foundation

/// On-device cache of downloaded catalogs and guide data (not synced – re-downloaded per device).
enum CatalogCache {
    private static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(_ name: String, _ id: UUID) -> URL {
        directory.appendingPathComponent("\(name)-\(id.uuidString).json")
    }

    static func loadCatalog(_ id: UUID) -> Catalog? {
        guard let data = try? Data(contentsOf: url("catalog", id)) else { return nil }
        return try? JSONDecoder.dtv.decode(Catalog.self, from: data)
    }

    static func saveCatalog(_ catalog: Catalog) {
        guard let data = try? JSONEncoder.dtv.encode(catalog) else { return }
        try? data.write(to: url("catalog", catalog.sourceID), options: .atomic)
    }

    static func loadEPG(_ id: UUID) -> EPGData? {
        guard let data = try? Data(contentsOf: url("epg", id)) else { return nil }
        return try? JSONDecoder.dtv.decode(EPGData.self, from: data)
    }

    static func saveEPG(_ epg: EPGData, for id: UUID) {
        guard let data = try? JSONEncoder.dtv.encode(epg) else { return }
        try? data.write(to: url("epg", id), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
