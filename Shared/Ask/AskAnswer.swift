import Foundation

/// The prompt for a question, and the check of the answer that comes back (issue #141).
enum AskPrompt {
    static let notFound = "Not found in the selected workspaces."
    /// The most passage text sent to a model. Keeps small on-device models inside their window.
    static let maxCharacters = 6000

    /// The passages that fit the budget, in rank order. The best one always stays.
    static func fitting(_ passages: [Passage]) -> [Passage] {
        var total = 0
        var kept: [Passage] = []
        for passage in passages {
            total += passage.text.count
            if total > maxCharacters, !kept.isEmpty {
                break
            }
            kept.append(passage)
        }
        return kept
    }

    /// One numbered document per passage. The number is what the answer cites.
    static func context(for passages: [Passage]) -> [AIContextItem] {
        passages.enumerated().map { offset, passage in
            let heading = passage.heading.isEmpty ? "" : " > \(passage.heading)"
            return AIContextItem(
                workspaceID: passage.workspaceID,
                label: "[\(offset + 1)] \(passage.workspaceName)/\(passage.relativePath)\(heading)",
                text: passage.text
            )
        }
    }

    static func prompt(question: String) -> String {
        """
        Answer the question using only the numbered documents above. \
        After every statement, cite the document it came from by its number in square brackets, like [1] or [2]. \
        Do not use any other source. If the documents do not answer the question, reply with exactly: \
        \(notFound)

        Question: \(question)
        """
    }
}

/// What an answer cites, and whether those citations hold up.
struct AnswerReading: Equatable {
    /// Passage numbers (1-based) the answer cites, in order, without repeats.
    var cited: [Int] = []
    /// Numbers the answer cites that match no passage. They are never shown as links.
    var invalid: [Int] = []
    /// Lines of the answer that make a statement but cite nothing.
    var uncited = 0
    var isNotFound = false

    static func read(_ answer: String, passageCount: Int) -> AnswerReading {
        var reading = AnswerReading()
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix(AskPrompt.notFound.lowercased().dropLast()) {
            reading.isNotFound = true
            return reading
        }
        for line in trimmed.split(separator: "\n") {
            let numbers = citations(in: String(line))
            for number in numbers.map(\.number) {
                if (1 ... passageCount).contains(number) {
                    if !reading.cited.contains(number) {
                        reading.cited.append(number)
                    }
                } else if !reading.invalid.contains(number) {
                    reading.invalid.append(number)
                }
            }
            let hasValid = numbers.contains { (1 ... passageCount).contains($0.number) }
            if !hasValid, wordCount(line) >= 4 {
                reading.uncited += 1
            }
        }
        return reading
    }

    /// Each `[n]` or `[n, m]` in `text`, with its range. `[1, 2]` gives two entries.
    static func citations(in text: String) -> [(number: Int, range: Range<String.Index>)] {
        guard let expression = try? NSRegularExpression(pattern: #"\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\]"#) else {
            return []
        }
        var found: [(Int, Range<String.Index>)] = []
        let whole = NSRange(text.startIndex..., in: text)
        for match in expression.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text),
                  let inner = Range(match.range(at: 1), in: text) else { continue }
            for part in text[inner].split(separator: ",") {
                if let number = Int(part.trimmingCharacters(in: .whitespaces)) {
                    found.append((number, range))
                }
            }
        }
        return found
    }

    private static func wordCount(_ line: Substring) -> Int {
        line.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    /// The answer with each valid citation turned into a link `fen-passage://n`.
    static func linked(_ answer: String, passageCount: Int) -> AttributedString {
        var text = AttributedString(answer)
        for citation in citations(in: answer) where (1 ... passageCount).contains(citation.number) {
            guard let start = AttributedString.Index(citation.range.lowerBound, within: text),
                  let end = AttributedString.Index(citation.range.upperBound, within: text) else { continue }
            text[start ..< end].link = URL(string: "fen-passage://\(citation.number)")
        }
        return text
    }
}
