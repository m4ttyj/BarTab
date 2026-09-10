import Foundation

/// Finds application bundles that Homebrew doesn't already manage.
///
/// Only the directories casks actually install into are scanned — a cask's `app`
/// artifact targets `/Applications` or `~/Applications` and nowhere else — so a
/// full-disk crawl would add noise, not candidates.
struct AppScanner: Sendable {
    static let searchPaths: [String] = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    func scan() async -> [InstalledApp] {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var apps: [InstalledApp] = []
            var seen = Set<String>()

            for root in Self.searchPaths {
                guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for entry in entries where entry.hasSuffix(".app") {
                    let path = root + "/" + entry
                    // A symlinked app is the same bundle by another name.
                    let resolved = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? path
                    guard seen.insert(resolved).inserted else { continue }
                    if let app = Self.read(path: path, fileName: entry) {
                        apps.append(app)
                    }
                }
            }
            return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }.value
    }

    private static func read(path: String, fileName: String) -> InstalledApp? {
        let plistPath = path + "/Contents/Info.plist"
        let info: [String: Any]
        if let data = FileManager.default.contents(atPath: plistPath),
           let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            info = parsed
        } else {
            info = [:]
        }

        let bundleID = (info["CFBundleIdentifier"] as? String)?.nilIfBlank
        let masReceipt = FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")

        return InstalledApp(
            path: path,
            fileName: fileName,
            displayName: String(fileName.dropLast(4)),
            bundleID: bundleID,
            shortVersion: (info["CFBundleShortVersionString"] as? String)?.nilIfBlank,
            bundleVersion: (info["CFBundleVersion"] as? String)?.nilIfBlank,
            isMacAppStore: masReceipt,
            isAppleSystemApp: bundleID?.hasPrefix("com.apple.") ?? false
        )
    }
}

// MARK: - Matching

enum AdoptionMatcher {
    /// Pairs each scanned app with the cask that installs an app of that name.
    ///
    /// - Parameters:
    ///   - index: cask app-artifact file name → casks installing it
    ///   - installedCaskTokens: casks brew already manages, which are not candidates
    static func candidates(
        apps: [InstalledApp],
        index: [String: [CatalogEntry]],
        installedCaskTokens: Set<String>
    ) -> [AdoptionCandidate] {
        apps.compactMap { app in
            guard !app.isAppleSystemApp else { return nil }
            guard let matches = index[app.fileName], !matches.isEmpty else { return nil }
            let usable = matches.filter { !installedCaskTokens.contains($0.token) && !$0.disabled }
            guard let cask = bestCask(for: app, among: usable) else { return nil }

            let confirmed = confirmsBundleID(cask: cask, app: app)
            return AdoptionCandidate(
                app: app,
                cask: cask,
                readiness: readiness(app: app, cask: cask),
                bundleIDConfirmed: confirmed
            )
        }
    }

    /// An app name can match several casks (`1password`, `1password@beta`,
    /// `1password@nightly`). Prefer a confirmed bundle ID, then a version match,
    /// then the plain unsuffixed token, then whichever is more popular.
    static func bestCask(for app: InstalledApp, among casks: [CatalogEntry]) -> CatalogEntry? {
        casks.max { lhs, rhs in
            score(lhs, app) < score(rhs, app)
        }
    }

    private static func score(_ cask: CatalogEntry, _ app: InstalledApp) -> Int {
        var score = 0
        if confirmsBundleID(cask: cask, app: app) { score += 1000 }
        if versionsAgree(app: app, cask: cask) { score += 500 }
        if !cask.token.contains("@") { score += 250 }
        score += min(cask.installs30d, 249)
        return score
    }

    static func confirmsBundleID(cask: CatalogEntry, app: InstalledApp) -> Bool {
        guard let bundleID = app.bundleID, !cask.bundleIDs.isEmpty else { return false }
        return cask.bundleIDs.contains(bundleID)
    }

    /// Cask versions are often `short,build` (`3.2.2,2896`); the part before the
    /// comma is what shows up as CFBundleShortVersionString.
    static func versionsAgree(app: InstalledApp, cask: CatalogEntry) -> Bool {
        let caskShort = cask.version.split(separator: ",").first.map(String.init) ?? cask.version
        guard let installed = app.shortVersion ?? app.bundleVersion else { return false }
        return caskShort.compare(installed, options: [.caseInsensitive]) == .orderedSame
    }

    /// Mirrors what `Cask::Artifact::Moved#move` actually does with `adopt:`:
    /// when the cask self-updates it adopts unconditionally, otherwise it compares
    /// Info.plist versions and refuses if they differ.
    static func readiness(app: InstalledApp, cask: CatalogEntry) -> AdoptionReadiness {
        if app.isMacAppStore { return .appStore }
        if cask.autoUpdates { return .ready }
        return versionsAgree(app: app, cask: cask) ? .ready : .versionMismatch
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
