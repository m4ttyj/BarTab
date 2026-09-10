import AppKit
import Foundation

enum AppManagementStatus: Sendable, Equatable {
    case granted
    case denied
    /// No suitable app bundle to test against, so the answer is genuinely unknown.
    case unknown
}

/// macOS 13 and later put modifying *another* app's bundle behind the
/// "App Management" privacy permission.
///
/// Every cask operation that touches an installed app needs it — adopting,
/// upgrading, uninstalling — and because `brew` runs as a child of this app,
/// macOS attributes the attempt to BarTab rather than to brew. So the permission
/// has to be granted to BarTab; granting it to your terminal does nothing here.
///
/// There is no public API to query the permission, so we do what Homebrew does
/// in `Cask::Quarantine.app_management_permissions_granted?`: attempt a real
/// write inside an app bundle. The attempt is also what prompts macOS to ask.
enum AppManagementPermission {
    /// Privacy & Security → App Management. The anchor name comes from
    /// SecurityPrivacyExtension's TCCServiceList (kTCCServiceSystemPolicyAppBundles).
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
    )!

    /// Probes by creating and immediately removing a dot-file inside an app bundle.
    ///
    /// Candidates are tried in order and the first conclusive answer wins. A
    /// candidate is only conclusive when we own it and its write bit is set —
    /// otherwise a refusal says nothing about App Management, only about
    /// ordinary file permissions.
    static func probe(candidates: [URL]) async -> AppManagementStatus {
        let ownBundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let paths = candidates.map { $0.resolvingSymlinksInPath().path }

        return await Task.detached(priority: .userInitiated) {
            for path in paths {
                // An app may modify its own bundle without the permission, so
                // probing ourselves would report a false "granted".
                guard path != ownBundle else { continue }

                var info = stat()
                guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
                let ownedByUs = info.st_uid == getuid()
                let userWritable = (info.st_mode & S_IWUSR) != 0
                guard ownedByUs, userWritable else { continue }

                let probePath = path + "/.bartab-write-test"
                let descriptor = open(probePath, O_CREAT | O_WRONLY | O_EXCL, 0o600)
                if descriptor >= 0 {
                    close(descriptor)
                    unlink(probePath)
                    return .granted
                }

                // We own it and it's writable, so a refusal here is the sandboxing
                // of app bundles rather than a file-mode problem.
                if errno == EPERM || errno == EACCES { return .denied }
                // Anything else (a read-only volume, a stale path) proves nothing.
            }
            return .unknown
        }.value
    }

    /// App bundles in the places casks install to, found without needing the
    /// app scan to have finished. Keeps the probe usable from any call site at
    /// any point in startup.
    static func defaultCandidates() -> [URL] {
        let fm = FileManager.default
        return AppScanner.searchPaths.flatMap { root -> [URL] in
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
            return names.filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: root).appendingPathComponent($0) }
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// Recognises the failure in brew's output, for operations that ran before we
    /// had a chance to check. Homebrew's wording is "does not have App Management
    /// permissions"; matching the two words alone keeps this robust to rephrasing.
    static func looksLikeFailure(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("app management")
            || lowered.contains("ktccservicesystempolicyappbundles")
            || lowered.contains("operation not permitted") && lowered.contains(".app")
    }
}
