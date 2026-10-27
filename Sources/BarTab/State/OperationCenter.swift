import AppKit
import Foundation
import Observation

enum OperationStatus: Sendable, Equatable {
    case queued
    case running
    case succeeded
    case failed(Int32)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .queued, .running: false
        case .succeeded, .failed, .cancelled: true
        }
    }
}

@Observable
final class BrewOperation: Identifiable {
    let id = UUID()
    let title: String
    let arguments: [String]
    /// Set when the operation mutates the local install, so the model knows to reload.
    let invalidatesLocalState: Bool

    var status: OperationStatus = .queued
    var log: [String] = []
    var startedAt: Date?
    var finishedAt: Date?
    /// brew asked for a password; we can't answer that from a GUI.
    var needsTerminal = false
    /// brew hit the App Management permission wall.
    var needsAppManagement = false

    fileprivate let handle = CommandHandle()
    private static let maxLogLines = 4000

    init(title: String, arguments: [String], invalidatesLocalState: Bool = true) {
        self.title = title
        self.arguments = arguments
        self.invalidatesLocalState = invalidatesLocalState
    }

    var commandLine: String { (["brew"] + arguments).joined(separator: " ") }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    func append(_ line: String) {
        log.append(line)
        if log.count > Self.maxLogLines {
            log.removeFirst(log.count - Self.maxLogLines)
        }
        if line.contains("Password:") || line.contains("a password is required")
            || line.contains("sudo: no askpass program") || line.lowercased().contains("sudo access") {
            needsTerminal = true
        }
        if AppManagementPermission.looksLikeFailure(line) {
            needsAppManagement = true
        }
    }

    func cancel() {
        handle.cancel()
    }
}

/// Runs brew operations strictly one at a time — Homebrew takes a global lock, so
/// firing two installs at once just produces a confusing failure.
@MainActor
@Observable
final class OperationCenter {
    private(set) var operations: [BrewOperation] = []
    private(set) var current: BrewOperation?
    var selectedOperationID: BrewOperation.ID?

    /// Called on the main actor as each operation finishes, whatever its outcome.
    /// The model decides what to do with it — reload state, stamp a timestamp.
    /// Main-actor isolated: `BrewOperation` is an observable reference type that
    /// never leaves this actor, and an unannotated closure would be `@concurrent`.
    var onOperationFinished: (@MainActor (BrewOperation) async -> Void)?

    private var env: BrewEnvironment?
    private var pumping = false

    func configure(env: BrewEnvironment) {
        self.env = env
    }

    var pendingCount: Int {
        operations.filter { !$0.status.isTerminal }.count
    }

    var isBusy: Bool { current != nil }

    @discardableResult
    func enqueue(title: String, arguments: [String], invalidatesLocalState: Bool = true) -> BrewOperation {
        let operation = BrewOperation(
            title: title, arguments: arguments, invalidatesLocalState: invalidatesLocalState
        )
        operations.insert(operation, at: 0)
        selectedOperationID = operation.id
        Task { await pump() }
        return operation
    }

    func clearFinished() {
        operations.removeAll { $0.status.isTerminal }
    }

    private func pump() async {
        guard !pumping, let env else { return }
        pumping = true
        defer { pumping = false }

        // Oldest queued first; `operations` is newest-first for display.
        while let next = operations.last(where: { $0.status == .queued }) {
            current = next
            next.status = .running
            next.startedAt = Date()

            let runner = env.runner
            let stream = runner.stream(next.arguments, handle: next.handle)
            var exitStatus: Int32 = 0
            var launchFailed = false

            for await event in stream {
                switch event {
                case .line(let text):
                    next.append(text)
                case .finished(let status):
                    exitStatus = status
                case .failedToLaunch(let message):
                    next.append("Failed to launch brew: \(message)")
                    launchFailed = true
                }
            }

            next.finishedAt = Date()
            if launchFailed {
                next.status = .failed(-1)
            } else if next.handle.isCancelled {
                next.status = .cancelled
                next.append("— cancelled —")
            } else if exitStatus == 0 {
                next.status = .succeeded
            } else {
                next.status = .failed(exitStatus)
            }

            current = nil

            await onOperationFinished?(next)
        }
    }

    // MARK: - Terminal escape hatch

    /// Opens the command in Terminal.app. Needed for the handful of casks whose
    /// installers require sudo, which a GUI can't supply.
    func openInTerminal(_ operation: BrewOperation) {
        guard let env else { return }
        Self.openInTerminal(brew: env.brewURL, arguments: operation.arguments)
    }

    static func openInTerminal(brew: URL, arguments: [String]) {
        let command = ([brew.path] + arguments).map(shellQuote).joined(separator: " ")
        let script = """
            #!/bin/bash
            echo "Running: \(command)"
            \(command)
            status=$?
            echo
            echo "Finished with exit code $status. You can close this window."

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bartab-\(UUID().uuidString.prefix(8)).command")
        guard let data = script.data(using: .utf8) else { return }
        try? data.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    private static func shellQuote(_ value: String) -> String {
        guard value.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=@:+")).inverted) != nil else {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
