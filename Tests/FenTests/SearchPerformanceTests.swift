@testable import FenCore
import Foundation
import Testing

/// Numbers for issue #35's performance bar. The limits are loose on purpose: they catch a
/// regression of an order of magnitude, not noise between machines. The measured values are
/// printed, so the PR can quote them.
@Suite("Search performance", .serialized)
@MainActor
struct SearchPerformanceTests {
    private let vocabulary = [
        "release", "notarize", "garden", "budget", "travel", "recipe", "meeting", "backup", "password", "sleep",
        "bicycle", "novel", "endpoint", "invoice", "roadmap", "design", "review", "deploy", "cache", "latency",
    ]

    private func populate(_ folder: TempFolder, files: Int, seed: Int) throws {
        for index in 0 ..< files {
            let words = (0 ..< 40)
                .map { vocabulary[($0 * 7 + index * 3 + seed) % vocabulary.count] + "\(($0 + index) % 13)" }
            let body = "# Note \(index)\n\n" + words.joined(separator: " ") + ".\n\n## Part two\n\n" + words.reversed()
                .joined(separator: " ") + ".\n"
            try folder.write("section-\(index / 25)/note-\(index).md", body)
        }
    }

    private func settled(_ library: WorkspaceLibrary, _ ids: [UUID], documents: Int) -> Bool {
        ids.allSatisfy {
            let status = library.indexStatus(for: $0)
            return library.state(for: $0).hasScanned && status.phase == .idle && status.documents == documents
        }
    }

    @Test("three large workspaces index in the background, the main actor never stalls, and search stays fast")
    func indexAndSearch() async throws {
        let home = try TempFolder("search-perf-home")
        let folders = try (0 ..< 3).map { _ in try TempFolder("search-perf") }
        defer { home.cleanUp()
            folders.forEach { $0.cleanUp() }
        }
        for (seed, folder) in folders.enumerated() {
            try populate(folder, files: 2000, seed: seed)
        }
        let homeFolder = FenHome(root: home.root.appendingPathComponent(".fen"))
        let library = WorkspaceLibrary(home: homeFolder, watching: false, embedder: FakeEmbedder())
        let clock = ContinuousClock()
        let started = clock.now
        var ids: [UUID] = []
        for folder in folders {
            try ids.append(library.add(folder: folder.root).id)
        }

        var maxGap = Duration.zero
        var last = clock.now
        while !settled(library, ids, documents: 2000) {
            await Task.yield()
            let now = clock.now
            maxGap = max(maxGap, now - last)
            last = now
            guard now - started < .seconds(120) else { break }
        }
        let indexTime = clock.now - started
        #expect(settled(library, ids, documents: 2000), "indexing did not finish")

        var latencies: [Duration] = []
        for number in 0 ..< 20 {
            let query = "\(vocabulary[number % vocabulary.count]) \(vocabulary[(number + 5) % vocabulary.count])"
            let begin = clock.now
            let results = await library.search(query, scope: .all)
            latencies.append(clock.now - begin)
            #expect(!results.isEmpty)
        }
        latencies.sort()
        let median = latencies[latencies.count / 2]
        let worst = latencies[latencies.count - 1]
        let size = ids.reduce(0) { total, id in
            total +
                ((try? FileManager.default
                        .attributesOfItem(atPath: homeFolder.indexDirectory(id: id)
                            .appendingPathComponent(SearchIndex.fileName)
                            .path)[.size] as? Int) ?? 0)
        }
        print(
            "PERF index: 3 workspaces x 2000 files (about 12000 chunks) in \(indexTime), longest main-actor gap \(maxGap)"
        )
        print(
            "PERF search across 3 workspaces: median \(median), worst \(worst); index files total \(size / 1_000_000) MB"
        )
        #expect(indexTime < .seconds(90))
        #expect(maxGap < .milliseconds(250))
        #expect(median < .milliseconds(250))
    }

    @Test("a second launch finds everything unchanged and embeds nothing")
    func relaunchIsCheap() async throws {
        let home = try TempFolder("search-perf-relaunch")
        let folder = try TempFolder("search-perf-relaunch-files")
        defer { home.cleanUp()
            folder.cleanUp()
        }
        try populate(folder, files: 3000, seed: 1)
        let homeFolder = FenHome(root: home.root.appendingPathComponent(".fen"))
        let first = FakeEmbedder()
        let library = WorkspaceLibrary(home: homeFolder, watching: false, embedder: first)
        let id = try library.add(folder: folder.root).id
        #expect(try await pollUntilTrue(timeout: .seconds(120)) { settled(library, [id], documents: 3000) })
        library.search.closeAll()

        let second = FakeEmbedder()
        let clock = ContinuousClock()
        let started = clock.now
        let again = WorkspaceLibrary(home: homeFolder, watching: false, embedder: second)
        again.start()
        #expect(try await pollUntilTrue(timeout: .seconds(120)) { settled(again, [id], documents: 3000) })
        let elapsed = clock.now - started
        print("PERF relaunch: 3000 unchanged files checked in \(elapsed), embed calls \(second.calls)")
        #expect(second.calls == 0)
        #expect(elapsed < .seconds(30))
    }

    @Test("the real on-device model: indexing speed on one workspace")
    func realModel() async throws {
        let provider = AppleSentenceEmbeddingProvider()
        try #require(provider.isAvailable)
        let home = try TempFolder("search-perf-real-home")
        let folder = try TempFolder("search-perf-real")
        defer { home.cleanUp()
            folder.cleanUp()
        }
        try populate(folder, files: 300, seed: 2)
        let library = WorkspaceLibrary(
            home: FenHome(root: home.root.appendingPathComponent(".fen")),
            watching: false,
            embedder: provider
        )
        let clock = ContinuousClock()
        let started = clock.now
        let id = try library.add(folder: folder.root).id
        var maxGap = Duration.zero
        var last = clock.now
        while !settled(library, [id], documents: 300) {
            await Task.yield()
            maxGap = max(maxGap, clock.now - last)
            last = clock.now
            guard clock.now - started < .seconds(120) else { break }
        }
        let elapsed = clock.now - started
        let status = library.indexStatus(for: id)
        print(
            "PERF real model: 300 files (\(status.chunks) chunks, \(status.embeddedChunks) embedded) in \(elapsed), longest main-actor gap \(maxGap)"
        )
        #expect(status.embeddedChunks == status.chunks)
        #expect(maxGap < .milliseconds(250))
    }
}
