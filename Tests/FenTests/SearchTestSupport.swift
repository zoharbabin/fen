@testable import FenCore
import Foundation

/// An embedder that needs no model. Words in the same group share one axis, so "car" and
/// "automobile" are close and unrelated words are not. It counts its calls.
final class FakeEmbedder: EmbeddingProvider, @unchecked Sendable {
    static let groups: [[String]] = [
        ["car", "automobile", "vehicle", "sedan"],
        ["release", "publish", "ship", "deploy"],
        ["cat", "feline", "kitten"],
        ["money", "budget", "cost", "price"],
        ["sign", "notarize", "certificate"],
        ["recipe", "cooking", "dinner", "bake"],
    ]

    let id = "fake.concepts"
    let dimension = 64
    let runsOnDevice = true
    var similarityFloor: Float {
        floor
    }

    private let floor: Float
    private let lock = NSLock()
    private var count = 0
    private var seen: [String] = []

    init(similarityFloor: Float = 0.2) {
        floor = similarityFloor
    }

    var calls: Int {
        lock.withLock { count }
    }

    var inputs: [String] {
        lock.withLock { seen }
    }

    func embed(_ text: String) async throws -> [Float] {
        lock.withLock {
            count += 1
            seen.append(text)
        }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        var vector = [Float](repeating: 0, count: dimension)
        for word in words {
            let canonical = Self.groups.first { $0.contains(word) }?.first ?? word
            let slot = canonical.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) % 1_000_003 } % dimension
            vector[slot] += 1
        }
        guard vector.contains(where: { $0 > 0 }) else { throw EmbeddingTextError.noVector }
        return vector
    }
}

/// An embedder that waits until the test opens it. Cancelling the task ends the wait.
final class GatedEmbedder: EmbeddingProvider, @unchecked Sendable {
    let id = "fake.concepts"
    let dimension = 64
    let runsOnDevice = true
    var similarityFloor: Float {
        0.2
    }

    private let inner = FakeEmbedder()
    private let lock = NSLock()
    private var isOpen = false

    func open() {
        lock.withLock { isOpen = true }
    }

    func embed(_ text: String) async throws -> [Float] {
        while !lock.withLock({ isOpen }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try await inner.embed(text)
    }
}

/// A source over a fixed list of files, for indexer tests that need no disk.
struct MemorySource: WorkspaceSource {
    let rootURL = URL(fileURLWithPath: "/memory")
    var contents: [String: String]

    func scan(progress _: @Sendable (Int) -> Void) async throws -> WorkspaceSnapshot {
        WorkspaceSnapshot()
    }

    func update(_ snapshot: WorkspaceSnapshot, changedPaths _: [String]) async throws -> WorkspaceSnapshot {
        snapshot
    }

    func gitState(for _: WorkspaceSnapshot) -> GitRepositoryState? {
        nil
    }

    func fileURL(forRelativePath _: String) -> URL? {
        nil
    }

    func read(relativePath path: String) throws -> Data {
        guard let text = contents[path] else { throw CocoaError(.fileNoSuchFile) }
        return Data(text.utf8)
    }

    func exclusionReason(forRelativePath _: String) -> ExclusionReason? {
        nil
    }

    func files(modified: Date = Date(timeIntervalSince1970: 1000)) -> [WorkspaceFile] {
        contents.keys.sorted().map {
            WorkspaceFile(relativePath: $0, size: contents[$0]?.utf8.count ?? 0, modified: modified)
        }
    }
}
