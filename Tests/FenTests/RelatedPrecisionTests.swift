@testable import FenCore
import Foundation
import Testing

// A hand-labeled spot-check of "related documents" (issue #8) with the real on-device model.
// Each selection comes from a note about one topic. The relevant files are the others on that
// topic. R-precision asks: of the first R suggestions (R = how many files are relevant), how
// many are right? Set `FEN_SPIKE=1` to print the numbers.
// swiftlint:disable line_length
enum RelatedCorpus {
    static let documents: [String: String] = [
        "release-process.md": "# Release process\nTag the commit. The workflow builds the app, signs the archive, and uploads it to the release page.",
        "notarization.md": "# Notarization\nApple checks every signed app before people can open it. Submit the archive with your developer certificate and wait for the ticket.",
        "release-notes.md": "# Release notes\nAfter the tag is pushed, write the notes by hand on GitHub. List what changed for users, not for developers.",
        "password-manager.md": "# Password manager\nKeep one unique password per site in a manager, so a leak on one site does not open your other accounts.",
        "two-factor.md": "# Two-factor login\nTurn on a second step at sign in. A code from an authenticator app is safer than a text message.",
        "phishing.md": "# Phishing\nFake emails try to trick you into typing your login on a copy of a real site. Check the address before you sign in.",
        "tomatoes.md": "# Tomatoes\nPlant tomatoes after the last frost. Tie the stems to a stake and pinch off the side shoots.",
        "compost.md": "# Compost\nMix kitchen scraps with dry leaves. After a few months the pile turns into dark soil that feeds the vegetable beds.",
        "watering.md": "# Watering\nWater the beds early in the morning, at the roots and not on the leaves. A deep soak twice a week beats a light spray every day.",
        "running-plan.md": "# Running plan\nRaise the weekly distance by ten percent at most. Take one easy day after every long run.",
        "stretching.md": "# Stretching\nAfter a run, hold each leg stretch for thirty seconds. Loose calves and hamstrings prevent injury.",
        "lisbon-trip.md": "# Trip to Lisbon\nBook the flight and the hotel for spring. Ride the old tram and take a day trip to the coast.",
        "tax-forms.md": "# Tax forms\nCollect your income statements and receipts. File the yearly return before the deadline.",
        "api-versioning.md": "# API versioning\nPut the version in the URL. Document every endpoint, its fields, and the status codes it returns.",
        "book-list.md": "# Book list\nA novel about a lighthouse keeper and a history of the printing press are on the list for winter.",
    ]

    /// Text you might select while writing, and the files that are about the same thing.
    static let selections: [(text: String, relevant: Set<String>)] = [
        (
            "We tag the commit and the pipeline signs the build before uploading it",
            ["release-process.md", "notarization.md", "release-notes.md"]
        ),
        (
            "Use a manager so each site has its own login, and add a second factor",
            ["password-manager.md", "two-factor.md", "phishing.md"]
        ),
        (
            "Water the vegetable beds early and feed the soil with kitchen scraps",
            ["tomatoes.md", "compost.md", "watering.md"]
        ),
        ("Build up the weekly mileage slowly and loosen the legs after each run", ["running-plan.md", "stretching.md"]),
        ("Booking flights and a hotel for the city break next spring", ["lisbon-trip.md"]),
        ("Which endpoints return which status codes in the web interface", ["api-versioning.md"]),
        ("Fill in the yearly return before the deadline", ["tax-forms.md"]),
        ("Novels I want to read this winter", ["book-list.md"]),
    ]
}

// swiftlint:enable line_length

@Suite("Related documents precision with the Apple embedder (issue #8)", .serialized)
@MainActor
struct RelatedPrecisionTests {
    private let provider = AppleSentenceEmbeddingProvider()

    private struct Totals {
        var precision = 0.0
        var recallAt3 = 0.0
    }

    private func score(_ ranked: [String], relevant: Set<String>, into totals: inout Totals) {
        var seen = Set<String>()
        let files = ranked.filter { seen.insert($0).inserted }
        let top = files.prefix(relevant.count)
        totals.precision += Double(top.filter { relevant.contains($0) }.count) / Double(relevant.count)
        totals.recallAt3 += Double(files.prefix(3).filter { relevant.contains($0) }.count) / Double(relevant.count)
    }

    @Test("combined relatedness is at least as precise as words alone or meaning alone")
    func combinedBeatsParts() async throws {
        try #require(provider.isAvailable, "The on-device sentence model isn't installed on this machine.")
        let home = try TempHome()
        let folder = try TempFolder("related-precision")
        defer { home.cleanUp()
            folder.cleanUp()
        }
        for (path, text) in RelatedCorpus.documents {
            try folder.write(path, text + "\n")
        }
        try folder.write("scratch.md", "# Scratch\nThe page you are writing.\n")
        let library = WorkspaceLibrary(home: home.home, watching: false, embedder: provider)
        let workspace = try library.add(folder: folder.root)
        let total = RelatedCorpus.documents.count + 1
        let ready = try await pollUntilTrue(timeout: .seconds(120)) {
            let status = library.indexStatus(for: workspace.id)
            return status.phase == .idle && status.documents == total && status.isSemantic
        }
        try #require(ready)
        let index = try #require(library.search.indexes[workspace.id])

        var words = Totals(), meaning = Totals(), combined = Totals()
        for (text, relevant) in RelatedCorpus.selections {
            let keywords = RelatedQuery.keywords(from: text)
            let wordHits = try await index.textCandidates(matching: keywords, anyWord: true, limit: 50)
            score(wordHits.map(\.path), relevant: relevant, into: &words)
            let vector = try await index.vectorCandidates(
                for: VectorCodec.normalized(provider.embed(text)) ?? [],
                limit: 50
            )
            score(
                vector.filter { $0.score >= Double(provider.similarityFloor) }.map(\.path),
                relevant: relevant, into: &meaning
            )
            let related = await library.related(to: text, from: "scratch.md", in: workspace, limit: 5)
            score(related.map(\.relativePath), relevant: relevant, into: &combined)
        }
        let count = Double(RelatedCorpus.selections.count)
        print(
            "RELATED R-precision words \(words.precision / count) meaning \(meaning.precision / count) combined \(combined.precision / count)"
                +
                " | recall@3 words \(words.recallAt3 / count) meaning \(meaning.recallAt3 / count) combined \(combined.recallAt3 / count)"
        )
        #expect(combined.precision >= words.precision)
        #expect(combined.precision >= meaning.precision)
        #expect(combined.precision / count >= 0.7)
        #expect(combined.recallAt3 / count >= 0.7)
    }
}
