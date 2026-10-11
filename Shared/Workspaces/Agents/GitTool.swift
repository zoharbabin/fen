import Foundation

/// Runs the `git` program for agent branches (issue #93). Only the agent-branch code uses it,
/// and only plumbing commands: they read objects, write objects and move one ref. None of them
/// touches your working tree, your index or your current branch, and none runs a hook.
///
/// Fen looks for git in fixed places and never asks `/usr/bin/git`. On a Mac without developer
/// tools that shim opens an install prompt.
struct GitTool: Sendable {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: String

        var succeeded: Bool {
            status == 0
        }

        var text: String {
            String(data: stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    static let candidates = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
    ]

    /// Options that stop a repository's own configuration from running programs.
    private static let safety = [
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "commit.gpgsign=false",
        "-c", "gc.auto=0",
    ]

    let executable: URL

    static func locate() -> GitTool? {
        #if os(macOS)
            (candidates + [selectedDeveloperGit()].compactMap(\.self))
                .first { FileManager.default.isExecutableFile(atPath: $0) }
                .map { GitTool(executable: URL(fileURLWithPath: $0)) }
        #else
            nil
        #endif
    }

    /// The git of the developer directory `xcode-select` points to, read from its link so no program runs.
    private static func selectedDeveloperGit() -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
            .appending("/usr/bin/git")
    }

    /// Runs git in `directory`. `environment` adds to a small fixed environment. Nothing from
    /// Fen's own environment passes through, so a stray `GIT_DIR` can't redirect a command.
    func run(
        _ arguments: [String],
        in directory: URL,
        input: Data? = nil,
        environment: [String: String] = [:]
    ) async throws -> Output {
        #if os(macOS)
            let process = Process()
            process.executableURL = executable
            process.arguments = Self.safety + arguments
            process.currentDirectoryURL = directory
            var env = [
                "PATH": "/usr/bin:/bin",
                "HOME": NSHomeDirectory(),
                "LC_ALL": "C",
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_OPTIONAL_LOCKS": "0",
            ]
            env.merge(environment) { $1 }
            process.environment = env

            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe

            return try await withCheckedThrowingContinuation { continuation in
                // Read both pipes while the process runs, or a full pipe stops it.
                let group = DispatchGroup()
                let collected = Collected()
                group.enter()
                DispatchQueue.global().async {
                    collected.setOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    collected.setErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                process.terminationHandler = { finished in
                    group.notify(queue: .global()) {
                        continuation.resume(returning: Output(
                            status: finished.terminationStatus,
                            stdout: collected.out,
                            stderr: String(decoding: collected.err, as: UTF8.self)
                        ))
                    }
                }
                do {
                    try process.run()
                } catch {
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                    return
                }
                let writer = inPipe.fileHandleForWriting
                DispatchQueue.global().async {
                    if let input {
                        try? writer.write(contentsOf: input)
                    }
                    try? writer.close()
                }
            }

        #else
            throw CocoaError(.featureUnsupported)
        #endif
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data(), errData = Data()

        var out: Data {
            lock.withLock { outData }
        }

        var err: Data {
            lock.withLock { errData }
        }

        func setOut(_ data: Data) {
            lock.withLock { outData = data }
        }

        func setErr(_ data: Data) {
            lock.withLock { errData = data }
        }
    }
}
