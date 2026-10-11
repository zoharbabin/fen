@testable import FenCore
import Foundation
import Testing

/// A hand-labeled spot-check of conflict detection (issue #94). Each pair is a passage that was just
/// edited and a passage elsewhere. `conflict` is the label a person would give. The first tier alone
/// decides here, with no model: a pair counts as flagged when it reaches the candidate list and shows
/// at least one mark of contradiction.
enum ConflictLabeledPairs {
    struct Pair {
        let changed: String
        let other: String
        let conflict: Bool
    }

    static let pairs: [Pair] = [
        // Real conflicts.
        Pair(
            changed: "Backups run every 6 hours and are kept for 30 days on the primary server.",
            other: "Backups run every 24 hours and are kept for 7 days on the primary server.",
            conflict: true
        ),
        Pair(
            changed: "Customers can cancel their subscription at any time from the billing page.",
            other: "Customers cannot cancel their subscription from the billing page, they must email support.",
            conflict: true
        ),
        Pair(
            changed: "Guest access to the staging site is enabled for all contractors.",
            other: "Guest access to the staging site is disabled for all contractors.",
            conflict: true
        ),
        Pair(
            changed: "The mobile app no longer uses API keys, it uses OAuth tokens for every request.",
            other: "The mobile app uses API keys for every request to the service.",
            conflict: true
        ),
        Pair(
            changed: "Version 3.1 is the current release and is supported on macOS 14 and later.",
            other: "Version 2.8 is the current release and is supported on macOS 12 and later.",
            conflict: true
        ),
        Pair(
            changed: "Invoices are due within 15 days of the issue date for all clients.",
            other: "Invoices are due within 45 days of the issue date for all clients.",
            conflict: true
        ),
        Pair(
            changed: "Always run the database migration before deploying the new build.",
            other: "Never run the database migration before deploying the new build.",
            conflict: true
        ),
        Pair(
            changed: "Remote work is allowed for all engineers on any weekday.",
            other: "Remote work is forbidden for all engineers on any weekday.",
            conflict: true
        ),
        Pair(
            changed: "Uploads over 25 MB are rejected by the server.",
            other: "Uploads over 100 MB are accepted by the server.",
            conflict: true
        ),
        Pair(
            changed: "The team does not review pull requests on Fridays.",
            other: "The team reviews pull requests on Fridays.",
            conflict: true
        ),
        // Not conflicts: detail, rewording, other topics, or an agreeing update.
        Pair(
            changed: "Backups run every 6 hours and are kept for 30 days on the primary server.",
            other: "Backups are written to encrypted storage and checked after each run.",
            conflict: false
        ),
        Pair(
            changed: "Backups run every 6 hours and are kept for 30 days on the primary server.",
            other: "The primary server keeps backups for 30 days and runs them every 6 hours.",
            conflict: false
        ),
        Pair(
            changed: "Customers can cancel their subscription at any time from the billing page.",
            other: "Customers can pause their subscription from the billing page for up to 3 months.",
            conflict: false
        ),
        Pair(
            changed: "The cat sleeps on the kitchen chair all afternoon long.",
            other: "Pull requests need 2 approvals before they can be merged into main.",
            conflict: false
        ),
        Pair(
            changed: "The release is published on Thursday after the review is complete.",
            other: "We publish the release every Thursday once the review passes.",
            conflict: false
        ),
        Pair(
            changed: "Version 3.1 is the current release and is supported on macOS 14 and later.",
            other: "Version 3.1 adds dark mode and is supported on macOS 14 and later.",
            conflict: false
        ),
        Pair(
            changed: "Remote work is allowed for all engineers on any weekday.",
            other: "Remote work is allowed for contractors on any weekday.",
            conflict: false
        ),
        Pair(
            changed: "Invoices are due within 15 days of the issue date for all clients.",
            other: "Late invoices get a reminder after 15 days and another after 30 days.",
            conflict: false
        ),
        Pair(
            changed: "Pull requests need 2 approvals before they can be merged into main.",
            other: "Pull requests need 2 approvals and a green build before they can be merged into main.",
            conflict: false
        ),
        Pair(
            changed: "Guest access to the staging site is enabled for all contractors.",
            other: "Contractors get guest access to the staging site through the enabled contractor group.",
            conflict: false
        ),
    ]
}

@Suite("Conflict detection precision and recall (issue #94)", .serialized)
@MainActor
struct ConflictPrecisionTests {
    struct Score {
        var truePositives = 0
        var falsePositives = 0
        var falseNegatives = 0
        var candidates = 0

        var precision: Double {
            truePositives + falsePositives == 0 ? 1 : Double(truePositives) / Double(truePositives + falsePositives)
        }

        var recall: Double {
            truePositives + falseNegatives == 0 ? 1 : Double(truePositives) / Double(truePositives + falseNegatives)
        }
    }

    private func score(embed: @escaping @MainActor (String) async -> [Float]?) async -> Score {
        var score = Score()
        for pair in ConflictLabeledPairs.pairs {
            var detector = ConflictDetector(embed: embed)
            let changed = ConflictPassage.split(pair.changed)
            let found = await detector.candidates(
                changed: changed,
                in: "a.md",
                neighbors: [(path: "b.md", text: pair.other)]
            )
            score.candidates += found.count
            let flagged = found.contains { $0.signals.score >= ConflictDetector.Options().minSignal }
            switch (flagged, pair.conflict) {
            case (true, true): score.truePositives += 1
            case (true, false): score.falsePositives += 1
            case (false, true): score.falseNegatives += 1
            case (false, false): break
            }
        }
        return score
    }

    @Test("With the stand-in embedder, the cheap tier finds most real conflicts and few false ones")
    func fakeEmbedder() async {
        let embedder = FakeEmbedder()
        let result = await score { text in
            guard let raw = try? await embedder.embed(text) else { return nil }
            return VectorCodec.normalized(raw)
        }
        print(
            "CONFLICTS fake embedder precision \(result.precision) recall \(result.recall) candidates \(result.candidates)"
        )
        #expect(result.recall >= 0.8)
        #expect(result.precision >= 0.8)
    }

    @Test("With the real on-device model, the cheap tier holds up. FEN_SPIKE=1 prints the numbers")
    func appleEmbedder() async throws {
        let provider = AppleSentenceEmbeddingProvider()
        try #require(provider.isAvailable, "The on-device sentence model isn't installed on this machine.")
        let result = await score { text in
            guard let raw = try? await provider.embed(text) else { return nil }
            return VectorCodec.normalized(raw)
        }
        if ProcessInfo.processInfo.environment["FEN_SPIKE"] == "1" {
            print(
                "[conflicts] real model precision \(result.precision) recall \(result.recall) candidates \(result.candidates)"
            )
        }
        // The real model differs between OS versions, so the bar is loose.
        #expect(result.recall >= 0.6)
        #expect(result.precision >= 0.6)
    }
}

// MARK: - Cost

@Suite("Conflict check cost against a full pass (issue #94)", .serialized)
@MainActor
struct ConflictCostTests {
    static let topics = [
        "harbor", "lantern", "orchard", "granite", "violin", "meadow", "compass", "tundra", "saffron", "glacier",
        "bakery", "canyon", "pigeon", "marble", "thicket", "anchor", "bishop", "cobalt", "dunes", "ferret",
        "hammock", "island", "jungle", "kettle", "lagoon", "mosaic", "nectar", "oyster", "paddle", "quarry",
        "rapids", "summit", "tavern", "uplands", "velvet", "willow", "yonder", "zephyr", "alcove", "bramble",
    ]

    static func note(_ index: Int) -> String {
        let topic = topics[index]
        let other = topics[(index + 1) % topics.count]
        let third = topics[(index + 2) % topics.count]
        return """
        # \(topic.capitalized)

        The \(topic) plan, the \(other) plan and the \(third) plan are reviewed every 7 days.

        The \(topic) archive is kept next to the \(other) archive for the whole year.

        Anyone on the \(topic) crew can open the \(topic) folder and read the notes inside.

        A short \(topic) summary goes out on the first day of each month to the crew.

        """
    }

    @Test("A small edit costs a few dozen comparisons and a handful of model calls, not every pair in the workspace")
    func smallEditIsCheap() async throws {
        var files: [String: String] = [:]
        for index in Self.topics.indices {
            files["docs/\(Self.topics[index]).md"] = Self.note(index)
        }
        let fixture = try await ConflictFixture(files: files)
        defer { fixture.cleanUp() }
        let baseline = try await fixture.run()
        #expect(baseline.flagged == 0)

        // Edit one note: a copy of another note's first paragraph with a different number.
        let edited = "docs/\(Self.topics[5]).md"
        let target = Self.topics[7]
        let next = Self.topics[8], last = Self.topics[9]
        let added = "The \(target) plan, the \(next) plan and the \(last) plan are reviewed every 60 days."
        try fixture.notes.write(edited, Self.note(5) + "\n" + added + "\n")
        try await fixture.rescan(expecting: Set(files.keys))

        var options = ConflictRun.Options()
        options.measureFullCorpus = true
        let summary = try await fixture.run(options)
        print("""
        CONFLICTS cost: \(summary.corpusPassages) passages, a full pass is \(summary.fullCorpusPairs) pairs. \
        This run: \(summary.changedNotes) changed note, \(summary.nearbyNotes) nearby, \
        \(summary.detection.compared) pairs compared, \(summary.detection.candidates) candidates, \
        at most \(summary.detection.candidates) model calls, \(summary.flagged) flagged.
        """)
        #expect(summary.changedNotes == 1)
        #expect(summary.corpusPassages >= 160)
        #expect(summary.detection.compared * 20 < summary.fullCorpusPairs)
        // Only candidates can go to a model, so this is the most calls a run can make.
        #expect(summary.detection.candidates < 10)
        #expect(summary.flagged >= 1)
        let flags = fixture.state().flags
        #expect(flags.allSatisfy { $0.changed.path == edited })
        #expect(flags.contains { $0.other.path == "docs/\(target).md" })
    }
}
