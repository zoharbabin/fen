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
}
