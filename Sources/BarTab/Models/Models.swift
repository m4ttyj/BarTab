import Foundation

// MARK: - Kind

enum PackageKind: String, Codable, Sendable, Hashable, CaseIterable {
    case formula
    case cask

    var label: String { self == .formula ? "Formula" : "Cask" }
    var pluralLabel: String { self == .formula ? "Formulae" : "Casks" }
    var symbol: String { self == .formula ? "terminal" : "macwindow" }

    /// The `--formula` / `--cask` flag brew wants for disambiguation.
    var brewFlag: String { self == .formula ? "--formula" : "--cask" }
}

// MARK: - Installed

struct InstalledPackage: Identifiable, Sendable, Hashable {
    let token: String            // full_name / full_token, unique within a kind
    let name: String             // human-facing name
    let kind: PackageKind
    let desc: String?
    let homepage: String?
    let installedVersion: String
    let latestVersion: String?
    let tap: String?
    let license: String?
    let installedOnRequest: Bool // false => pulled in as a dependency
    let installedAt: Date?
    let dependencies: [String]
    let buildDependencies: [String]
    let caveats: String?
    let pinned: Bool
    let deprecated: Bool
    let deprecationReason: String?
    let kegOnly: Bool
    let outdated: Bool
    let appNames: [String]       // casks: bundled .app names
    /// A cask Homebrew still has registered whose app is no longer on disk —
    /// usually because it was dragged to the Bin by hand after installing.
    /// Always false for formulae, which don't install into /Applications.
    let isOrphaned: Bool

    var id: String { "\(kind.rawValue):\(token)" }

    var isUpToDate: Bool {
        guard let latestVersion else { return true }
        return latestVersion == installedVersion
    }
}

// MARK: - Outdated

struct OutdatedPackage: Identifiable, Sendable, Hashable {
    let token: String
    let kind: PackageKind
    let installedVersions: [String]
    let currentVersion: String
    let pinned: Bool
    let pinnedVersion: String?

    var id: String { "\(kind.rawValue):\(token)" }
    var installedVersionText: String { installedVersions.joined(separator: ", ") }
}

// MARK: - Catalog (everything brew knows about, from formulae.brew.sh)

struct CatalogEntry: Identifiable, Sendable, Hashable, Codable {
    let token: String
    let name: String
    let kind: PackageKind
    let desc: String?
    let homepage: String?
    let version: String
    let tap: String?
    let license: String?
    let deprecated: Bool
    let disabled: Bool
    let dependencies: [String]
    let caveats: String?
    let appNames: [String]
    /// The cask keeps itself up to date, which makes `--adopt` skip its version check.
    let autoUpdates: Bool
    /// Bundle identifiers the cask names in its uninstall/zap stanzas. Not every
    /// cask declares one, but when it does it confirms an app-name match.
    let bundleIDs: [String]
    var installs30d: Int

    var id: String { "\(kind.rawValue):\(token)" }

    /// Lowercased haystack used for substring search, built once at decode time.
    var searchHaystack: String {
        var s = token.lowercased()
        if name.lowercased() != s { s += " " + name.lowercased() }
        if let desc { s += " " + desc.lowercased() }
        for app in appNames { s += " " + app.lowercased() }
        return s
    }
}

/// The slim on-disk cache we persist so relaunches don't re-download 7 MB.
struct CatalogCache: Codable, Sendable {
    /// Bumped whenever `CatalogEntry` gains a field, so an older cache is
    /// discarded and refetched rather than failing to decode.
    static let currentSchema = 2

    var schemaVersion: Int = CatalogCache.currentSchema
    var fetchedAt: Date
    var entries: [CatalogEntry]
}

// MARK: - Adoption

/// An app bundle found on disk, with what its Info.plist says about it.
struct InstalledApp: Identifiable, Sendable, Hashable {
    let path: String
    let fileName: String        // "1Password.app"
    let displayName: String     // "1Password"
    let bundleID: String?
    let shortVersion: String?
    let bundleVersion: String?
    /// Bought or downloaded from the Mac App Store, which keeps updating it itself.
    let isMacAppStore: Bool
    let isAppleSystemApp: Bool

    var id: String { path }
}

enum AdoptionReadiness: Sendable, Hashable {
    /// `brew install --cask --adopt` should succeed as-is.
    case ready
    /// The cask ships a different version and doesn't self-update, so brew will
    /// refuse to adopt — safely, leaving your copy alone.
    case versionMismatch
    /// Installed from the App Store, which will keep updating it behind brew's back.
    case appStore

    var title: String {
        switch self {
        case .ready: "Ready to adopt"
        case .versionMismatch: "Version differs"
        case .appStore: "From the App Store"
        }
    }
}

/// An app on disk paired with the cask that would manage it.
struct AdoptionCandidate: Identifiable, Sendable, Hashable {
    let app: InstalledApp
    let cask: CatalogEntry
    let readiness: AdoptionReadiness
    /// The cask names this app's bundle identifier, so the match is not just a
    /// coincidence of file names.
    let bundleIDConfirmed: Bool

    var id: String { app.path }
    var canAdopt: Bool { readiness == .ready }
}

// MARK: - Maintenance

struct DoctorReport: Sendable {
    var isHealthy: Bool
    var output: String
}

struct CleanupPreview: Sendable {
    var reclaimableBytes: Int64
    var output: String
}

// MARK: - Errors

struct BrewError: LocalizedError, Sendable {
    let message: String
    var underlyingOutput: String?
    var errorDescription: String? { message }
}
