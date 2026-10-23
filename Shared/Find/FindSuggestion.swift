import Foundation

/// "Did you mean": the word in the note closest to a query that matched nothing.
public enum FindSuggestion {
    /// The most common word within a couple of typing mistakes of `query`, or nil. Only single words
    /// of four letters or more get a suggestion, and a word equal to the query never does.
    public static func nearest(to query: String, in text: String) -> String? {
        let target = fold(query)
        guard target.count >= 4, !target.contains(where: \.isWhitespace) else { return nil }
        let allowed = target.count <= 5 ? 1 : 2

        var counts: [String: Int] = [:]
        var word = String.UnicodeScalarView()
        func flush() {
            defer { word.removeAll() }
            guard word.count >= 3, abs(word.count - target.count) <= allowed, counts.count < 100_000 else { return }
            counts[fold(String(word)), default: 0] += 1
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                word.append(scalar)
            } else {
                flush()
            }
        }
        flush()

        let candidates = counts.compactMap { entry -> (word: String, distance: Int, count: Int)? in
            guard entry.key != target else { return nil }
            let distance = SchemaHints.editDistance(target, entry.key)
            return distance <= allowed ? (entry.key, distance, entry.value) : nil
        }
        return candidates.min {
            ($0.distance, -$0.count, $0.word) < ($1.distance, -$1.count, $1.word)
        }?.word
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
