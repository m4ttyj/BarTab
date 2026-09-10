import AppKit
import Foundation
import Observation

/// Points at a package regardless of whether it's installed, in the catalogue, or both.
struct PackageRef: Hashable, Identifiable, Sendable {
    let kind: PackageKind
    let token: String
    var id: String { "\(kind.rawValue):\(token)" }
}

/// A catalogue entry with its search text precomputed once at load.
struct CatalogRow: Identifiable, Sendable {
    let entry: CatalogEntry
    let tokenLower: String
    let nameLower: String
    let descLower: String
    var id: String { entry.id }

    init(entry: CatalogEntry) {
        self.entry = entry
        self.tokenLower = entry.token.lowercased()
        self.nameLower = entry.name.lowercased()
        var extra = entry.desc?.lowercased() ?? ""
        for app in entry.appNames { extra += " " + app.lowercased() }
        self.descLower = extra
    }
}

enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case installed, updates, browse, adopt, maintenance, activity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .installed: "Installed"
        case .updates: "Updates"
        case .browse: "Browse"
        case .adopt: "Unmanaged Apps"
        case .maintenance: "Maintenance"
        case .activity: "Activity"
        }
    }

    /// Shown on hover in the sidebar.
    var help: String {
        switch self {
        case .installed: "Every formula and cask Homebrew has installed on this Mac"
        case .updates: "Packages with a newer version available"
        case .browse: "Search everything Homebrew can install"
        case .adopt: "Apps you installed by hand that Homebrew could take over"
        case .maintenance: "Health checks, cleanup and updating Homebrew itself"
        case .activity: "Output from every command this app has run"
        }
    }

    var symbol: String {
        switch self {
        case .installed: "shippingbox"
        case .updates: "arrow.triangle.2.circlepath"
        case .browse: "square.grid.2x2"
        case .adopt: "app.badge.checkmark"
        case .maintenance: "stethoscope"
        case .activity: "list.bullet.rectangle"
        }
    }
}

enum InstalledFilter: String, CaseIterable, Identifiable {
    case all, formulae, casks, leaves
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .formulae: "Formulae"
        case .casks: "Casks"
        case .leaves: "Top level"
        }
    }
}

enum BrowseFilter: String, CaseIterable, Identifiable {
    case all, formulae, casks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .formulae: "Formulae"
        case .casks: "Casks"
        }
    }
}

enum AdoptFilter: String, CaseIterable, Identifiable {
    case adoptable, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .adoptable: "Adoptable"
        case .all: "All apps"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // Environment
    private(set) var env: BrewEnvironment?
    private(set) var service: BrewService?
    private(set) var setupError: String?
    private(set) var brewVersion = ""

    // Local state
    private(set) var installed: [InstalledPackage] = []
    private(set) var outdated: [OutdatedPackage] = []
    private(set) var sizes: [String: Int64] = [:]
    private(set) var isLoadingLocal = false
    private(set) var localError: String?
    private(set) var lastLocalRefresh: Date?

    // Catalogue
    private(set) var catalogRows: [CatalogRow] = []
    private(set) var catalogFetchedAt: Date?
    private(set) var isLoadingCatalog = false
    private(set) var catalogError: String?

    // Apps installed outside Homebrew
    private(set) var installedApps: [InstalledApp] = []
    private(set) var isScanningApps = false
    private(set) var lastAppScan: Date?

    // Maintenance
    private(set) var doctorReport: DoctorReport?
    private(set) var isRunningDoctor = false
    private(set) var cleanupPreview: CleanupPreview?
    private(set) var isCheckingCleanup = false

    // UI selection
    var section: SidebarSection = .installed
    var installedFilter: InstalledFilter = .all
    var browseFilter: BrowseFilter = .all
    var installedSearch = ""
    var browseSearch = ""
    var adoptFilter: AdoptFilter = .adoptable
    var adoptSelection: AdoptionCandidate.ID?
    /// Include casks that keep themselves up to date.
    var includeSelfUpdatingCasks = false {
        didSet { Task { await refreshLocal() } }
    }
    var selection: PackageRef?

    let operations = OperationCenter()
    private let catalog = CatalogService()

    // MARK: - Lookup

    private var installedByID: [String: InstalledPackage] = [:]
    private var catalogByID: [String: CatalogEntry] = [:]
    private var outdatedByID: [String: OutdatedPackage] = [:]
    /// App bundle file name → casks that install it. Built once per catalogue load.
    private var caskAppIndex: [String: [CatalogEntry]] = [:]

    func installedPackage(_ ref: PackageRef) -> InstalledPackage? { installedByID[ref.id] }
    func catalogEntry(_ ref: PackageRef) -> CatalogEntry? { catalogByID[ref.id] }
    func outdatedEntry(_ ref: PackageRef) -> OutdatedPackage? { outdatedByID[ref.id] }
    func isInstalled(_ ref: PackageRef) -> Bool { installedByID[ref.id] != nil }
    func size(_ ref: PackageRef) -> Int64? { sizes[ref.id] }

    /// Resolves a bare dependency name (which has no kind) to something clickable.
    func resolveDependency(_ name: String) -> PackageRef? {
        let bare = name.split(separator: " ").first.map(String.init) ?? name
        let formula = PackageRef(kind: .formula, token: bare)
        if installedByID[formula.id] != nil || catalogByID[formula.id] != nil { return formula }
        let cask = PackageRef(kind: .cask, token: bare)
        if installedByID[cask.id] != nil || catalogByID[cask.id] != nil { return cask }
        return nil
    }

    // MARK: - Setup

    func start() async {
        do {
            let env = try BrewEnvironment.discover()
            self.env = env
            self.service = BrewService(env: env)
            operations.configure(env: env)
            operations.onLocalStateChanged = { [weak self] in
                await self?.refreshLocal()
            }
        } catch {
            setupError = error.localizedDescription
            return
        }
        async let version: Void = loadVersion()
        async let local: Void = refreshLocal()
        async let cat: Void = loadCatalog()
        async let apps: Void = scanApps()
        _ = await (version, local, cat, apps)
    }

    private func loadVersion() async {
        guard let service else { return }
        brewVersion = await service.version()
    }

    // MARK: - Local refresh

    func refreshLocal() async {
        guard let service else { return }
        isLoadingLocal = true
        localError = nil
        defer { isLoadingLocal = false }

        do {
            async let installedTask = service.installedPackages()
            async let outdatedTask = service.outdatedPackages(greedy: includeSelfUpdatingCasks)
            let (packages, outdatedItems) = try await (installedTask, outdatedTask)
            installed = packages
            outdated = outdatedItems
            installedByID = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) })
            outdatedByID = Dictionary(outdatedItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            lastLocalRefresh = Date()
        } catch {
            localError = error.localizedDescription
        }

        // Sizes are slower and non-essential, so they land separately.
        let usage = await service.diskUsage()
        if !usage.isEmpty { sizes = usage }
        await scanApps()
    }

    // MARK: - Apps outside Homebrew

    func scanApps() async {
        isScanningApps = true
        defer { isScanningApps = false }
        installedApps = await AppScanner().scan()
        lastAppScan = Date()
    }

    /// Called when the app regains focus — you may have run brew in a terminal.
    func refreshLocalIfStale(maxAge: TimeInterval = 30) async {
        guard !isLoadingLocal else { return }
        if let lastLocalRefresh, Date().timeIntervalSince(lastLocalRefresh) < maxAge { return }
        await refreshLocal()
    }

    // MARK: - Catalogue

    func loadCatalog(forceRefresh: Bool = false) async {
        isLoadingCatalog = true
        catalogError = nil
        defer { isLoadingCatalog = false }

        if !forceRefresh, let cached = await catalog.cached() {
            apply(cached)
            guard await catalog.isStale(cached) else { return }
        }

        do {
            let fresh = try await catalog.refresh()
            apply(fresh)
        } catch {
            // A stale catalogue still beats an empty one.
            if catalogRows.isEmpty {
                catalogError = error.localizedDescription
            }
        }
    }

    private func apply(_ cache: CatalogCache) {
        catalogRows = cache.entries.map(CatalogRow.init)
        catalogByID = Dictionary(cache.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        catalogFetchedAt = cache.fetchedAt

        var index: [String: [CatalogEntry]] = [:]
        for entry in cache.entries where entry.kind == .cask {
            for name in entry.appNames {
                index[name, default: []].append(entry)
            }
        }
        caskAppIndex = index
    }

    // MARK: - Derived lists

    var installedList: [InstalledPackage] {
        let query = installedSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return installed.filter { package in
            switch installedFilter {
            case .all: break
            case .formulae: if package.kind != .formula { return false }
            case .casks: if package.kind != .cask { return false }
            case .leaves: if !package.installedOnRequest { return false }
            }
            guard !query.isEmpty else { return true }
            return package.token.lowercased().contains(query)
                || package.name.lowercased().contains(query)
                || (package.desc?.lowercased().contains(query) ?? false)
        }
    }

    var outdatedList: [OutdatedPackage] { outdated }

    var upgradableCount: Int { outdated.filter { !$0.pinned }.count }

    var counts: (formulae: Int, casks: Int, leaves: Int) {
        (installed.filter { $0.kind == .formula }.count,
         installed.filter { $0.kind == .cask }.count,
         installed.filter { $0.installedOnRequest }.count)
    }

    var totalInstalledSize: Int64 { sizes.values.reduce(0, +) }

    /// Ranked catalogue search. With no query, shows the most-installed packages.
    var browseResults: [CatalogRow] {
        let query = browseSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let kindFiltered = catalogRows.filter { row in
            if row.entry.disabled { return false }
            switch browseFilter {
            case .all: return true
            case .formulae: return row.entry.kind == .formula
            case .casks: return row.entry.kind == .cask
            }
        }

        guard !query.isEmpty else {
            return Array(kindFiltered.sorted { $0.entry.installs30d > $1.entry.installs30d }.prefix(200))
        }

        var scored: [(row: CatalogRow, score: Int)] = []
        scored.reserveCapacity(256)
        for row in kindFiltered {
            let score: Int
            if row.tokenLower == query { score = 0 }
            else if row.tokenLower.hasPrefix(query) { score = 1 }
            else if row.nameLower.hasPrefix(query) { score = 2 }
            else if row.tokenLower.contains(query) { score = 3 }
            else if row.nameLower.contains(query) { score = 4 }
            else if row.descLower.contains(query) { score = 5 }
            else { continue }
            scored.append((row, score))
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score
                ? lhs.score < rhs.score
                : lhs.row.entry.installs30d > rhs.row.entry.installs30d
        }
        return scored.prefix(200).map(\.row)
    }

    // MARK: - Adoption

    private var installedCaskTokens: Set<String> {
        Set(installed.filter { $0.kind == .cask }.map(\.token))
    }

    var adoptionCandidates: [AdoptionCandidate] {
        guard !caskAppIndex.isEmpty else { return [] }
        return AdoptionMatcher.candidates(
            apps: installedApps,
            index: caskAppIndex,
            installedCaskTokens: installedCaskTokens
        )
    }

    /// Apps we found that no cask installs — shown in the "All apps" filter so the
    /// list accounts for everything, rather than silently dropping them.
    var unmatchedApps: [InstalledApp] {
        let matched = Set(adoptionCandidates.map(\.app.path))
        return installedApps.filter { !matched.contains($0.path) && !$0.isAppleSystemApp }
    }

    var readyToAdoptCount: Int {
        adoptionCandidates.count { $0.canAdopt }
    }

    func candidate(id: AdoptionCandidate.ID) -> AdoptionCandidate? {
        adoptionCandidates.first { $0.id == id }
    }

    func adopt(_ candidate: AdoptionCandidate) {
        operations.enqueue(
            title: "Adopt \(candidate.app.displayName)",
            arguments: ["install", "--cask", "--adopt", candidate.cask.token]
        )
        section = .activity
    }

    func adoptAllReady() {
        for candidate in adoptionCandidates where candidate.canAdopt {
            operations.enqueue(
                title: "Adopt \(candidate.app.displayName)",
                arguments: ["install", "--cask", "--adopt", candidate.cask.token]
            )
        }
        section = .activity
    }

    /// The destructive alternative when versions differ: throw away the installed
    /// copy and install the cask's version over it.
    func replaceWithCask(_ candidate: AdoptionCandidate) {
        operations.enqueue(
            title: "Replace \(candidate.app.displayName) with Homebrew's copy",
            arguments: ["install", "--cask", "--force", candidate.cask.token]
        )
        section = .activity
    }

    func revealApp(_ app: InstalledApp) {
        NSWorkspace.shared.selectFile(app.path, inFileViewerRootedAtPath: (app.path as NSString).deletingLastPathComponent)
    }

    // MARK: - Actions

    func install(_ ref: PackageRef) {
        operations.enqueue(title: "Install \(ref.token)", arguments: ["install", ref.kind.brewFlag, ref.token])
        section = .activity
    }

    func upgrade(_ ref: PackageRef) {
        operations.enqueue(title: "Upgrade \(ref.token)", arguments: ["upgrade", ref.kind.brewFlag, ref.token])
        section = .activity
    }

    func upgradeAll() {
        operations.enqueue(title: "Upgrade all packages", arguments: ["upgrade"])
        section = .activity
    }

    func uninstall(_ ref: PackageRef, zap: Bool = false) {
        var args = ["uninstall", ref.kind.brewFlag]
        if zap && ref.kind == .cask { args = ["uninstall", "--cask", "--zap"] }
        args.append(ref.token)
        operations.enqueue(title: "Uninstall \(ref.token)", arguments: args)
        section = .activity
    }

    func reinstall(_ ref: PackageRef) {
        operations.enqueue(title: "Reinstall \(ref.token)", arguments: ["reinstall", ref.kind.brewFlag, ref.token])
        section = .activity
    }

    func setPinned(_ ref: PackageRef, pinned: Bool) {
        guard ref.kind == .formula else { return }
        operations.enqueue(
            title: pinned ? "Pin \(ref.token)" : "Unpin \(ref.token)",
            arguments: [pinned ? "pin" : "unpin", ref.token]
        )
    }

    func updateHomebrew() {
        operations.enqueue(title: "Update Homebrew", arguments: ["update"])
        section = .activity
    }

    func runCleanup() {
        operations.enqueue(title: "Clean up old versions and caches", arguments: ["cleanup", "--prune=all", "-s"])
        section = .activity
    }

    func runAutoremove() {
        operations.enqueue(title: "Remove unused dependencies", arguments: ["autoremove"])
        section = .activity
    }

    func runDoctor() async {
        guard let service else { return }
        isRunningDoctor = true
        defer { isRunningDoctor = false }
        doctorReport = await service.doctor()
    }

    func checkCleanup() async {
        guard let service else { return }
        isCheckingCleanup = true
        defer { isCheckingCleanup = false }
        cleanupPreview = await service.cleanupPreview()
    }

    func dependents(of ref: PackageRef) async -> [String] {
        guard let service, ref.kind == .formula else { return [] }
        return await service.dependents(of: ref.token)
    }

    func openInTerminal(_ arguments: [String]) {
        guard let env else { return }
        OperationCenter.openInTerminal(brew: env.brewURL, arguments: arguments)
    }

    func openHomepage(_ urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveals a cask's installed app, or a formula's keg, in Finder.
    func revealInFinder(_ ref: PackageRef) {
        guard let env else { return }
        let url: URL
        switch ref.kind {
        case .formula: url = env.cellarURL.appendingPathComponent(ref.token)
        case .cask: url = env.caskroomURL.appendingPathComponent(ref.token)
        }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}
