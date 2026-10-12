#if os(macOS)
    @testable import FenCore
    import Foundation
    import Testing

    /// Issue #59. `addVersion` exists on macOS only, so these tests make versions the way the system does.
    struct FileVersionHistoryTests {
        private func makeFile(_ text: String) throws -> URL {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/FenVersionTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("note.md")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        private func snapshot(_ url: URL, text: String, modified: Date) throws {
            let source = url.deletingLastPathComponent().appendingPathComponent("source-\(UUID().uuidString).md")
            try text.write(to: source, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
            try NSFileVersion.addOfItem(at: url, withContentsOf: source, options: [])
            try? FileManager.default.removeItem(at: source)
        }

        @Test func listsEarlierVersionsNewestFirstWithoutTheCurrentOne() async throws {
            let url = try makeFile("current")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try snapshot(url, text: "older", modified: Date(timeIntervalSinceNow: -3600))
            try snapshot(url, text: "newer", modified: Date(timeIntervalSinceNow: -60))

            let versions = await FileVersionHistory.versions(of: url)
            let texts = try await versions.asyncMap { try await FileVersionHistory.text(of: $0) }
            #expect(texts == ["newer", "older"])
            #expect(!texts.contains("current"))
        }

        @Test func aMissingFileHasNoVersions() async {
            let url = URL(fileURLWithPath: "/tmp/fen-no-such-\(UUID().uuidString).md")
            #expect(await FileVersionHistory.versions(of: url).isEmpty)
        }

        @Test func readingAVersionDoesNotChangeTheFile() async throws {
            let url = try makeFile("current")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try snapshot(url, text: "old", modified: .now)
            let versions = await FileVersionHistory.versions(of: url)
            _ = try await FileVersionHistory.text(of: #require(versions.first))
            #expect(try String(contentsOf: url, encoding: .utf8) == "current")
            #expect(await FileVersionHistory.versions(of: url).count == 1)
        }
    }

    private extension Array {
        func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
            var out: [T] = []
            for element in self {
                try await out.append(transform(element))
            }
            return out
        }
    }
#endif
