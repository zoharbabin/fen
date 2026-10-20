import Foundation

/// Inline math (issue #250). cmark-gfm strips backslashes (`\$` -> `$`, `\(` -> `(`) and reads `_`/`*` inside a
/// formula as emphasis, so MathJax can't find the formulas in its output. This pass finds them in the source
/// instead, with the rules Live Preview already uses (`LivePreviewInlineMath.swift`), hides each behind a
/// placeholder while cmark runs, and puts it back as `\(...\)`, the one inline delimiter MathJax reads.
extension MarkdownRenderer {
    private static let placeholderOpen = "\u{E000}fenmath"
    private static let placeholderClose = "\u{E001}"
    private static let placeholderPattern = placeholderOpen + "(\\d+)" + placeholderClose

    /// Replaces each inline formula in `markdown` with a placeholder and returns the formulas, delimiters included.
    /// Skips fenced code, indented code and inline code. Line count never changes.
    func hideInlineMath(
        in markdown: String, delimiters: LivePreviewEditing.MathDelimiters
    ) -> (text: String, formulas: [String]) {
        guard !delimiters.isEmpty else { return (markdown, []) }
        var formulas: [String] = []
        var fence: (marker: Character, length: Int)?
        var previousBlank = true
        var previousIndentedCode = false
        var inList = false
        var lines = markdown.components(separatedBy: "\n")

        for index in lines.indices {
            let line = lines[index]
            let indent = Self.indentWidth(of: line)
            let blank = line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
            defer { previousBlank = blank }

            if let open = fence {
                if Self.closesFence(line, indent: indent, open: open) {
                    fence = nil
                }
                continue
            }
            if !blank, indent < 4, let opened = Self.fenceOpening(line) {
                fence = opened
                previousIndentedCode = false
                continue
            }
            if !blank, indent == 0, previousBlank, !Self.startsListItem(line) {
                inList = false
            }
            if !blank, indent < 4, Self.startsListItem(line) {
                inList = true
            }
            let indentedCode = !blank && indent >= 4 && !inList && (previousBlank || previousIndentedCode)
            previousIndentedCode = indentedCode || (blank && previousIndentedCode)
            if blank || indentedCode {
                continue
            }

            lines[index] = hideInlineMath(inLine: line, delimiters: delimiters, formulas: &formulas)
        }
        return (lines.joined(separator: "\n"), formulas)
    }

    /// Puts each formula back where `hideInlineMath` took it out, as `\(...\)` with the TeX HTML-escaped.
    func restoreInlineMath(in html: String, formulas: [String]) -> String {
        guard !formulas.isEmpty,
              let regex = try? NSRegularExpression(pattern: Self.placeholderPattern)
        else { return html }
        let nsHTML = html as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            guard let index = Int(nsHTML.substring(with: match.range(at: 1))), formulas.indices.contains(index)
            else { continue }
            result += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += Self.escapeForHTML(Self.mathJaxSource(formulas[index]))
            cursor = match.range.location + match.range.length
        }
        return result + nsHTML.substring(from: cursor)
    }

    // MARK: - One line

    private func hideInlineMath(
        inLine line: String, delimiters: LivePreviewEditing.MathDelimiters, formulas: inout [String]
    ) -> String {
        let ns = line as NSString
        var result = ""
        var plainStart = 0
        var cursor = 0
        while cursor < ns.length {
            let character = ns.character(at: cursor)
            if let (span, next) = LivePreviewEditing.matchInlineMath(
                ns, at: cursor, textStart: 0, delimiters: delimiters
            ), case let .inlineMath(source) = span.kind {
                result += ns.substring(with: NSRange(location: plainStart, length: cursor - plainStart))
                result += Self.placeholderOpen + String(formulas.count) + Self.placeholderClose
                formulas.append(source)
                cursor = next
                plainStart = next
            } else if character == Self.backslash {
                cursor += 2
            } else if character == Self.backtick {
                cursor = Self.endOfCodeSpan(ns, from: cursor)
            } else {
                cursor += 1
            }
        }
        return result + ns.substring(from: min(plainStart, ns.length))
    }

    // MARK: - Block structure

    private static let backslash = UInt16(UnicodeScalar("\\").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)

    /// The index after the code span that opens at `start`, or after the backtick run if nothing closes it.
    private static func endOfCodeSpan(_ ns: NSString, from start: Int) -> Int {
        var runEnd = start
        while runEnd < ns.length, ns.character(at: runEnd) == backtick {
            runEnd += 1
        }
        let runLength = runEnd - start
        var cursor = runEnd
        while cursor < ns.length {
            guard ns.character(at: cursor) == backtick else {
                cursor += 1
                continue
            }
            var closeEnd = cursor
            while closeEnd < ns.length, ns.character(at: closeEnd) == backtick {
                closeEnd += 1
            }
            if closeEnd - cursor == runLength {
                return closeEnd
            }
            cursor = closeEnd
        }
        return runEnd
    }

    /// Leading width in columns: a tab counts as 4.
    private static func indentWidth(of line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }

    private static func fenceOpening(_ line: String) -> (marker: Character, length: Int)? {
        let trimmed = line.drop { $0 == " " }
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        // A backtick fence's info string can't hold a backtick, or it's an inline code span.
        if marker == "`", trimmed.dropFirst(length).contains("`") {
            return nil
        }
        return (marker, length)
    }

    private static func closesFence(_ line: String, indent: Int, open: (marker: Character, length: Int)) -> Bool {
        guard indent < 4 else { return false }
        let trimmed = line.drop { $0 == " " }
        let length = trimmed.prefix { $0 == open.marker }.count
        return length >= open.length && trimmed.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private static func startsListItem(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        if let first = trimmed.first, "-*+".contains(first) {
            return trimmed.dropFirst().first.map { $0 == " " || $0 == "\t" } ?? false
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard (1 ... 9).contains(digits.count) else { return false }
        let rest = trimmed.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return false }
        return rest.dropFirst().first.map { $0 == " " || $0 == "\t" } ?? false
    }

    // MARK: - Output

    /// MathJax takes `\(...\)`, so a `$...$` formula is rewritten to it.
    static func mathJaxSource(_ formula: String) -> String {
        guard formula.hasPrefix("$"), formula.hasSuffix("$"), formula.count >= 2 else { return formula }
        return "\\(" + formula.dropFirst().dropLast() + "\\)"
    }

    private static func escapeForHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
