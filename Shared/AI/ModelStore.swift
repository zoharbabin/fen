import CryptoKit
import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// What a downloaded model does, and how the runtime must treat it.
public enum ModelKind: String, Sendable, Equatable {
    /// Google's EmbeddingGemma 2. Needs the task prefixes in its model card.
    case embeddingGemma2
    /// Alibaba's Qwen3-Embedding. Its last-token pooling needs an end-of-text token on every input.
    case qwen3Embedding
    /// Google's Gemma 4 chat models.
    case gemma4
    /// A file with no special handling. Used by tests.
    case generic

    public var role: ModelRole {
        switch self {
        case .embeddingGemma2, .qwen3Embedding: .embedding
        case .gemma4, .generic: .answer
        }
    }
}

public enum ModelRole: String, Sendable, Equatable {
    case embedding
    case answer

    public var title: String {
        switch self {
        case .embedding: "Search"
        case .answer: "Answers"
        }
    }
}

/// A model file Fen can fetch or import (issues #4, #234). `sha256` and `byteCount` come from Fen,
/// not from the server, so a swapped or cut-off file is rejected.
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
    public let kind: ModelKind
    /// Shown in Settings, for example "100+ languages".
    public let languages: String
    /// The size of the vectors an embedding model returns. 0 for answer models.
    public let embeddingDimension: Int
    /// A redirect may only go to the download host or to a host that ends with one of these.
    public let redirectHostSuffixes: [String]
    /// Physical memory the model needs to run, in bytes. 0 means no gate.
    public let minimumMemory: Int64
    /// Where the model can run. Big models stay off phones.
    public let platforms: Set<ModelPlatform>

    public init(
        id: String,
        displayName: String,
        url: URL,
        sha256: String,
        byteCount: Int64,
        fileName: String,
        licenseName: String,
        kind: ModelKind = .generic,
        languages: String = "",
        embeddingDimension: Int = 0,
        redirectHostSuffixes: [String] = [],
        minimumMemory: Int64 = 0,
        platforms: Set<ModelPlatform> = [.mac, .iPad, .iPhone]
    ) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
        self.fileName = fileName
        self.licenseName = licenseName
        self.kind = kind
        self.languages = languages
        self.embeddingDimension = embeddingDimension
        self.redirectHostSuffixes = redirectHostSuffixes
        self.minimumMemory = minimumMemory
        self.platforms = platforms
    }

    public var role: ModelRole {
        kind.role
    }

    public var host: String {
        url.host(percentEncoded: false) ?? ""
    }

    /// The sentence the confirmation dialog shows before a download starts. It names the host you
    /// ask for and, when the file is served from a download network, the hosts it may be handed to.
    public var consentText: String {
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        var text = "Download \(displayName) (\(size)) from \(host)?"
        if !redirectHostSuffixes.isEmpty {
            let hosts = redirectHostSuffixes.joined(separator: ", ")
            text += " The file may come from a download server of \(hosts). Fen refuses any other host and any plain http."
        }
        return text
    }

    /// `true` when `url` is a place a download of this model may be redirected to.
    func allowsRedirect(to url: URL) -> Bool {
        guard let target = url.host(percentEncoded: false)?.lowercased() else { return false }
        let scheme = url.scheme?.lowercased()
        let secure = scheme == "https" || (scheme == "http" && AIEndpoint.isLoopback(host: target))
        guard secure else { return false }
        if target == host.lowercased() {
            return true
        }
        return redirectHostSuffixes.contains { suffix in
            let suffix = suffix.lowercased()
            return target == suffix || target.hasSuffix("." + suffix)
        }
    }
}

public enum ModelPlatform: String, Sendable, Equatable {
    case mac
    case iPad
    case iPhone
}

public enum ModelError: Error, Equatable, LocalizedError {
    case invalidFileName
    case insecureURL
    /// The caller did not confirm the host and size the descriptor names.
    case consentMismatch
    case http(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    /// The download was sent to a host the model's entry does not allow.
    case redirectRefused(host: String)
    case notEnoughSpace(needed: Int64, available: Int64)
    /// The device has too little memory for this model, or the model is not for this kind of device.
    case notForThisDevice(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFileName: "The model file name is not valid."
        case .insecureURL: "Models download over https only."
        case .consentMismatch: "The download was not confirmed for this host and size."
        case let .http(status): "The download server answered with HTTP \(status)."
        case let .sizeMismatch(expected, actual): "The file is \(actual) bytes. Expected \(expected)."
        case .checksumMismatch: "The file does not match its checksum. It was not installed."
        case let .redirectRefused(host): "The server tried to send the download to \(host). Fen stopped."
        case let .notEnoughSpace(needed, available):
            "Not enough free space. The model needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)),"
                + " and \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is free."
        case let .notForThisDevice(reason): reason
        }
    }
}

/// Model weights on disk, in `~/.fen/models` (issues #4, #9, #234). The only way weights arrive is a
/// download you confirmed by host and size, or a file you pick. Both are checked against the
/// descriptor's size and SHA-256 before they are moved into place.
///
/// A download writes to `<file>.part`. A canceled or broken download leaves that file, and the next
/// one asks the server for the rest (an HTTP Range request) instead of starting over.
public struct ModelStore: Sendable {
    private let home: FenHome
    private let session: URLSession
    private let freeSpace: @Sendable (URL) -> Int64?

    public init(home: FenHome) {
        self.init(home: home, session: Self.makeSession())
    }

    init(home: FenHome, session: URLSession, freeSpace: @escaping @Sendable (URL) -> Int64? = Self.freeSpace(at:)) {
        self.home = home
        self.session = session
        self.freeSpace = freeSpace
    }

    /// Redirects are checked per download, against the host list of the model being fetched.
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Free space for the volume that holds `url`, counting what the system can free for important files.
    static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
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
        guard let url = try? fileURL(for: model), let size = Self.size(of: url) else { return false }
        return size == model.byteCount
    }

    /// Bytes of an unfinished download that the next download would keep.
    public func partialBytes(_ model: ModelDescriptor) -> Int64 {
        guard let url = try? fileURL(for: model) else { return 0 }
        return Self.size(of: Self.partialURL(url)) ?? 0
    }

    /// Deletes the model and any unfinished download of it.
    public func remove(_ model: ModelDescriptor) throws {
        let url = try fileURL(for: model)
        LlamaEngineCache.shared.evict(path: url.path)
        for file in [url, Self.partialURL(url)] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func partialURL(_ destination: URL) -> URL {
        destination.appendingPathExtension("part")
    }

    private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    // MARK: - Download

    /// Downloads and installs `model`. `confirmedHost` and `confirmedBytes` are what the user saw
    /// in the confirmation, and must match the descriptor. Cancel the task to stop: the part that
    /// arrived stays on disk for the next call.
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
        try Self.checkDevice(for: model)

        try FileManager.default.createDirectory(at: home.modelsDirectory, withIntermediateDirectories: true)
        let partial = Self.partialURL(destination)
        var have = Self.size(of: partial) ?? 0
        if have > model.byteCount {
            try FileManager.default.removeItem(at: partial)
            have = 0
        }
        if let free = freeSpace(home.modelsDirectory), free < model.byteCount - have {
            throw ModelError.notEnoughSpace(needed: model.byteCount - have, available: free)
        }
        if have < model.byteCount {
            progress(have)
            do {
                try await fetch(model, into: partial, from: have, progress: progress)
            } catch {
                // Nothing arrived, so there is nothing to resume.
                if Self.size(of: partial) == 0 {
                    try? FileManager.default.removeItem(at: partial)
                }
                throw error
            }
        }
        try Task.checkCancellation()
        return try place(partial, as: model, at: destination)
    }

    /// Throws when this device can't run `model`: wrong kind of device, or too little memory.
    public static func checkDevice(for model: ModelDescriptor) throws {
        if !model.platforms.contains(.current) {
            throw ModelError.notForThisDevice("\(model.displayName) is too big for \(ModelPlatform.current.title).")
        }
        let memory = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        if model.minimumMemory > 0, memory < model.minimumMemory {
            let need = ByteCountFormatter.string(fromByteCount: model.minimumMemory, countStyle: .memory)
            throw ModelError.notForThisDevice("\(model.displayName) needs \(need) of memory.")
        }
    }

    private func fetch(
        _ model: ModelDescriptor,
        into partial: URL,
        from offset: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var request = URLRequest(url: model.url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        try await Transfer(model: model, handle: handle, offset: offset, report: progress)
            .run(session: session, request: request)
    }

    /// One download request. It writes each piece to the partial file as it arrives and enforces
    /// the redirect rule and the size ceiling.
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let model: ModelDescriptor
        private let handle: FileHandle
        private let report: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var offset: Int64
        private var continuation: CheckedContinuation<Void, Error>?
        private var task: URLSessionDataTask?
        private var failure: Error?
        private var cancelled = false

        init(model: ModelDescriptor, handle: FileHandle, offset: Int64, report: @escaping @Sendable (Int64) -> Void) {
            self.model = model
            self.handle = handle
            self.offset = offset
            self.report = report
        }

        func run(session: URLSession, request: URLRequest) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let task = session.dataTask(with: request)
                    task.delegate = self
                    let stop = lock.withLock {
                        self.continuation = continuation
                        self.task = task
                        return cancelled
                    }
                    if stop {
                        continuation.resume(throwing: CancellationError())
                        lock.withLock { self.continuation = nil }
                    } else {
                        task.resume()
                    }
                }
            } onCancel: {
                let task = lock.withLock {
                    cancelled = true
                    return self.task
                }
                task?.cancel()
            }
        }

        /// Records the first reason this download has to stop and stops it.
        private func fail(_ error: Error) {
            lock.withLock {
                if failure == nil {
                    failure = error
                }
            }
            task?.cancel()
        }

        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let url = request.url, model.allowsRedirect(to: url) {
                completionHandler(request)
            } else {
                fail(ModelError.redirectRefused(host: request.url?.host(percentEncoded: false) ?? ""))
                completionHandler(nil)
            }
        }

        func urlSession(
            _: URLSession,
            dataTask _: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                fail(ModelError.http(0))
                return completionHandler(.cancel)
            }
            do {
                switch http.statusCode {
                case 206:
                    // Only a reply that starts where the partial file ends can be appended.
                    guard Self.rangeStart(http.value(forHTTPHeaderField: "Content-Range")) == offset else {
                        throw ModelError.http(206)
                    }
                case 200:
                    // The server ignored the Range header, so start over.
                    if offset > 0 {
                        try handle.truncate(atOffset: 0)
                        try handle.seek(toOffset: 0)
                        offset = 0
                    }
                default:
                    throw ModelError.http(http.statusCode)
                }
                if http.expectedContentLength > 0, offset + http.expectedContentLength > model.byteCount {
                    throw ModelError.sizeMismatch(
                        expected: model.byteCount,
                        actual: offset + http.expectedContentLength
                    )
                }
                completionHandler(.allow)
            } catch {
                fail(error)
                completionHandler(.cancel)
            }
        }

        func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle.write(contentsOf: data)
            } catch {
                return fail(error)
            }
            offset += Int64(data.count)
            if offset > model.byteCount {
                return fail(ModelError.sizeMismatch(expected: model.byteCount, actual: offset))
            }
            report(offset)
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, reason, wasCancelled) = lock.withLock {
                let taken = self.continuation
                self.continuation = nil
                return (taken, failure, cancelled)
            }
            if let reason {
                continuation?.resume(throwing: reason)
            } else if wasCancelled {
                continuation?.resume(throwing: CancellationError())
            } else if let error {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume()
            }
        }

        /// The first byte of a `Content-Range: bytes 100-199/200` header.
        static func rangeStart(_ header: String?) -> Int64? {
            guard let header, header.hasPrefix("bytes ") else { return nil }
            return header.dropFirst(6).split(separator: "-").first.flatMap { Int64($0) }
        }
    }

    // MARK: - Import

    /// Installs a model file you picked. Same checks as a download.
    @discardableResult
    public func importFile(_ source: URL, as model: ModelDescriptor) throws -> URL {
        let destination = try fileURL(for: model)
        try FileManager.default.createDirectory(at: home.modelsDirectory, withIntermediateDirectories: true)
        let partial = Self.partialURL(destination)
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.copyItem(at: source, to: partial)
        return try place(partial, as: model, at: destination)
    }

    // MARK: - Install

    /// Checks the partial file and renames it into place. A failed check deletes it, so a bad file
    /// is never resumed.
    private func place(_ partial: URL, as model: ModelDescriptor, at destination: URL) throws -> URL {
        do {
            let size = Self.size(of: partial) ?? -1
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

extension ModelPlatform {
    /// The kind of device this build runs on. An iPad counts as an iPad even with a phone's screen size.
    static var current: ModelPlatform {
        #if os(macOS)
            .mac
        #else
            ProcessInfo.processInfo
                .isiOSAppOnMac ? .mac : (UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone)
        #endif
    }

    var title: String {
        switch self {
        case .mac: "this Mac"
        case .iPad: "this iPad"
        case .iPhone: "this iPhone"
        }
    }
}
