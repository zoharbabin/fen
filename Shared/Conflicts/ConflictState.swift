import Foundation

/// One side of a flagged conflict: a passage of one note.
struct ConflictSide: Codable, Sendable, Equatable {
    var path: String
    var text: String
    /// Hash of the text (`ConflictPassage.hash`). The flag finds the passage again by this.
    var hash: String
    /// Where the passage was when it was flagged. Only a hint: it moves as the file changes.
    var startLine: Int

    init(path: String, passage: ConflictPassage) {
        self.path = path
        text = passage.text
        hash = passage.hash
        startLine = passage.startLine
    }
}

/// Two passages that seem to disagree (issue #94). `changed` is the side that was edited and
/// triggered the check, `other` the passage elsewhere that may now be out of date.
struct ConflictFlag: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable {
        case open
        /// You said these don't conflict. They stay quiet while both texts stay the same.
        case dismissed
    }

    /// How a fix for this flag is going through the write gate.
    struct Resolution: Codable, Sendable, Equatable {
        var changeID: UUID
        var runID: UUID
        /// The path the fix rewrites.
        var path: String
    }

    var id: UUID
    var changed: ConflictSide
    var other: ConflictSide
    /// 0 to 1. A model's "high" is 0.9. A match found without a model claims at most 0.5.
    var confidence: Double
    /// `model` or `signals`.
    var method: String
    var explanation: String
    var created: Date
    var status: Status
    var resolution: Resolution?
    /// Which side is probably out of date, when a model said so.
    var staleSide: String?

    /// The same two texts, in either order. A second run does not flag a pair twice.
    var pairKey: String {
        [changed.hash, other.hash].sorted().joined(separator: "+")
    }
}

/// Where a flagged passage is now.
enum FlagLocation: Equatable {
    case found(line: Int)
    /// The text was edited or removed since it was flagged.
    case stale
}

/// What Fen remembers about a workspace's conflict checks, in `~/.fen/workspaces/<id>/conflicts.json`.
/// It lives on this device and is never written into the workspace, so it can't leak into git.
struct ConflictState: Codable, Sendable, Equatable {
    /// What the last run knew about one file.
    struct FileRecord: Codable, Sendable, Equatable {
        var hash: String
        var passages: [String]
    }

    var version = 1
    /// `HEAD` when the last run finished. `nil` in a folder with no git.
    var commit: String?
    var files: [String: FileRecord] = [:]
    var flags: [ConflictFlag] = []
    var lastRun: Date?
}

struct ConflictStore {
    let file: URL

    func load() -> ConflictState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file)).flatMap { try? decoder.decode(ConflictState.self, from: $0) }
            ?? ConflictState()
    }

    func save(_ state: ConflictState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: file, options: .atomic)
    }
}

extension ConflictFlag {
    /// Looks for each side's text in the current files. `read` returns a file's text, or `nil`.
    func locate(read: (String) -> String?) -> (changed: FlagLocation, other: FlagLocation) {
        (Self.locate(changed, read), Self.locate(other, read))
    }

    private static func locate(_ side: ConflictSide, _ read: (String) -> String?) -> FlagLocation {
        guard let text = read(side.path),
              let passage = ConflictPassage.find(hash: side.hash, in: text) else { return .stale }
        return .found(line: passage.startLine)
    }
}
