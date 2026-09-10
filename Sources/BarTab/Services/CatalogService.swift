import Foundation

/// The full catalogue of everything Homebrew can install, from formulae.brew.sh.
///
/// The API payloads are ~7 MB gzipped and change once a day, so we download them,
/// reduce them to the fields the UI needs, and cache that slim form in Application
/// Support. Relaunches are then instant and offline-friendly.
actor CatalogService {
    static let formulaURL = URL(string: "https://formulae.brew.sh/api/formula.json")!
    static let caskURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
    static let formulaAnalyticsURL = URL(string: "https://formulae.brew.sh/api/analytics/install/30d.json")!
    static let caskAnalyticsURL = URL(string: "https://formulae.brew.sh/api/analytics/cask-install/30d.json")!

    /// Re-download if the cache is older than this.
    static let maxCacheAge: TimeInterval = 12 * 60 * 60

    private let cacheURL: URL
    private let session: URLSession

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarTab", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        cacheURL = support.appendingPathComponent("catalog.json")

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    /// Cached catalogue, if we have one. Nil when nothing has been downloaded yet.
    func cached() -> CatalogCache? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CatalogCache.self, from: data),
              cache.schemaVersion == CatalogCache.currentSchema
        else { return nil }
        return cache
    }

    func isStale(_ cache: CatalogCache) -> Bool {
        Date().timeIntervalSince(cache.fetchedAt) > Self.maxCacheAge
    }

    /// Downloads and rebuilds the catalogue.
    func refresh() async throws -> CatalogCache {
        async let formulaData = fetch(Self.formulaURL)
        async let caskData = fetch(Self.caskURL)
        async let formulaAnalytics = try? fetch(Self.formulaAnalyticsURL)
        async let caskAnalytics = try? fetch(Self.caskAnalyticsURL)

        let (formulae, casks) = try await (formulaData, caskData)
        let (fAnalytics, cAnalytics) = await (formulaAnalytics, caskAnalytics)

        var entries = try Self.parseFormulae(formulae)
        entries += try Self.parseCasks(casks)

        var installs: [String: Int] = [:]
        if let fAnalytics { installs.merge(Self.parseAnalytics(fAnalytics, kind: .formula)) { a, _ in a } }
        if let cAnalytics { installs.merge(Self.parseAnalytics(cAnalytics, kind: .cask)) { a, _ in a } }
        for index in entries.indices {
            entries[index].installs30d = installs[entries[index].id] ?? 0
        }

        let cache = CatalogCache(fetchedAt: Date(), entries: entries)
        if let encoded = try? JSONEncoder().encode(cache) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        return cache
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BrewError(message: "Couldn't reach formulae.brew.sh (\(url.lastPathComponent)).")
        }
        return data
    }

    // MARK: - Parsing

    nonisolated static func parseFormulae(_ data: Data) throws -> [CatalogEntry] {
        let root = try JSONValue.parse(data)
        return root.array.compactMap { item in
            guard let token = item["name"].string else { return nil }
            let version = item["versions"]["stable"].string ?? item["version"].string ?? "—"
            return CatalogEntry(
                token: token,
                name: token,
                kind: .formula,
                desc: item["desc"].nonEmptyString,
                homepage: item["homepage"].nonEmptyString,
                version: version,
                tap: item["tap"].nonEmptyString,
                license: item["license"].nonEmptyString,
                deprecated: item["deprecated"].bool,
                disabled: item["disabled"].bool,
                dependencies: item["dependencies"].stringArray,
                caveats: item["caveats"].nonEmptyString,
                appNames: [],
                autoUpdates: false,
                bundleIDs: [],
                installs30d: 0
            )
        }
    }

    nonisolated static func parseCasks(_ data: Data) throws -> [CatalogEntry] {
        let root = try JSONValue.parse(data)
        return root.array.compactMap { item in
            guard let token = item["token"].string else { return nil }
            let names = item["name"].stringArray
            return CatalogEntry(
                token: token,
                name: names.first ?? token,
                kind: .cask,
                desc: item["desc"].nonEmptyString,
                homepage: item["homepage"].nonEmptyString,
                version: item["version"].string ?? "—",
                tap: item["tap"].nonEmptyString,
                license: nil,
                deprecated: item["deprecated"].bool,
                disabled: item["disabled"].bool,
                dependencies: BrewService.caskFormulaDependencies(item),
                caveats: item["caveats"].nonEmptyString,
                appNames: BrewService.caskAppNames(item),
                autoUpdates: item["auto_updates"].bool,
                bundleIDs: BrewService.caskBundleIDs(item),
                installs30d: 0
            )
        }
    }

    /// `{ "items": [ { "formula": "wget", "count": "12,345" }, ... ] }`
    nonisolated static func parseAnalytics(_ data: Data, kind: PackageKind) -> [String: Int] {
        guard let root = try? JSONValue.parse(data) else { return [:] }
        var result: [String: Int] = [:]
        for item in root["items"].array {
            let key = kind == .formula ? "formula" : "cask"
            // Formula analytics keys include install options, e.g. "wget --HEAD".
            guard let rawName = item[key].string?.split(separator: " ").first.map(String.init),
                  let count = item["count"].int else { continue }
            let id = "\(kind.rawValue):\(rawName)"
            result[id, default: 0] += count
        }
        return result
    }
}
