import Foundation

/// Read-only queries against the local Homebrew installation.
struct BrewService: Sendable {
    let env: BrewEnvironment

    private var runner: CommandRunner { env.runner }

    // MARK: - Installed

    func installedPackages() async throws -> [InstalledPackage] {
        let result = try await runner.capture(["info", "--json=v2", "--installed"])
        guard result.succeeded else {
            throw BrewError(
                message: "`brew info --installed` failed (exit \(result.status)).",
                underlyingOutput: result.stderrText
            )
        }
        let data = result.stdout
        return try await Task.detached(priority: .userInitiated) {
            try Self.parseInstalled(data)
        }.value
    }

    private static func parseInstalled(_ data: Data) throws -> [InstalledPackage] {
        let root = try JSONValue.parse(data)
        var packages: [InstalledPackage] = []

        for item in root["formulae"].array {
            guard let token = item["full_name"].string ?? item["name"].string else { continue }
            // A formula can have several kegs installed; the last is the newest.
            let kegs = item["installed"].array
            guard let keg = kegs.last else { continue }
            let version = keg["version"].string ?? "?"
            let latest = item["versions"]["stable"].string
            let revision = item["revision"].int ?? 0
            let latestWithRevision = (revision > 0 && latest != nil) ? "\(latest!)_\(revision)" : latest

            packages.append(InstalledPackage(
                token: token,
                name: item["name"].string ?? token,
                kind: .formula,
                desc: item["desc"].nonEmptyString,
                homepage: item["homepage"].nonEmptyString,
                installedVersion: version,
                latestVersion: latestWithRevision,
                tap: item["tap"].nonEmptyString,
                license: item["license"].nonEmptyString,
                installedOnRequest: keg["installed_on_request"].bool,
                installedAt: keg["time"].double.map { Date(timeIntervalSince1970: $0) },
                dependencies: item["dependencies"].stringArray,
                buildDependencies: item["build_dependencies"].stringArray,
                caveats: item["caveats"].nonEmptyString,
                pinned: item["pinned"].bool,
                deprecated: item["deprecated"].bool,
                deprecationReason: item["deprecation_reason"].nonEmptyString,
                kegOnly: item["keg_only"].bool,
                outdated: item["outdated"].bool,
                appNames: []
            ))
        }

        for item in root["casks"].array {
            guard let token = item["full_token"].string ?? item["token"].string else { continue }
            guard let version = item["installed"].string else { continue }
            packages.append(InstalledPackage(
                token: token,
                name: item["name"].stringArray.first ?? token,
                kind: .cask,
                desc: item["desc"].nonEmptyString,
                homepage: item["homepage"].nonEmptyString,
                installedVersion: version,
                latestVersion: item["version"].nonEmptyString,
                tap: item["tap"].nonEmptyString,
                license: nil,
                installedOnRequest: true, // casks are never pulled in as dependencies
                installedAt: item["installed_time"].double.map { Date(timeIntervalSince1970: $0) },
                dependencies: caskFormulaDependencies(item),
                buildDependencies: [],
                caveats: item["caveats"].nonEmptyString,
                pinned: item["pinned"].bool,
                deprecated: item["deprecated"].bool,
                deprecationReason: item["deprecation_reason"].nonEmptyString,
                kegOnly: false,
                outdated: item["outdated"].bool,
                appNames: caskAppNames(item)
            ))
        }

        return packages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Cask `artifacts` is an array of single-key objects. Collect every file name
    /// the cask could end up installing: the `app` entries plus any explicit
    /// `target`, which is what a cask that renames the bundle actually lands as.
    static func caskAppNames(_ item: JSONValue) -> [String] {
        var names: Set<String> = []
        for artifact in item["artifacts"].array {
            for app in artifact["app"].array {
                if let name = app.string {
                    names.insert((name as NSString).lastPathComponent)
                }
                if let target = app["target"].string {
                    names.insert((target as NSString).lastPathComponent)
                }
            }
            if let target = artifact["target"].string, target.hasSuffix(".app") {
                names.insert((target as NSString).lastPathComponent)
            }
        }
        return Array(names)
    }

    /// Bundle identifiers a cask names in its uninstall/zap stanzas. `quit` is the
    /// app's own identifier; `launchctl` entries are usually helpers, but an exact
    /// match against the app is still confirmation.
    static func caskBundleIDs(_ item: JSONValue) -> [String] {
        var ids: Set<String> = []
        for artifact in item["artifacts"].array {
            for stanza in artifact["uninstall"].array + artifact["zap"].array {
                for key in ["quit", "launchctl", "login_item"] {
                    if let single = stanza[key].string {
                        ids.insert(single)
                    }
                    ids.formUnion(stanza[key].stringArray)
                }
            }
        }
        return Array(ids)
    }

    static func caskFormulaDependencies(_ item: JSONValue) -> [String] {
        let dependsOn = item["depends_on"]
        return dependsOn["formula"].stringArray + dependsOn["cask"].stringArray
    }

    // MARK: - Outdated

    /// `greedy` also reports casks that update themselves (Chrome, Slack…), which
    /// brew hides by default because they're rarely actionable.
    func outdatedPackages(greedy: Bool = false) async throws -> [OutdatedPackage] {
        var arguments = ["outdated", "--json=v2"]
        if greedy { arguments.append("--greedy") }
        let result = try await runner.capture(arguments)
        guard result.succeeded else {
            throw BrewError(
                message: "`brew outdated` failed (exit \(result.status)).",
                underlyingOutput: result.stderrText
            )
        }
        let root = try JSONValue.parse(result.stdout)

        var items: [OutdatedPackage] = []
        for entry in root["formulae"].array {
            guard let name = entry["name"].string else { continue }
            items.append(OutdatedPackage(
                token: name,
                kind: .formula,
                installedVersions: entry["installed_versions"].stringArray,
                currentVersion: entry["current_version"].string ?? "?",
                pinned: entry["pinned"].bool,
                pinnedVersion: entry["pinned_version"].nonEmptyString
            ))
        }
        for entry in root["casks"].array {
            guard let name = entry["name"].string else { continue }
            items.append(OutdatedPackage(
                token: name,
                kind: .cask,
                installedVersions: entry["installed_versions"].stringArray,
                currentVersion: entry["current_version"].string ?? "?",
                pinned: false,
                pinnedVersion: nil
            ))
        }
        return items.sorted { $0.token.localizedCaseInsensitiveCompare($1.token) == .orderedAscending }
    }

    // MARK: - Sizes

    /// On-disk size per package, keyed by `PackageKind` + token.
    /// One `du` pass over Cellar and Caskroom beats 90 recursive FileManager walks.
    func diskUsage() async -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        let du = env.runner(for: "/usr/bin/du")

        for (root, kind) in [(env.cellarURL, PackageKind.formula), (env.caskroomURL, PackageKind.cask)] {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            // Every cask install ends with `ln_sf target, source`, so the Caskroom
            // holds a symlink to the app in /Applications rather than the app
            // itself. Without -L every cask measures a few kilobytes.
            var arguments = ["-k", "-d", "1"]
            if kind == .cask { arguments.append("-L") }
            arguments.append(root.path)
            guard let result = try? await du.capture(arguments), result.succeeded else { continue }
            for line in result.stdoutText.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
                let path = String(parts[1])
                guard path != root.path else { continue }  // the roll-up line
                let token = (path as NSString).lastPathComponent
                sizes["\(kind.rawValue):\(token)"] = kb * 1024
            }
        }
        return sizes
    }

    // MARK: - Detail lookups

    /// Installed packages that depend on `token` — i.e. what breaks if you remove it.
    func dependents(of token: String) async -> [String] {
        guard let result = try? await runner.capture(["uses", "--installed", token]),
              result.succeeded else { return [] }
        return result.stdoutText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .sorted()
    }

    /// Full recursive dependency list for a not-yet-installed formula.
    func dependencies(of token: String, kind: PackageKind) async -> [String] {
        guard kind == .formula else { return [] }
        guard let result = try? await runner.capture(["deps", "--formula", token]), result.succeeded else { return [] }
        return result.stdoutText.split(separator: "\n").map(String.init)
    }

    // MARK: - Maintenance

    func doctor() async -> DoctorReport {
        let result = try? await runner.capture(["doctor"])
        guard let result else {
            return DoctorReport(isHealthy: false, output: "Couldn't run `brew doctor`.")
        }
        let combined = (result.stdoutText + result.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
        return DoctorReport(isHealthy: result.succeeded, output: ANSI.strip(combined))
    }

    func cleanupPreview() async -> CleanupPreview {
        let result = try? await runner.capture(["cleanup", "--dry-run"])
        guard let result else {
            return CleanupPreview(reclaimableBytes: 0, output: "Couldn't run `brew cleanup --dry-run`.")
        }
        let text = ANSI.strip(result.stdoutText + result.stderrText)
        return CleanupPreview(reclaimableBytes: Self.parseReclaimable(from: text), output: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// brew prints e.g. "This operation would free approximately 1.2GB of disk space."
    static func parseReclaimable(from text: String) -> Int64 {
        let pattern = #"free approximately ([0-9.]+)\s*([KMGT]?B)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[numberRange])
        else { return 0 }

        let multiplier: Double
        switch text[unitRange].uppercased() {
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        case "TB": multiplier = 1_000_000_000_000
        default: multiplier = 1
        }
        return Int64(value * multiplier)
    }

    func version() async -> String {
        guard let result = try? await runner.capture(["--version"]) else { return "unknown" }
        return result.stdoutText
            .split(separator: "\n").first
            .map { $0.replacingOccurrences(of: "Homebrew ", with: "") } ?? "unknown"
    }
}
