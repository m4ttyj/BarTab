import Foundation

// MARK: - Results & events

struct CommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    var succeeded: Bool { status == 0 }
}

enum CommandEvent: Sendable {
    case line(String)
    case finished(status: Int32)
    case failedToLaunch(String)
}

/// Handle for a running streamed command so the UI can cancel it.
final class CommandHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            process.terminate()
        } else {
            self.process = process
        }
    }

    func cancel() {
        lock.lock()
        let p = process
        cancelled = true
        lock.unlock()
        p?.terminate()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Mutable state shared with reader threads; guarded by a lock.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - Runner

/// Runs an external executable. Reads stdout and stderr on their own threads so a
/// command that writes megabytes of JSON (`brew info --json=v2`) can't deadlock on
/// a full pipe buffer.
struct CommandRunner: Sendable {
    let executableURL: URL
    let environment: [String: String]
    let currentDirectory: URL?

    init(executableURL: URL, environment: [String: String], currentDirectory: URL? = nil) {
        self.executableURL = executableURL
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    // MARK: Capture

    func capture(_ arguments: [String]) async throws -> CommandResult {
        let exe = executableURL
        let env = environment
        let cwd = currentDirectory
        return try await Task.detached(priority: .userInitiated) {
            try Self.captureSync(exe, arguments, env, cwd)
        }.value
    }

    private static func captureSync(
        _ exe: URL, _ arguments: [String], _ env: [String: String], _ cwd: URL?
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = exe
        process.arguments = arguments
        process.environment = env
        if let cwd { process.currentDirectoryURL = cwd }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw BrewError(message: "Couldn't run \(exe.path): \(error.localizedDescription)")
        }

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "brewui.capture", attributes: .concurrent)

        for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
            group.enter()
            queue.async {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    box.append(chunk)
                }
                group.leave()
            }
        }

        group.wait()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: outBox.value, stderr: errBox.value)
    }

    // MARK: Stream

    /// Streams merged stdout/stderr line by line. `\r` is treated as a line break so
    /// brew's download progress bars surface as they update.
    func stream(_ arguments: [String], handle: CommandHandle) -> AsyncStream<CommandEvent> {
        let exe = executableURL
        let env = environment
        let cwd = currentDirectory

        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let thread = Thread {
                let process = Process()
                process.executableURL = exe
                process.arguments = arguments
                process.environment = env
                if let cwd { process.currentDirectoryURL = cwd }

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.yield(.failedToLaunch(error.localizedDescription))
                    continuation.finish()
                    return
                }
                handle.attach(process)

                var buffer = Data()
                let reader = pipe.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        let lineData = buffer[buffer.startIndex..<index]
                        buffer.removeSubrange(buffer.startIndex...index)
                        let text = String(decoding: lineData, as: UTF8.self)
                        continuation.yield(.line(ANSI.strip(text)))
                    }
                }
                if !buffer.isEmpty {
                    continuation.yield(.line(ANSI.strip(String(decoding: buffer, as: UTF8.self))))
                }

                process.waitUntilExit()
                continuation.yield(.finished(status: process.terminationStatus))
                continuation.finish()
            }
            thread.name = "brewui.stream"
            thread.stackSize = 512 * 1024
            thread.start()

            continuation.onTermination = { reason in
                if case .cancelled = reason { handle.cancel() }
            }
        }
    }
}

// MARK: - ANSI

enum ANSI {
    /// brew still emits a few escape sequences even with HOMEBREW_NO_COLOR set.
    static func strip(_ input: String) -> String {
        guard input.contains("\u{1B}") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        var iterator = input.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\u{1B}" else {
                out.append(ch)
                continue
            }
            // Skip "[ ... <final byte in @-~>" or a single-character sequence.
            guard let next = iterator.next() else { break }
            if next == "[" {
                while let c = iterator.next() {
                    if ("@"..."~").contains(c) { break }
                }
            }
        }
        return out
    }
}
