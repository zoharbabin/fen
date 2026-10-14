import Foundation

public extension LivePreviewEditing {
    /// Which inline math delimiters Live Preview looks for. They follow the preview's MathJax setup: `\( \)` always,
    /// `$ $` only when `htmlMathJaxInlineDollar` is on.
    struct MathDelimiters: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let parentheses = MathDelimiters(rawValue: 1)
        public static let dollars = MathDelimiters(rawValue: 2)
    }
}

extension LivePreviewEditing {
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)

    /// Matches `\(…\)` or `$…$` at `index`, on one line. The span's `source` is the text as written, delimiters
    /// included, because that is what MathJax takes. `$` follows the usual rules, so prices don't turn into math:
    /// the opening `$` needs a non-space after it, the closing one a non-space before it and no digit after it. `$$` is
    /// display math, not this.
    /// A `\$` is an escaped dollar.
    static func matchInlineMath(
        _ ns: NSString, at index: Int, textStart: Int, delimiters: MathDelimiters
    ) -> (Span, Int)? {
        guard index < ns.length else { return nil }
        let first = ns.character(at: index)
        if first == backslash, delimiters.contains(.parentheses) {
            return matchParentheses(ns, at: index, textStart: textStart)
        }
        if first == dollar, delimiters.contains(.dollars) {
            return matchDollars(ns, at: index, textStart: textStart)
        }
        return nil
    }

    private static func matchParentheses(_ ns: NSString, at index: Int, textStart: Int) -> (Span, Int)? {
        let contentStart = index + 2
        guard contentStart < ns.length, ns.character(at: index + 1) == openParen else { return nil }
        let close = ns.range(of: "\\)", range: NSRange(location: contentStart, length: ns.length - contentStart))
        guard close.location != NSNotFound, close.location > contentStart else { return nil }
        return mathSpan(ns, open: index, openLength: 2, close: close.location, textStart: textStart)
    }

    private static func matchDollars(_ ns: NSString, at index: Int, textStart: Int) -> (Span, Int)? {
        if index > 0, [backslash, dollar].contains(ns.character(at: index - 1)) {
            return nil
        }
        let contentStart = index + 1
        guard contentStart < ns.length else { return nil }
        let next = ns.character(at: contentStart)
        guard next != dollar, !isSpace(next) else { return nil }
        var cursor = contentStart
        while cursor < ns.length {
            let character = ns.character(at: cursor)
            if character == 10 {
                return nil
            }
            if character == backslash {
                cursor += 2
                continue
            }
            if character == dollar {
                let after = cursor + 1 < ns.length ? ns.character(at: cursor + 1) : nil
                guard !isSpace(ns.character(at: cursor - 1)), after != dollar, !(after.map(isDigit) ?? false)
                else { return nil }
                return mathSpan(ns, open: index, openLength: 1, close: cursor, textStart: textStart)
            }
            cursor += 1
        }
        return nil
    }

    private static func mathSpan(
        _ ns: NSString, open: Int, openLength: Int, close: Int, textStart: Int
    ) -> (Span, Int)? {
        let contentStart = open + openLength
        let content = NSRange(location: contentStart, length: close - contentStart)
        guard !ns.substring(with: content).contains("\n") else { return nil }
        let end = close + openLength
        let span = Span(
            kind: .inlineMath(source: ns.substring(with: NSRange(location: open, length: end - open))),
            markerRanges: [
                NSRange(location: textStart + open, length: openLength),
                NSRange(location: textStart + close, length: openLength),
            ],
            contentRange: NSRange(location: textStart + contentStart, length: content.length)
        )
        return (span, end)
    }

    private static func isSpace(_ character: UInt16) -> Bool {
        character == 32 || character == 9 || character == 10 || character == 13
    }

    private static func isDigit(_ character: UInt16) -> Bool {
        character >= 48 && character <= 57
    }
}
