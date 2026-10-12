@testable import FenCore
import Foundation
import Testing

@Suite("Finding passages that may disagree (issue #94)")
@MainActor
struct ConflictDetectorTests {
    private func detector(
        _ options: ConflictDetector.Options = .init(),
        embedder: FakeEmbedder = FakeEmbedder()
    ) -> ConflictDetector {
        ConflictDetector(options: options) { text in
            guard let raw = try? await embedder.embed(text) else { return nil }
            return VectorCodec.normalized(raw)
        }
    }

    private func passages(_ text: String) -> [ConflictPassage] {
        ConflictPassage.split(text)
    }

    @Test("Two passages on one topic with a different number make a candidate with a reason")
    func contradiction() async {
        var detector = detector()
        let found = await detector.candidates(
            changed: passages("We ship the release every 2 weeks on Thursday."),
            in: "a.md",
            neighbors: [(path: "b.md", text: "We ship the release every 4 weeks on Thursday.")]
        )
        #expect(found.count == 1)
        #expect(found.first?.other.path == "b.md")
        #expect(found.first?.signals.reasons.contains { $0.contains("numbers differ") } == true)
        #expect(detector.stats.candidates == 1)
    }

    @Test("A passage on another topic is never a candidate")
    func differentTopic() async {
        var detector = detector()
        let found = await detector.candidates(
            changed: passages("We ship the release every 2 weeks on Thursday."),
            in: "a.md",
            neighbors: [(path: "b.md", text: "The cat sleeps on the kitchen chair for 4 hours.")]
        )
        #expect(found.isEmpty)
        #expect(detector.stats.related == 0)
    }

    @Test("Passages on one topic that agree are dropped before any model sees them, with the near-copy rule off")
    func agreeing() async {
        var options = ConflictDetector.Options()
        options.strongSimilarity = 1.1
        var detector = detector(options)
        let found = await detector.candidates(
            changed: passages("We ship the release on Thursday, after a final check."),
            in: "a.md",
            neighbors: [(path: "b.md", text: "After a final check we publish the release on Thursday.")]
        )
        #expect(found.isEmpty)
        #expect(detector.stats.related == 1)
    }

    @Test("A near copy goes on even with no mark, because it may have drifted")
    func nearCopy() async {
        var detector = detector()
        let found = await detector.candidates(
            changed: passages("We ship the release on Thursday, after a final check."),
            in: "a.md",
            neighbors: [(path: "b.md", text: "We ship the release on Thursday, after a final test.")]
        )
        #expect(found.count == 1)
        #expect(found.first?.signals == ConflictSignals.none)
    }

    @Test("A note is never compared with itself or with an identical passage")
    func skipsSelf() async {
        var detector = detector()
        let text = "We ship the release every 2 weeks on Thursday."
        let found = await detector.candidates(
            changed: passages(text),
            in: "a.md",
            neighbors: [
                (path: "a.md", text: "We ship the release every 4 weeks on Thursday."),
                (path: "b.md", text: text),
            ]
        )
        #expect(found.isEmpty)
        #expect(detector.stats.compared == 0)
    }

    @Test("Each passage is embedded once, however many times it is compared")
    func cachesVectors() async {
        let embedder = FakeEmbedder()
        var detector = detector(embedder: embedder)
        let neighbor = "We ship the release every 4 weeks on Thursday."
        _ = await detector.candidates(
            changed: passages(
                "We ship the release every 2 weeks on Thursday.\n\nWe publish the release every 3 weeks on Friday."
            ),
            in: "a.md",
            neighbors: [(path: "b.md", text: neighbor), (path: "c.md", text: neighbor)]
        )
        #expect(embedder.calls == 3)
        #expect(detector.stats.embedded == 3)
        #expect(detector.stats.compared == 4)
    }

    @Test("The best candidates come first")
    func ranked() async {
        var detector = detector()
        let found = await detector.candidates(
            changed: passages("We do not ship the release every 2 weeks on Thursday."),
            in: "a.md",
            neighbors: [
                (path: "weak.md", text: "We ship the release on Thursday, after a final check of all work."),
                (path: "strong.md", text: "We ship the release every 4 weeks on Thursday."),
            ]
        )
        #expect(found.first?.other.path == "strong.md")
        #expect(found.map(\.rank) == found.map(\.rank).sorted(by: >))
    }

    @Test("A note with no on-device vectors gives no candidates")
    func noEmbedder() async {
        var detector = ConflictDetector { _ in nil }
        let found = await detector.candidates(
            changed: passages("We ship the release every 2 weeks on Thursday."),
            in: "a.md",
            neighbors: [(path: "b.md", text: "We ship the release every 4 weeks on Thursday.")]
        )
        #expect(found.isEmpty)
    }

    @Test("Only the first passages of a long neighbor are compared")
    func capsPassages() async {
        var options = ConflictDetector.Options()
        options.maxPassagesPerNote = 2
        var detector = detector(options)
        let many = (1 ... 6).map { "We ship the release every \($0 + 10) weeks on Thursday." }.joined(separator: "\n\n")
        _ = await detector.candidates(
            changed: passages("We ship the release every 2 weeks on Thursday."),
            in: "a.md",
            neighbors: [(path: "b.md", text: many)]
        )
        #expect(detector.stats.compared == 2)
    }
}
