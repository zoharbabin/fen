@testable import FenCore
import Foundation
import Testing

/// Downloads the real EmbeddingGemma 2 file from Hugging Face into a temp home. Set
/// `FEN_LIVE_DOWNLOAD=1` to run it. CI skips it, so it downloads no gigabytes.
@Suite("A real download from the catalog (issue #234)", .serialized)
struct LiveDownloadTests {
    @Test(
        "stop part way, resume, verify, run the model, then delete it",
        .enabled(if: ProcessInfo.processInfo.environment["FEN_LIVE_DOWNLOAD"] != nil)
    )
    func stopResumeRun() async throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = ModelCatalog.embeddingGemma2
        let store = ModelStore(home: temp.home)

        let first = Task {
            try await store.download(model, confirmedHost: model.host, confirmedBytes: model.byteCount)
        }
        let started = try await pollUntilTrue(timeout: .seconds(120)) { store.partialBytes(model) >= 40_000_000 }
        first.cancel()
        await #expect(throws: (any Error).self) { try await first.value }
        let kept = store.partialBytes(model)
        print("LIVE kept \(kept) of \(model.byteCount) bytes after the stop")
        #expect(started)
        #expect(kept >= 40_000_000 && kept < model.byteCount)
        #expect(!store.isInstalled(model))

        let firstProgress = FirstValue()
        let file = try await store.download(model, confirmedHost: model.host, confirmedBytes: model.byteCount) {
            firstProgress.set($0)
        }
        print("LIVE the second download reported its first progress at \(firstProgress.value ?? -1) bytes")
        #expect((firstProgress.value ?? 0) >= kept)
        #expect(store.isInstalled(model))
        #expect(try ModelStore.sha256(of: file) == model.sha256)

        let provider = try #require(LlamaEmbeddingProvider(model: model, file: file))
        let vector = try await provider.embed("Water the tomatoes early in the morning.")
        #expect(vector.count == model.embeddingDimension)

        try store.remove(model)
        #expect(!store.isInstalled(model))
        #expect(store.partialBytes(model) == 0)
    }
}

private final class FirstValue: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64?
    var value: Int64? {
        lock.withLock { stored }
    }

    func set(_ new: Int64) {
        lock.withLock {
            if stored == nil {
                stored = new
            }
        }
    }
}
