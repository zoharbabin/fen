@testable import FenCore
import Foundation
import Testing

/// A hand-labeled spot-check of type classification (issue #11) with the real on-device model, using
/// the starter types. Set `FEN_SPIKE=1` to print each verdict. The real model differs between OS
/// versions, so the checks are loose.
@Suite("Type classification with the on-device model (issue #11)", .serialized)
@MainActor
struct TypeClassifierPrecisionTests {
    struct Labeled {
        let name: String
        let text: String
        let type: String

        init(_ name: String, _ text: String, _ type: String) {
            self.name = name
            self.text = text
            self.type = type
        }
    }

    struct Outcome {
        let name: String
        let expected: String
        let verdict: TypeVerdict
    }

    // swiftlint:disable line_length
    static let labeled: [Labeled] = [
        Labeled(
            "jane",
            "# Jane Doe\n\nProduct manager at Acme. We met at the conference. Her email is jane@acme.com and she prefers calls in the morning.",
            "Person"
        ),
        Labeled(
            "carlos",
            "# Carlos Ruiz\n\nOld colleague, now an engineering lead. Last spoke in March about his move to a new team.",
            "Person"
        ),
        Labeled(
            "standup",
            "# Weekly sync\n\nAttendees: Sam, Priya. We talked about the launch date and agreed on next steps. Action items for each person.",
            "Meeting"
        ),
        Labeled(
            "kickoff",
            "# Kickoff call\n\nNotes from the call with the vendor. Who joined, what was decided, and what happens next.",
            "Meeting"
        ),
        Labeled(
            "website",
            "# Website redesign\n\nGoal: ship the new site by autumn. Milestones, owner, and the budget for the project.",
            "Project"
        ),
        Labeled(
            "migration",
            "# Database migration project\n\nThe goal is to move all services to the new cluster. Phase one ends in June.",
            "Project"
        ),
        Labeled(
            "renew",
            "# Renew passport\n\nBring photos and the old passport to the office. Do this before the trip.",
            "Task"
        ),
        Labeled(
            "invoice",
            "# Send the invoice\n\nSend the March invoice to the client by Friday. Priority: high.",
            "Task"
        ),
        Labeled(
            "tuesday",
            "# Tuesday\n\nWoke up late, walked by the river. Felt calm and a bit tired. Dinner with friends in the evening.",
            "Journal"
        ),
        Labeled(
            "sunday",
            "# Sunday evening\n\nA slow day at home. I read a few chapters and thought about the week ahead. Mood: good.",
            "Journal"
        ),
        Labeled(
            "paper",
            "# Attention is all you need\n\nA paper by Vaswani et al. about the transformer. Source: arXiv. Useful to look up the attention formula.",
            "Reference"
        ),
        Labeled(
            "rfc",
            "# HTTP caching RFC\n\nThe standard that defines cache headers. Link and notes on what each header means, to look up later.",
            "Reference"
        ),
    ]
    // swiftlint:enable line_length

    private static func unit(_ text: String, _ provider: AppleSentenceEmbeddingProvider) async -> [Float]? {
        guard let raw = try? await provider.embed(text) else { return nil }
        return VectorCodec.normalized(raw)
    }

    /// With `withExamples`, each document is classified by a classifier that also knows the other
    /// labeled document of its type, as a workspace with typed notes would.
    private func verdicts(withExamples: Bool) async throws -> [Outcome]? {
        let provider = AppleSentenceEmbeddingProvider()
        guard provider.isAvailable else { return nil }
        var vectors: [String: [Float]] = [:]
        for item in Self.labeled {
            vectors[item.name] = try #require(await Self.unit(
                TypeClassifier.excerpt(of: item.text, path: item.name + ".md"), provider
            ))
        }
        var out: [Outcome] = []
        for item in Self.labeled {
            var examples: [String: [[Float]]] = [:]
            if withExamples {
                for other in Self.labeled where other.name != item.name {
                    examples[other.type, default: []].append(vectors[other.name] ?? [])
                }
            }
            let classifier = try #require(await TypeClassifier.build(
                types: SchemaStarters.universal, floor: provider.similarityFloor, examples: examples
            ) { await Self.unit($0, provider) })
            let verdict = try classifier.verdict(for: #require(vectors[item.name]))
            out.append(Outcome(name: item.name, expected: item.type, verdict: verdict))
        }
        return out
    }

    @Test("with typed notes as examples, confident answers are right, and the right type is among the close calls")
    func precisionWithExamples() async throws {
        guard let results = try await verdicts(withExamples: true) else { return }
        var confident = 0, confidentRight = 0, closeCalls = 0, closeContains = 0, none = 0
        for result in results {
            let (name, expected, verdict) = (result.name, result.expected, result.verdict)
            switch verdict {
            case let .confident(score, margin):
                confident += 1
                confidentRight += score.name == expected ? 1 : 0
                log("\(name): confident \(score.name) \(score.score) margin \(margin) expected \(expected)")
            case let .ambiguous(scores):
                closeCalls += 1
                closeContains += scores.contains { $0.name == expected } ? 1 : 0
                log("\(name): ambiguous \(scores.map { "\($0.name) \($0.score)" }) expected \(expected)")
            case .none:
                none += 1
                log("\(name): none expected \(expected)")
            }
        }
        log("confident \(confidentRight)/\(confident), close \(closeContains)/\(closeCalls), none \(none)")
        if confident > 0 {
            #expect(Double(confidentRight) / Double(confident) >= 0.6)
        }
        if closeCalls > 0 {
            #expect(Double(closeContains) / Double(closeCalls) >= 0.4)
        }
    }

    private func log(_ line: String) {
        if ProcessInfo.processInfo.environment["FEN_SPIKE"] == "1" {
            print("[types] " + line)
        }
    }
}
