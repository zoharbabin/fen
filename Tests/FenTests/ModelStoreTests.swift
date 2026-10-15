import CryptoKit
@testable import FenCore
import Foundation
import Testing

@Suite("ModelStore", .serialized)
struct ModelStoreTests {
    private static let payload = Data("pretend these are model weights".utf8)

    private static var digest: String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private func descriptor(
        url: String = "https://models.example.com/m.gguf",
        sha256: String = ModelStoreTests.digest,
        byteCount: Int64 = Int64(ModelStoreTests.payload.count),
        fileName: String = "m.gguf"
    ) throws -> ModelDescriptor {
        try ModelDescriptor(
            id: "m",
            displayName: "Test model",
            url: #require(URL(string: url)),
            sha256: sha256,
            byteCount: byteCount,
            fileName: fileName,
            licenseName: "Apache-2.0"
        )
    }

    private func store(_ temp: TempHome) -> ModelStore {
        ModelStore(home: temp.home, session: ModelStore.makeSession())
    }

    private func pickedFile(_ temp: TempHome, _ data: Data = ModelStoreTests.payload) throws -> URL {
        let url = temp.folder.root.appendingPathComponent("picked.bin")
        try FileManager.default.createDirectory(at: temp.folder.root, withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func leftovers(_ temp: TempHome) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: temp.home.modelsDirectory.path)) ?? []
    }

    @Test("consent text names the model, size, and host")
    func consentText() throws {
        let text = try descriptor().consentText
        #expect(text.contains("Test model") && text.contains("models.example.com"))
    }

    @Test("importing a matching file installs it")
    func importOK() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try descriptor()
        let store = store(temp)
        #expect(!store.isInstalled(model))
        let installed = try store.importFile(pickedFile(temp), as: model)
        #expect(try Data(contentsOf: installed) == Self.payload)
        #expect(store.isInstalled(model))
        #expect(leftovers(temp) == ["m.gguf"])
        try store.remove(model)
        #expect(!store.isInstalled(model))
    }

    @Test("a file with the wrong checksum is rejected and leaves nothing behind")
    func wrongChecksum() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let other = Data(repeating: 7, count: Self.payload.count)
        #expect(throws: ModelError.checksumMismatch) {
            try store(temp).importFile(pickedFile(temp, other), as: descriptor())
        }
        #expect(leftovers(temp).isEmpty)
    }

    @Test("a file of the wrong size is rejected")
    func wrongSize() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        #expect(throws: ModelError.sizeMismatch(expected: 5, actual: Int64(Self.payload.count))) {
            try store(temp).importFile(pickedFile(temp), as: descriptor(byteCount: 5))
        }
        #expect(leftovers(temp).isEmpty)
    }

    @Test("a failed re-install keeps the model that was already there")
    func failedReplaceKeepsOld() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let store = store(temp)
        let model = try descriptor()
        try store.importFile(pickedFile(temp), as: model)
        _ = try? store.importFile(pickedFile(temp, Data(repeating: 1, count: Self.payload.count)), as: model)
        #expect(try Data(contentsOf: store.fileURL(for: model)) == Self.payload)
    }

    @Test("file names that could escape the models folder are refused", arguments: [
        "", ".", "..", "../x", "a/b", "a\\b", ".hidden", "nul\0byte",
    ])
    func badFileName(name: String) throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        #expect(throws: ModelError.invalidFileName) {
            try store(temp).fileURL(for: descriptor(fileName: name))
        }
    }

    // MARK: - Download

    @Test("downloads, verifies, and installs after consent")
    func download() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(headers: ["Content-Length": "\(Self.payload.count)"], chunks: [Self.payload])
        }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try descriptor(url: "\(server.baseURL)/m.gguf")
        let installed = try await store(temp).download(
            model,
            confirmedHost: model.host,
            confirmedBytes: model.byteCount
        )
        #expect(try Data(contentsOf: installed) == Self.payload)
        #expect(leftovers(temp) == ["m.gguf"])
    }

    @Test("a download that was not confirmed for this host and size never connects")
    func consentRequired() async throws {
        let server = try await LoopbackServer.start { _ in LoopbackServer.Response() }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try descriptor(url: "\(server.baseURL)/m.gguf")
        await #expect(throws: ModelError.consentMismatch) {
            try await store(temp).download(model, confirmedHost: "evil.example.com", confirmedBytes: model.byteCount)
        }
        await #expect(throws: ModelError.consentMismatch) {
            try await store(temp).download(model, confirmedHost: model.host, confirmedBytes: 1)
        }
        #expect(server.connections == 0)
    }

    @Test("plain http to a remote host is refused")
    func insecure() async throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try descriptor(url: "http://models.example.com/m.gguf")
        await #expect(throws: ModelError.insecureURL) {
            try await store(temp).download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        }
    }

    @Test("a swapped download is rejected and nothing is installed")
    func swappedDownload() async throws {
        let server = try await LoopbackServer.start { _ in
            let fake = Data(repeating: 9, count: Self.payload.count)
            return LoopbackServer.Response(headers: ["Content-Length": "\(fake.count)"], chunks: [fake])
        }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try descriptor(url: "\(server.baseURL)/m.gguf")
        await #expect(throws: ModelError.checksumMismatch) {
            try await store(temp).download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        }
        #expect(leftovers(temp).isEmpty)
    }

    @Test("an error status is reported and nothing is installed")
    func httpError() async throws {
        let server = try await LoopbackServer.start { _ in LoopbackServer.Response(
            status: 404,
            chunks: [Data("no".utf8)]
        ) }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try descriptor(url: "\(server.baseURL)/m.gguf")
        await #expect(throws: ModelError.http(404)) {
            try await store(temp).download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        }
        #expect(leftovers(temp).isEmpty)
    }

    // MARK: - Resume, redirects, space (issue #234)

    private static let big = Data((0 ..< 5000).map { UInt8($0 % 251) })

    private func bigDescriptor(url: String, redirects: [String] = []) throws -> ModelDescriptor {
        let digest = SHA256.hash(data: Self.big).map { String(format: "%02x", $0) }.joined()
        return try ModelDescriptor(
            id: "big", displayName: "Big model", url: #require(URL(string: url)), sha256: digest,
            byteCount: Int64(Self.big.count), fileName: "big.gguf", licenseName: "Apache-2.0",
            redirectHostSuffixes: redirects
        )
    }

    @Test("a download that stops keeps its part, and the next one asks only for the rest")
    func resumes() async throws {
        let first = try await LoopbackServer.start { _ in
            // Sends the first 2000 bytes and says there are 5000, so the client sees a cut-off.
            LoopbackServer.Response(
                headers: ["Content-Length": "\(Self.big.count)"], chunks: [Self.big.prefix(2000)]
            )
        }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try bigDescriptor(url: "\(first.baseURL)/big.gguf")
        await #expect(throws: (any Error).self) {
            try await store(temp).download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        }
        first.stop()
        #expect(store(temp).partialBytes(model) == 2000)
        #expect(!store(temp).isInstalled(model))

        let second = try await LoopbackServer.start { request in
            #expect(request.headers.first { $0.key.lowercased() == "range" }?.value == "bytes=2000-")
            return LoopbackServer.Response(
                status: 206,
                headers: ["Content-Length": "3000", "Content-Range": "bytes 2000-4999/5000"],
                chunks: [Self.big.suffix(3000)]
            )
        }
        defer { second.stop() }
        let resumed = try bigDescriptor(url: "\(second.baseURL)/big.gguf")
        let installed = try await store(temp).download(
            resumed,
            confirmedHost: resumed.host,
            confirmedBytes: resumed.byteCount
        )
        #expect(try Data(contentsOf: installed) == Self.big)
        #expect(leftovers(temp) == ["big.gguf"])
        #expect(second.requests.count == 1)
    }

    @Test("a server that ignores the Range header makes the download start over")
    func rangeIgnored() async throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(headers: ["Content-Length": "\(Self.big.count)"], chunks: [Self.big])
        }
        defer { server.stop() }
        let model = try bigDescriptor(url: "\(server.baseURL)/big.gguf")
        try FileManager.default.createDirectory(at: temp.home.modelsDirectory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1234).write(to: temp.home.modelsDirectory.appendingPathComponent("big.gguf.part"))
        try await store(temp).download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        #expect(try Data(contentsOf: store(temp).fileURL(for: model)) == Self.big)
    }

    @Test("a part that is bigger than the model is thrown away")
    func oversizedPart() async throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(headers: ["Content-Length": "\(Self.big.count)"], chunks: [Self.big])
        }
        defer { server.stop() }
        let model = try bigDescriptor(url: "\(server.baseURL)/big.gguf")
        try FileManager.default.createDirectory(at: temp.home.modelsDirectory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 9000).write(to: temp.home.modelsDirectory.appendingPathComponent("big.gguf.part"))
        try await store(temp).download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        #expect(store(temp).isInstalled(model))
    }

    @Test("a server that sends more than the pinned size is stopped, and a wrong file is not kept for resume")
    func tooMuch() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(chunks: [Self.big, Data(repeating: 0, count: 100)])
        }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try bigDescriptor(url: "\(server.baseURL)/big.gguf")
        await #expect(throws: ModelError.self) {
            try await store(temp).download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        }
        #expect(!store(temp).isInstalled(model))
    }

    @Test("a redirect to another host is refused")
    func redirectRefused() async throws {
        let target = try await LoopbackServer.start { _ in
            LoopbackServer.Response(headers: ["Content-Length": "\(Self.big.count)"], chunks: [Self.big])
        }
        defer { target.stop() }
        let origin = try await LoopbackServer.start { _ in
            // "127.0.0.1" is another host than the descriptor's "localhost".
            LoopbackServer.Response(status: 302, headers: ["Location": "http://127.0.0.1:\(target.port)/big.gguf"])
        }
        defer { origin.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try bigDescriptor(url: "\(origin.baseURL)/big.gguf")
        await #expect(throws: ModelError.redirectRefused(host: "127.0.0.1")) {
            try await store(temp).download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        }
        #expect(target.connections == 0)
        #expect(leftovers(temp).isEmpty)
    }

    @Test("a redirect to a host the model's entry lists is followed")
    func redirectAllowed() async throws {
        let target = try await LoopbackServer.start { _ in
            LoopbackServer.Response(headers: ["Content-Length": "\(Self.big.count)"], chunks: [Self.big])
        }
        defer { target.stop() }
        let origin = try await LoopbackServer.start { _ in
            LoopbackServer.Response(status: 302, headers: ["Location": "http://127.0.0.1:\(target.port)/big.gguf"])
        }
        defer { origin.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try bigDescriptor(url: "\(origin.baseURL)/big.gguf", redirects: ["127.0.0.1"])
        try await store(temp).download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        #expect(store(temp).isInstalled(model))
    }

    @Test("redirect rules: https only, and only the listed hosts")
    func redirectRules() throws {
        let model = try ModelDescriptor(
            id: "m", displayName: "M", url: #require(URL(string: "https://huggingface.co/a/b.gguf")),
            sha256: "00", byteCount: 1, fileName: "b.gguf", licenseName: "MIT",
            redirectHostSuffixes: ["hf.co", "huggingface.co"]
        )
        func allowed(_ text: String) throws -> Bool {
            try model.allowsRedirect(to: #require(URL(string: text)))
        }
        #expect(try allowed("https://huggingface.co/x"))
        #expect(try allowed("https://us.aws.cdn.hf.co/x"))
        #expect(try allowed("https://cdn-lfs.huggingface.co/x"))
        #expect(try !allowed("http://us.aws.cdn.hf.co/x"))
        #expect(try !allowed("https://evilhf.co/x"))
        #expect(try !allowed("https://hf.co.evil.com/x"))
        #expect(try !allowed("https://example.com/x"))
        #expect(try !allowed("file:///etc/passwd"))
        #expect(model.consentText.contains("hf.co") && model.consentText.contains("huggingface.co"))
    }

    @Test("a download that does not fit the free space never connects")
    func notEnoughSpace() async throws {
        let server = try await LoopbackServer.start { _ in LoopbackServer.Response() }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try bigDescriptor(url: "\(server.baseURL)/big.gguf")
        let tight = ModelStore(home: temp.home, session: ModelStore.makeSession(), freeSpace: { _ in 100 })
        await #expect(throws: ModelError.notEnoughSpace(needed: model.byteCount, available: 100)) {
            try await tight.download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        }
        #expect(server.connections == 0)
    }

    @Test("a model that needs more memory than this device has is refused")
    func notEnoughMemory() async throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try ModelDescriptor(
            id: "m", displayName: "Huge", url: #require(URL(string: "https://models.example.com/m.gguf")),
            sha256: "00", byteCount: 1, fileName: "m.gguf", licenseName: "MIT", minimumMemory: Int64.max
        )
        await #expect(throws: ModelError.self) {
            try await store(temp).download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        }
    }

    @Test("canceling keeps the part, and deleting removes the model and its part")
    func cancelAndDelete() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(
                headers: ["Content-Length": "\(Self.big.count)"], chunks: [Self.big.prefix(1000)], holdOpen: true
            )
        }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try bigDescriptor(url: "\(server.baseURL)/big.gguf")
        let store = store(temp)
        let received = ReceivedFlag()
        let task = Task {
            try await store.download(model, confirmedHost: model.host, confirmedBytes: model.byteCount) { bytes in
                if bytes >= 1000 {
                    received.set()
                }
            }
        }
        try await pollUntilTrue { received.isSet }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.partialBytes(model) == 1000)
        try store.remove(model)
        #expect(store.partialBytes(model) == 0)
        #expect(leftovers(temp).isEmpty)
    }
}

private final class ReceivedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}
