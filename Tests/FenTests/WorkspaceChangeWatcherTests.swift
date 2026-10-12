@testable import FenCore
import Foundation
import Testing

#if os(macOS)
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func add(_ new: [String]) {
            lock.lock()
            paths += new
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    @Suite("WorkspaceChangeWatcher")
    struct WorkspaceChangeWatcherTests {
        @Test("reports created, edited, and deleted files as relative paths")
        func reportsChanges() async throws {
            let folder = try TempFolder()
            defer { folder.cleanUp() }
            try folder.write("notes/seed.md", "seed")
            let collector = Collector()
            let watcher = WorkspaceChangeWatcher(root: folder.root, latency: 0.05) { collector.add($0) }
            watcher.start()
            defer { watcher.stop() }

            try folder.write("notes/new.md", "one")
            #expect(try await pollUntilTrue { collector.all.contains("notes/new.md") })

            try folder.write("notes/new.md", "two")
            try FileManager.default.removeItem(at: folder.root.appendingPathComponent("notes/seed.md"))
            #expect(try await pollUntilTrue { collector.all.contains("notes/seed.md") })
        }

        @Test("stops reporting after stop()")
        func stops() async throws {
            let folder = try TempFolder()
            defer { folder.cleanUp() }
            let collector = Collector()
            let watcher = WorkspaceChangeWatcher(root: folder.root, latency: 0.05) { collector.add($0) }
            watcher.start()
            try folder.write("a.md", "a")
            #expect(try await pollUntilTrue { collector.all.contains("a.md") })
            watcher.stop()
            let before = collector.all.count
            // Prove absence: a second watcher sees the later write, the stopped one does not.
            let witness = Collector()
            let second = WorkspaceChangeWatcher(root: folder.root, latency: 0.05) { witness.add($0) }
            second.start()
            defer { second.stop() }
            try folder.write("b.md", "b")
            #expect(try await pollUntilTrue { witness.all.contains("b.md") })
            #expect(collector.all.count == before)
        }
    }
#endif
