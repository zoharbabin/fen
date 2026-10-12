import CryptoKit
import Foundation

/// A model file Fen can fetch or import (issue #4). `sha256` and `byteCount` come from Fen, not
/// from the server, so a swapped or cut-off file is rejected.
public struct ModelDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let url: URL
    /// Lowercase hex.
    public let sha256: String
    public let byteCount: Int64
    /// A plain file name inside `~/.fen/models`. No folders.
    public let fileName: String
    /// The license of these exact weights. A copy lives under `LICENSE/`.
    public let licenseName: String

    public init(
        id: String,
        displayName: String,
        url: URL,
        sha256: String,
        byteCount: Int64,
        fileName: String,
        licenseName: String
    ) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
        self.fileName = fileName
        self.licenseName = licenseName
    }

    public var host: String {
        url.host(percentEncoded: false) ?? ""
    }

    /// The sentence the confirmation dialog shows before a download starts.
    public var consentText: String {
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        return "Download \(displayName) (\(size)) from \(host)?"
    }
}

public enum ModelError: Error, Equatable, LocalizedError {
    case invalidFileName
    case insecureURL
    /// The caller did not confirm the host and size the descriptor names.
    case consentMismatch
    case http(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidFileName: "The model file name is not valid."
        case .insecureURL: "Models download over https only."
        case .consentMismatch: "The download was not confirmed for this host and size."
        case let .http(status): "The download server answered with HTTP \(status)."
        case let .sizeMismatch(expected, actual): "The file is \(actual) bytes. Expected \(expected)."
        case .checksumMismatch: "The file does not match its checksum. It was not installed."
        }
    }
}

/// Model weights on disk, in `~/.fen/models` (issues #4, #9). The only way weights arrive is a
/// download you confirmed by host and size, or a file you pick. Both are checked against the
/// descriptor's size and SHA-256 before they are moved into place.
public struct ModelStore: Sendable {
    private let home: FenHome
    private let session: URLSession

    public init(home: FenHome) {
        self.init(home: home, session: Self.makeSession())
    }

    init(home: FenHome, session: URLSession) {
        self.home = home
        self.session = session
    }

    /// Follows redirects (model hosts hand off to a CDN) but never to plain `http`.
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
    }

    private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
        }
    }

    // MARK: - Location

    public func fileURL(for model: ModelDescriptor) throws -> URL {
        let name = model.fileName
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw ModelError.invalidFileName
        }
        return home.modelsDirectory.appendingPathComponent(name)
    }

    /// `true` when the file exists at the expected size. It was hashed when it was installed.
    public func isInstalled(_ model: ModelDescriptor) -> Bool {
        guard let url = try? fileURL(for: model),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else {
            return false
        }
        return size == model.byteCount
    }

    public func remove(_ model: ModelDescriptor) throws {
        let url = try fileURL(for: model)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Download

    /// Downloads and installs `model`. `confirmedHost` and `confirmedBytes` are what the user saw
    /// in the confirmation, and must match the descriptor. Cancel the task to stop.
    @discardableResult
    public func download(
        _ model: ModelDescriptor,
        confirmedHost: String,
        confirmedBytes: Int64,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> URL {
        let destination = try fileURL(for: model)
        guard confirmedHost == model.host, confirmedBytes == model.byteCount else { throw ModelError.consentMismatch }
        let scheme = model.url.scheme?.lowercased()
        let isLoopbackHTTP = scheme == "http" && AIEndpoint.isLoopback(host: model.host)
        guard scheme == "https" || isLoopbackHTTP else { throw ModelError.insecureURL }

        let (temporary, response) = try await session.download(
            for: URLRequest(url: model.url),
            delegate: ProgressDelegate(progress)
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw ModelError.http(http.statusCode)
        }
        try Task.checkCancellation()
        return try install(temporary, as: model, at: destination, move: true)
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let report: @Sendable (Int64) -> Void

        init(_ report: @escaping @Sendable (Int64) -> Void) {
            self.report = report
        }

        func urlSession(
            _: URLSession,
            downloadTask _: URLSessionDownloadTask,
            didWriteData _: Int64,
            totalBytesWritten written: Int64,
            totalBytesExpectedToWrite _: Int64
        ) {
            report(written)
        }

        func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
    }

    // MARK: - Import

    /// Installs a model file you picked. Same checks as a download.
    @discardableResult
    public func importFile(_ source: URL, as model: ModelDescriptor) throws -> URL {
        try install(source, as: model, at: fileURL(for: model), move: false)
    }

    // MARK: - Install

    /// Copies (or moves) to a partial file beside the destination, checks it there, then renames.
    /// A failed check leaves nothing behind.
    private func install(_ source: URL, as model: ModelDescriptor, at destination: URL, move: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: home.modelsDirectory, withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        if move {
            try FileManager.default.moveItem(at: source, to: partial)
        } else {
            try FileManager.default.copyItem(at: source, to: partial)
        }
        do {
            let size = try (FileManager.default.attributesOfItem(atPath: partial.path))[.size] as? Int64 ?? -1
            guard size == model.byteCount else {
                throw ModelError.sizeMismatch(expected: model.byteCount, actual: size)
            }
            guard try Self.sha256(of: partial) == model.sha256 else { throw ModelError.checksumMismatch }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Hex SHA-256, read in 1 MB pieces so a multi-gigabyte model never sits in memory.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
