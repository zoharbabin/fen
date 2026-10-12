import Foundation

/// The cheap check in the first tier of conflict detection (issue #94). It reads two passages that
/// are about the same thing and looks for the marks of a contradiction. It runs on the device, calls
/// no model, and is a filter, not a verdict: a passage pair that shows no mark never reaches the
/// model, and one that shows a mark is only a candidate.
struct ConflictSignals: Equatable {
    /// 0 to 1. The sum of the marks found, capped.
    var score: Double
    /// One plain line per mark, in the order found.
    var reasons: [String]

    static let none = ConflictSignals(score: 0, reasons: [])

    private static let negations: Set<String> = [
        "not", "no", "never", "cannot", "can't", "won't", "isn't", "aren't", "don't", "doesn't", "didn't",
        "without", "none", "nor", "neither", "wasn't", "weren't", "shouldn't", "wouldn't", "couldn't",
    ]

    /// Pairs that mean opposite things. Matched as whole words, either way round.
    private static let opposites: [(String, String)] = [
        ("enable", "disable"), ("enabled", "disabled"), ("allow", "forbid"), ("allowed", "forbidden"),
        ("accept", "reject"), ("accepted", "rejected"), ("approved", "rejected"), ("increase", "decrease"),
        ("required", "optional"), ("always", "never"), ("use", "avoid"), ("yes", "no"), ("open", "closed"),
        ("public", "private"), ("sync", "async"), ("before", "after"), ("faster", "slower"), ("more", "less"),
        ("on", "off"), ("start", "stop"), ("include", "exclude"), ("win", "lose"), ("buy", "sell"),
    ]

    /// Words in the changed passage that say it replaces an older statement.
    private static let changeCues = [
        "no longer", "instead of", "replaced", "replaces", "switched to", "switch to", "deprecated", "dropped",
        "reverted", "superseded", "changed to", "moved to", "we now", "now uses", "decided to",
    ]

    /// Compares the passage that changed with a passage elsewhere. The cues about change count only
    /// for `changed`: it is the one being updated.
    static func compare(changed: String, other: String) -> ConflictSignals {
        let lhs = words(changed)
        let rhs = words(other)
        var score = 0.0
        var reasons: [String] = []

        if polarity(lhs) != polarity(rhs) {
            score += 0.35
            reasons.append("One says no or not, the other doesn't.")
        }
        let numbersA = numbers(in: changed)
        let numbersB = numbers(in: other)
        if !numbersA.isEmpty, !numbersB.isEmpty, numbersA.isDisjoint(with: numbersB) {
            score += 0.35
            let shown = { (set: Set<String>) in set.sorted().prefix(3).joined(separator: ", ") }
            reasons.append("The numbers differ: \(shown(numbersA)) and \(shown(numbersB)).")
        }
        let setA = Set(lhs)
        let setB = Set(rhs)
        for (first, second) in opposites {
            if (setA.contains(first) && setB.contains(second) && !setA.contains(second) && !setB.contains(first))
                || (setA.contains(second) && setB.contains(first) && !setA.contains(first) && !setB.contains(second)) {
                score += 0.3
                reasons.append("“\(first)” and “\(second)” point opposite ways.")
                break
            }
        }
        let lowered = changed.lowercased()
        if let cue = changeCues.first(where: { lowered.contains($0) }) {
            score += 0.2
            reasons.append("The new text says something changed (“\(cue)”).")
        }
        return ConflictSignals(score: min(1, score), reasons: reasons)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    /// Odd when the passage negates once, even when it negates twice or not at all.
    private static func polarity(_ words: [String]) -> Bool {
        words.filter { negations.contains($0) }.count % 2 == 1
    }

    /// Numbers, versions and percentages as written, such as `30`, `2.5`, `v2`, `45%`.
    private static func numbers(in text: String) -> Set<String> {
        var found = Set<String>()
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            if trimmed.contains(where: \.isNumber) {
                found.insert(trimmed.lowercased())
            }
            current = ""
        }
        for character in text {
            if character
                .isNumber || (!current.isEmpty && ".,%".contains(character) && current.contains(where: \.isNumber)) {
                current.append(character)
            } else if character.isLetter, current.isEmpty || current.allSatisfy(\.isLetter), "vV".contains(character) {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return found
    }
}
