import CryptoKit
import Foundation

public enum ContentHash {
    /// SHA-256 as lowercase hex.
    public static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ApprovedBy: String, Codable, Sendable {
    /// Applied by auto-approve.
    case auto
    /// You approved it in the approval list.
    case user
    /// You started it yourself.
    case invoked
}

/// One applied change, as the activity log shows it (issue #140).
public struct ActivityEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var runID: UUID
    public var workspaceID: UUID
    public var date: Date
    public var operation: String
    public var edit: String
    public var tier: EditTier
    public var path: String
    /// The new path of a move.
    public var toPath: String?
    public var preHash: String?
    public var postHash: String?
    public var provenance: Provenance
    public var approvedBy: ApprovedBy
    public var diff: LineDiff
    public var undoneAt: Date?
    /// The agent branch and commit that hold this change, when it was committed there (#93).
    public var branch: String?
    public var commit: String?
    /// Whose branch it went to, so an undo opens the same one.
    public var agent: String?

    public var isUndone: Bool {
        undoneAt != nil
    }
}

/// An append-only JSON Lines file per workspace, in `~/.fen/workspaces/<id>/history/`.
/// A damaged line is skipped, never fatal. It stays when the app restarts.
struct ActivityLog {
    private enum Record: Codable {
        case applied(ActivityEntry)
        case undone(id: UUID, date: Date)
    }

    let file: URL

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func load() -> [ActivityEntry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [ActivityEntry] = []
        for line in text.split(separator: "\n") {
            guard let record = try? decoder.decode(Record.self, from: Data(line.utf8)) else { continue }
            switch record {
            case let .applied(entry):
                entries.append(entry)
            case let .undone(id, date):
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index].undoneAt = date
                }
            }
        }
        return entries
    }

    func appendApplied(_ entry: ActivityEntry) throws {
        try append(.applied(entry))
    }

    func appendUndone(id: UUID, date: Date) throws {
        try append(.undone(id: id, date: date))
    }

    private func append(_ record: Record) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var line = try encoder.encode(record)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: file.path) {
            try line.write(to: file, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}

/// Copies of files as they were before a change, in `history/preimages/`. Named by a hash of the
/// path and a hash of the content, so the same bytes at the same path are stored once.
struct PreImageStore {
    let directory: URL

    private func url(path: String, hash: String) -> URL {
        directory.appendingPathComponent("\(ContentHash.of(Data(path.utf8)).prefix(16))-\(hash)")
    }

    func save(_ data: Data, path: String) throws {
        let target = url(path: path, hash: ContentHash.of(data))
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    /// The saved bytes, or `nil` if they are missing or no longer match `hash`.
    func load(path: String, hash: String) -> Data? {
        guard let data = try? Data(contentsOf: url(path: path, hash: hash)), ContentHash.of(data) == hash else {
            return nil
        }
        return data
    }
}
