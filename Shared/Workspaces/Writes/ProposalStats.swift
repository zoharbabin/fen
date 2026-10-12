import Foundation

/// How often you accept or dismiss what Fen proposes, per operation (issue #11). Counts only. It
/// stays on this device in `~/.fen/workspaces/<id>/proposal-stats.json` and is never sent anywhere.
public struct ProposalStats: Codable, Sendable, Equatable {
    public struct Counts: Codable, Sendable, Equatable {
        /// Applied by auto-approve.
        public var auto = 0
        /// You approved it in the approval list.
        public var accepted = 0
        /// You rejected it.
        public var dismissed = 0

        public var total: Int {
            auto + accepted + dismissed
        }

        /// Share of proposals that were kept, 0 to 1. `nil` before any decision.
        public var keptRate: Double? {
            total == 0 ? nil : Double(auto + accepted) / Double(total)
        }
    }

    public enum Outcome: Sendable {
        case auto, accepted, dismissed
    }

    public var operations: [String: Counts] = [:]

    public init() {}

    public mutating func record(_ outcome: Outcome, operation: String) {
        var counts = operations[operation] ?? Counts()
        switch outcome {
        case .auto: counts.auto += 1
        case .accepted: counts.accepted += 1
        case .dismissed: counts.dismissed += 1
        }
        operations[operation] = counts
    }
}

struct ProposalStatsStore {
    let file: URL

    func load() -> ProposalStats {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ProposalStats.self, from: $0) }
            ?? ProposalStats()
    }

    func record(_ outcome: ProposalStats.Outcome, operation: String) throws {
        var stats = load()
        stats.record(outcome, operation: operation)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(stats).write(to: file, options: .atomic)
    }
}
