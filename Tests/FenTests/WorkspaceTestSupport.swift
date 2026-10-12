@testable import FenCore
import Foundation

/// A throwaway directory tree for workspace tests. Deleted on `cleanUp()`.
/// `root` is symlink-resolved, so assertions compare against what the gate returns.
final class TempFolder: @unchecked Sendable {
    let root: URL

    init(_ label: String = "workspace") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fen-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = PathGate.canonicalURL(of: base) ?? base
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func write(_ relativePath: String, _ text: String = "# Note\n") throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @discardableResult
    func writeBytes(_ relativePath: String, _ bytes: [UInt8]) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    @discardableResult
    func folder(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func symlink(_ relativePath: String, to target: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }
}

// MARK: - Real git

extension TempFolder {
    /// Runs the system `git` in this folder. Test setup only: the app never does this.
    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try git(arguments)
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
            + arguments
        process.currentDirectoryURL = root
        process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "HOME": root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    func initRepo(branch: String = "main") throws {
        try git("init", "-b", branch)
    }

    func commitAll(_ message: String = "commit") throws {
        try git("add", "-A")
        try git("commit", "-m", message)
    }
}
