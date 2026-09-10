import Foundation

/// Where brew lives and what environment we hand its subprocesses.
///
/// A GUI app launched from Finder inherits almost nothing from the user's shell,
/// so we reconstruct a usable PATH rather than relying on the inherited one.
struct BrewEnvironment: Sendable {
    let brewURL: URL
    let prefix: URL

    var cellarURL: URL { prefix.appendingPathComponent("Cellar") }
    var caskroomURL: URL { prefix.appendingPathComponent("Caskroom") }

    static let candidatePaths = [
        "/opt/homebrew/bin/brew",   // Apple silicon
        "/usr/local/bin/brew",      // Intel
    ]

    /// Locates brew, or throws with something the user can act on.
    static func discover() throws -> BrewEnvironment {
        let fm = FileManager.default
        var brewPath: String?

        for candidate in candidatePaths where fm.isExecutableFile(atPath: candidate) {
            brewPath = candidate
            break
        }

        // Fall back to a login shell in case brew is somewhere unusual.
        if brewPath == nil, let found = try? loginShellWhichBrew(), fm.isExecutableFile(atPath: found) {
            brewPath = found
        }

        guard let brewPath else {
            throw BrewError(message: """
                Homebrew wasn't found. Looked in \(candidatePaths.joined(separator: ", ")) \
                and asked your login shell. Install it from https://brew.sh and reopen this app.
                """)
        }

        let brewURL = URL(fileURLWithPath: brewPath)
        // <prefix>/bin/brew -> <prefix>
        let prefix = brewURL.deletingLastPathComponent().deletingLastPathComponent()
        return BrewEnvironment(brewURL: brewURL, prefix: prefix)
    }

    private static func loginShellWhichBrew() throws -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let runner = CommandRunner(
            executableURL: URL(fileURLWithPath: shell),
            environment: ProcessInfo.processInfo.environment
        )
        // Synchronous bridge: discovery happens before any UI is drawn.
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: String?
        Task.detached {
            if let output = try? await runner.capture(["-lc", "command -v brew"]) {
                result = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return (result?.isEmpty == false) ? result : nil
    }

    /// Environment for `brew` subprocesses: predictable, quiet, machine-readable.
    var childEnvironment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]

        // Carry over the handful of variables brew and git actually need.
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL", "SSH_AUTH_SOCK",
                    "HOMEBREW_GITHUB_API_TOKEN", "GITHUB_TOKEN", "http_proxy", "https_proxy",
                    "HTTP_PROXY", "HTTPS_PROXY", "no_proxy", "NO_PROXY"] {
            if let value = inherited[key] { env[key] = value }
        }

        env["PATH"] = [
            prefix.appendingPathComponent("bin").path,
            prefix.appendingPathComponent("sbin").path,
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")

        env["HOMEBREW_NO_COLOR"] = "1"
        env["HOMEBREW_NO_EMOJI"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        // We drive `brew update` explicitly from the Maintenance tab; implicit
        // updates in the middle of an install make progress impossible to report.
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        // brew refuses to prompt for a password when it can't reach a TTY; make that
        // failure fast and legible instead of a hung process.
        env["SUDO_ASKPASS"] = "/usr/bin/false"
        return env
    }

    var runner: CommandRunner {
        CommandRunner(executableURL: brewURL, environment: childEnvironment)
    }

    /// Runner for a non-brew helper (currently just `du` for on-disk sizes).
    func runner(for executable: String) -> CommandRunner {
        CommandRunner(executableURL: URL(fileURLWithPath: executable), environment: childEnvironment)
    }
}
