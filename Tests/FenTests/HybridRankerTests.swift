@testable import FenCore
import Foundation
import Testing

@Suite("HybridRanker")
struct HybridRankerTests {
    private let workspace = UUID()

    private func text(_ id: Int64, _ path: String, score: Double, inbound: Int = 0) -> TextCandidate {
        TextCandidate(
            chunkID: id,
            path: path,
            title: path,
            heading: "",
            startLine: 1,
            snippet: "words \(path)",
            inbound: inbound,
            score: score
        )
    }

    private func meaning(_ id: Int64, _ path: String, score: Double, inbound: Int = 0) -> VectorCandidate {
        VectorCandidate(
            chunkID: id,
            path: path,
            title: path,
            heading: "",
            startLine: 1,
            snippet: "meaning \(path)",
            inbound: inbound,
            score: score
        )
    }

    private func rank(
        text: [TextCandidate] = [],
        meaning: [VectorCandidate] = [],
        floor: Float = 0.3,
        origin: SearchOrigin? = nil,
        limit: Int = 10
    ) -> [SearchResult] {
        HybridRanker.rank(
            [WorkspaceCandidates(workspaceID: workspace, workspaceName: "W", text: text, vector: meaning)],
            similarityFloor: floor,
            origin: origin,
            limit: limit
        )
    }

    @Test("a file found both ways beats files found one way")
    func agreementWins() {
        let results = rank(
            text: [text(1, "words-only.md", score: 9), text(2, "both.md", score: 8)],
            meaning: [meaning(3, "meaning-only.md", score: 0.9), meaning(2, "both.md", score: 0.8)]
        )
        #expect(results.map(\.relativePath).first == "both.md")
        #expect(results.first?.match == .both)
        #expect(Set(results.map(\.relativePath)) == ["both.md", "words-only.md", "meaning-only.md"])
        #expect(results.first { $0.relativePath == "words-only.md" }?.match == .words)
        #expect(results.first { $0.relativePath == "meaning-only.md" }?.match == .meaning)
    }

    @Test("meaning matches under the floor are dropped")
    func floor() {
        let results = rank(meaning: [meaning(1, "close.md", score: 0.7), meaning(2, "noise.md", score: 0.2)])
        #expect(results.map(\.relativePath) == ["close.md"])
    }

    @Test("one file appears once, with its best chunk")
    func oneResultPerFile() {
        let results = rank(text: [text(1, "a.md", score: 9), text(2, "a.md", score: 8), text(3, "b.md", score: 7)])
        #expect(results.map(\.relativePath) == ["a.md", "b.md"])
        #expect(results[0].snippet == "words a.md")
    }

    @Test("links break a tie, but never beat a clearly better match")
    func linkBoost() {
        let tied = rank(text: [text(1, "plain.md", score: 5), text(2, "linked.md", score: 4.99, inbound: 20)])
        #expect(tied.first?.relativePath == "linked.md")
        let ahead = rank(text: [
            text(1, "best.md", score: 9),
            text(2, "ok.md", score: 5),
            text(3, "linked.md", score: 1, inbound: 500),
        ])
        #expect(ahead.first?.relativePath == "best.md")
    }

    @Test("files near the one you are in rank a little higher, only in the same workspace")
    func proximity() {
        let candidates = [text(1, "far/x.md", score: 5), text(2, "docs/guides/y.md", score: 4.99)]
        let near = rank(
            text: candidates,
            origin: SearchOrigin(workspaceID: workspace, relativePath: "docs/guides/z.md")
        )
        #expect(near.first?.relativePath == "docs/guides/y.md")
        let elsewhere = rank(
            text: candidates,
            origin: SearchOrigin(workspaceID: UUID(), relativePath: "docs/guides/z.md")
        )
        #expect(elsewhere.first?.relativePath == "far/x.md")
    }

    @Test("results from several workspaces merge into one list that names each workspace")
    func merge() {
        let other = UUID()
        let results = HybridRanker.rank(
            [
                WorkspaceCandidates(
                    workspaceID: workspace,
                    workspaceName: "Notes",
                    text: [text(1, "a.md", score: 5)],
                    vector: []
                ),
                WorkspaceCandidates(
                    workspaceID: other,
                    workspaceName: "Work",
                    text: [text(1, "a.md", score: 9)],
                    vector: []
                ),
            ],
            similarityFloor: 0,
            origin: nil,
            limit: 10
        )
        #expect(results.map(\.workspaceName) == ["Work", "Notes"])
        #expect(Set(results.map(\.id)).count == 2)
    }

    @Test("the limit applies, and empty input gives nothing")
    func limit() {
        #expect(rank(text: (1 ... 20).map { text(Int64($0), "f\($0).md", score: Double($0)) }, limit: 5).count == 5)
        #expect(rank().isEmpty)
    }
}
