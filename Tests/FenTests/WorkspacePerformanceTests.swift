@testable import FenCore
import Foundation
import Testing

/// Numbers for issue #5's "optimal performance" bar. The limits are loose on purpose: they catch a
/// regression of an order of magnitude, not noise between machines. The measured values are
/// printed, so the PR can quote them.
@Suite("Workspace performance", .serialized)
@MainActor
struct WorkspacePerformanceTests {
    private func populate(_ folder: TempFolder, files: Int, perDirectory: Int = 25) throws {
        for index in 0 ..< files {
            try folder.write("section-\(index / perDirectory)/note-\(index).md", "# Note \(index)\n")
        }
    }

    @Test("several workspaces list quickly and the main actor never stalls")
    func scanSeveralWorkspaces() async throws {
        let home = try TempFolder("perf-home")
        let folders = try (0 ..< 3).map { _ in try TempFolder("perf") }
        defer { home.cleanUp()
            folders.forEach { $0.cleanUp() }
        }
        for folder in folders {
            try populate(folder, files: 3000)
        }

        let library = WorkspaceLibrary(home: FenHome(root: home.root.appendingPathComponent(".fen")), watching: false)
        let clock = ContinuousClock()
        var maxGap = Duration.zero
        var done = false
        let started = clock.now

        var ids: [UUID] = []
        for folder in folders {
            try ids.append(library.add(folder: folder.root).id)
        }

        var last = clock.now
        while !done {
            await Task.yield()
            let now = clock.now
            maxGap = max(maxGap, now - last)
            last = now
            done = ids.allSatisfy { library.state(for: $0).hasScanned && library.state(for: $0).phase == .idle }
            #expect(clock.now - started < .seconds(60), "scan did not finish")
            if clock.now - started >= .seconds(60) {
                break
            }
        }
        let total = clock.now - started
        print("PERF scan: 3 workspaces x 3000 files in \(total), longest main-actor gap \(maxGap)")
        #expect(ids.allSatisfy { library.state(for: $0).snapshot.files.count == 3000 })
        #expect(total < .seconds(20))
        #expect(maxGap < .milliseconds(250))
    }

    @Test("sorting and building the tree for a large workspace is fast enough for a view body")
    func treeBuild() {
        let files = (0 ..< 20000).map {
            WorkspaceFile(relativePath: "section-\($0 / 25)/note-\($0).md", size: 10, modified: .distantPast)
        }
        var snapshot = WorkspaceSnapshot()
        for file in files {
            snapshot.files[file.relativePath] = file
        }
        let clock = ContinuousClock()
        let started = clock.now
        let tree = WorkspaceFileTree.build(from: snapshot.documents)
        let elapsed = clock.now - started
        print("PERF tree: 20000 files sorted and grouped in \(elapsed)")
        #expect(tree.count == 800)
        #expect(elapsed < .seconds(2))
    }

    @Test("an incremental update is much cheaper than a full scan")
    func incrementalIsCheap() async throws {
        let folder = try TempFolder("perf-inc")
        defer { folder.cleanUp() }
        try populate(folder, files: 5000)
        let source = LocalFolderSource(root: folder.root, settings: WorkspaceSettings())
        let clock = ContinuousClock()

        // Files written a moment ago are slow to open the first time (the OS scans them), so the
        // first pass is cold. The second pass is what a relaunch or Refresh costs.
        let coldStart = clock.now
        _ = try await source.scan { _ in }
        let coldTime = clock.now - coldStart
        let scanStart = clock.now
        let snapshot = try await source.scan { _ in }
        let scanTime = clock.now - scanStart

        try folder.write("section-0/added.md", "# New\n")
        let updateStart = clock.now
        let updated = try await source.update(snapshot, changedPaths: ["section-0/added.md"])
        let updateTime = clock.now - updateStart

        print(
            "PERF incremental: 5000 files, first scan \(coldTime), second scan \(scanTime), "
                + "one-file update \(updateTime)"
        )
        #expect(updated.files.count == 5001)
        #expect(updateTime < scanTime / 5)
    }
}
