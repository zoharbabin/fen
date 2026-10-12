@testable import FenCore
import Foundation
import Testing

/// Headless proxy for issue #35's "no regression in launch time" bar. It is not a launch-time
/// measurement of the app.
///
/// What it times is the work `WorkspaceLibrary` puts on the main actor when it starts with workspaces
/// that are already indexed: build the library, `start()` (read the saved list, create the file
/// watchers, queue one scan per workspace), then the main-actor slices of the rescan and the "nothing
/// changed" index check. A ticker on the main actor records the longest stretch where nothing else
/// could run. The limits are loose on purpose: they catch a regression of an order of magnitude, not
/// noise between machines. The numbers are printed (`PERF launch ...`) and recorded in
/// `docs/spikes/latency-proxies.md`.
///
/// Not covered: process start, SwiftUI scene setup, the first window, document loading, WebKit.
@Suite("Launch latency proxy (issue #35)", .serialized)
@MainActor
struct LaunchLatencyProxyTests {
    private struct Launch {
        var libraryInit: Duration
        var start: Duration
        var longestGap: Duration
        var settled: Duration
        var embedCalls: Int
    }

    private let vocabulary = [
        "release", "notarize", "garden", "budget", "travel", "recipe", "meeting", "backup", "password", "sleep",
        "bicycle", "novel", "endpoint", "invoice", "roadmap", "design", "review", "deploy", "cache", "latency",
    ]

    private func populate(_ folder: TempFolder, files: Int) throws {
        for index in 0 ..< files {
            var words: [String] = []
            for position in 0 ..< 40 {
                words
                    .append(vocabulary[(position * 7 + index * 3) % vocabulary.count] + String((position + index) % 13))
            }
            let forward = words.joined(separator: " ")
            let backward = words.reversed().joined(separator: " ")
            let body = "# Note \(index)\n\n" + forward + ".\n\n## Part two\n\n" + backward + ".\n"
            try folder.write("section-\(index / 25)/note-\(index).md", body)
        }
    }

    /// Copies `template` into `count` separate folders. APFS clones the files, so this is quick.
    private func clones(of template: TempFolder, count: Int) throws -> [TempFolder] {
        try (0 ..< count).map { _ in
            let parent = try TempFolder("launch-proxy")
            try FileManager.default.copyItem(at: template.root, to: parent.root.appendingPathComponent("notes"))
            return parent
        }
    }

    private func allSettled(_ library: WorkspaceLibrary, _ ids: [UUID], documents: Int) -> Bool {
        ids.allSatisfy {
            let status = library.indexStatus(for: $0)
            return library.state(for: $0).hasScanned && status.phase == .idle && status.documents == documents
        }
    }

    private func allListed(_ library: WorkspaceLibrary, _ ids: [UUID]) -> Bool {
        ids.allSatisfy { library.state(for: $0).hasScanned && library.state(for: $0).phase == .idle }
    }

    /// Runs the main-actor ticker until `done`. Returns the longest gap between two ticks.
    private func tick(timeout: Duration, until done: () -> Bool) async -> (gap: Duration, elapsed: Duration) {
        let clock = ContinuousClock()
        let started = clock.now
        var last = started
        var gap = Duration.zero
        while !done() {
            await Task.yield()
            let now = clock.now
            gap = max(gap, now - last)
            last = now
            if now - started > timeout {
                break
            }
        }
        return (gap, clock.now - started)
    }

    /// Keeps the first `count` workspaces in the saved list, so one set of indexes serves every N.
    private func limitSavedList(_ file: URL, original: Data, to count: Int) throws {
        guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              let list = object["workspaces"] as? [Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        object["workspaces"] = Array(list.prefix(count))
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
    }

    /// A relaunch: a new library over the same `~/.fen`, real file watchers, indexes already built.
    /// With `untilIndexed` false it stops once every workspace is listed, which is when the
    /// main-actor work that depends on the file count is done.
    private func relaunch(home: FenHome, count: Int, files: Int, untilIndexed: Bool = true) async throws -> Launch {
        let clock = ContinuousClock()
        let embedder = FakeEmbedder()
        let beforeInit = clock.now
        let library = WorkspaceLibrary(home: home, watching: true, embedder: embedder)
        let libraryInit = clock.now - beforeInit
        let beforeStart = clock.now
        library.start()
        let start = clock.now - beforeStart
        let ids = library.workspaces.map(\.id)
        #expect(ids.count == count)
        let done = { untilIndexed ? allSettled(library, ids, documents: files) : allListed(library, ids) }
        let ticks = await tick(timeout: .seconds(120), until: done)
        #expect(done(), "relaunch did not settle")
        library.search.closeAll()
        return Launch(
            libraryInit: libraryInit,
            start: start,
            longestGap: ticks.gap,
            settled: start + ticks.elapsed,
            embedCalls: embedder.calls
        )
    }

    private func line(_ label: String, _ runs: [Launch]) -> String {
        func range(_ pick: (Launch) -> Duration) -> String {
            let values = runs.map(pick).sorted()
            return "\(values[0].milliseconds)-\(values[values.count - 1].milliseconds) ms"
        }
        return "PERF launch \(label): init \(range(\.libraryInit)), start() \(range(\.start)), "
            + "longest main-actor gap after start \(range(\.longestGap)), all settled \(range(\.settled)), "
            + "embed calls \(runs.map(\.embedCalls).max() ?? 0)"
    }

    @Test("starting with 1, 5 and 20 indexed workspaces of 1000 files stays off the main actor")
    func startWithIndexedWorkspaces() async throws {
        let files = 1000
        let workspaceCount = 20
        let home = try TempFolder("launch-proxy-home")
        let template = try TempFolder("launch-proxy-template")
        var folders: [TempFolder] = []
        defer {
            home.cleanUp()
            template.cleanUp()
            folders.forEach { $0.cleanUp() }
        }
        try populate(template, files: files)
        folders = try clones(of: template, count: workspaceCount)
        let fenHome = FenHome(root: home.root.appendingPathComponent(".fen"))

        // First ever launch: 20 workspaces are added and indexed from nothing.
        let first = WorkspaceLibrary(home: fenHome, watching: true, embedder: FakeEmbedder())
        let clock = ContinuousClock()
        let coldStart = clock.now
        var ids: [UUID] = []
        for folder in folders {
            try ids.append(first.add(folder: folder.root.appendingPathComponent("notes")).id)
        }
        let addTime = clock.now - coldStart
        let cold = await tick(timeout: .seconds(300)) { allSettled(first, ids, documents: files) }
        #expect(allSettled(first, ids, documents: files), "first index did not finish")
        first.search.closeAll()
        print(
            "PERF launch cold index: \(workspaceCount) workspaces x \(files) files, "
                + "add() loop \(addTime.milliseconds) ms, longest main-actor gap \(cold.gap.milliseconds) ms, "
                + "everything indexed in \(cold.elapsed.milliseconds) ms"
        )

        let listFile = fenHome.workspacesFile
        let original = try Data(contentsOf: listFile)
        for count in [1, 5, 20] {
            try limitSavedList(listFile, original: original, to: count)
            var runs: [Launch] = []
            for _ in 0 ..< 2 {
                try await runs.append(relaunch(home: fenHome, count: count, files: files))
            }
            print(line("\(count) workspaces x \(files) files (2 runs)", runs))
            for run in runs {
                #expect(run.embedCalls == 0, "an unchanged workspace was embedded again")
                #expect(run.libraryInit < .milliseconds(Limits.libraryInit), "init \(run.libraryInit)")
                #expect(run.start < .milliseconds(Limits.start), "start() \(run.start)")
                #expect(run.longestGap < .milliseconds(Limits.gap), "gap \(run.longestGap)")
            }
        }
        #expect(cold.gap < .milliseconds(Limits.gap), "cold index gap \(cold.gap)")
    }

    @Test("main-actor work after start() does not grow with the number of files")
    func doesNotGrowWithFileCount() async throws {
        var table: [String] = []
        var worstGap = Duration.zero
        var worstStart = Duration.zero
        for files in [500, 2000, 8000] {
            let template = try TempFolder("launch-proxy-scale")
            let home = try TempFolder("launch-proxy-scale-home")
            defer {
                template.cleanUp()
                home.cleanUp()
            }
            try populate(template, files: files)
            let fenHome = FenHome(root: home.root.appendingPathComponent(".fen"))
            try WorkspaceRegistry(home: fenHome).add(folder: template.root)

            // The saved list is on disk and the folder has `files` notes. The index is not built: what
            // is measured is the listing and the hand-over to the indexer, which is the part that sees
            // every file on the main actor.
            var runs: [Launch] = []
            for _ in 0 ..< 3 {
                try await runs.append(relaunch(home: fenHome, count: 1, files: files, untilIndexed: false))
            }
            table.append(line("1 workspace x \(files) files, listing only (3 runs)", runs))
            worstGap = max(worstGap, runs.map(\.longestGap).max() ?? .zero)
            worstStart = max(worstStart, runs.map(\.start).max() ?? .zero)
        }
        table.forEach { print($0) }
        #expect(worstStart < .milliseconds(Limits.start), "start() \(worstStart)")
        #expect(worstGap < .milliseconds(Limits.gap), "gap \(worstGap)")
    }

    /// Loose regression ceilings in milliseconds. See `docs/spikes/latency-proxies.md` for the
    /// measured values and the load they were chosen under.
    private enum Limits {
        static let libraryInit = 500
        static let start = 500
        static let gap = 500
    }
}

extension Duration {
    var milliseconds: Int {
        Int((Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15).rounded())
    }
}
