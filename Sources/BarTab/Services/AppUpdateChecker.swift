import Foundation

/// A published BarTab release on GitHub.
struct AppRelease: Sendable, Equatable {
    let version: String      // "1.2"
    let tag: String          // "v1.2"
    let url: URL
    let publishedAt: Date?
}

/// Checks GitHub for a newer BarTab than the one running.
///
/// BarTab ships as a Homebrew cask, so a brew-managed copy already learns about
/// its own updates through `brew outdated` once the tap has been refreshed. This
/// check exists for the cases that doesn't cover: a copy installed by unzipping
/// the release by hand, and knowing about a release before the tap catches up.
enum AppUpdateChecker {
    static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/m4ttyj/BarTab/releases/latest"
    )!

    static var runningVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Returns the newest published release, or nil if it isn't newer than the
    /// running build. Throws only on a genuine failure to ask.
    static func newerRelease(than current: String = runningVersion) async throws -> AppRelease? {
        let release = try await latestRelease()
        return isVersion(release.version, newerThan: current) ? release : nil
    }

    static func latestRelease() async throws -> AppRelease {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects API requests that don't identify themselves.
        request.setValue("BarTab/\(runningVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BrewError(message: "Couldn't reach GitHub.")
        }
        guard http.statusCode == 200 else {
            // 403 with the rate limit exhausted is the common unauthenticated case.
            let hint = http.statusCode == 403
                ? " GitHub's hourly limit for unauthenticated requests may be used up."
                : ""
            throw BrewError(message: "GitHub returned \(http.statusCode) when asked for the latest release.\(hint)")
        }

        let root = try JSONValue.parse(data)
        guard let tag = root["tag_name"].nonEmptyString,
              let link = root["html_url"].nonEmptyString,
              let url = URL(string: link)
        else {
            throw BrewError(message: "GitHub's response didn't contain a release.")
        }
        guard !root["draft"].bool, !root["prerelease"].bool else {
            throw BrewError(message: "The newest release is a draft or pre-release.")
        }

        return AppRelease(
            version: normalise(tag),
            tag: tag,
            url: url,
            publishedAt: root["published_at"].string.flatMap {
                ISO8601DateFormatter().date(from: $0)
            }
        )
    }

    // MARK: - Version comparison

    /// Compares component by component as numbers. A plain string comparison gets
    /// "1.10" versus "1.9" backwards, which is exactly the case that matters once
    /// a project reaches a tenth release.
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = parts(lhs), right = parts(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func normalise(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    private static func parts(_ version: String) -> [Int] {
        normalise(version)
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
