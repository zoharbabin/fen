import Foundation

/// Stashes a marker run's real foreground color/font before live-preview styling shrinks it to
/// near-invisible off-focus, mirroring `NSAttributedString.Key.focusModeOriginalForegroundColor`'s
/// stash-before-overwrite pattern (issue #19) so the reveal path can restore exactly, and
/// repeated hide/reveal calls never compound. Declared once here (not per-platform) since both
/// Coordinators' extensions read/write the same key names.
public extension NSAttributedString.Key {
    static let livePreviewOriginalForegroundColor = NSAttributedString.Key("FenLivePreviewOriginalForegroundColor")
    static let livePreviewOriginalFont = NSAttributedString.Key("FenLivePreviewOriginalFont")
    /// Marks a range this session's live-preview pass has ever touched, independent of whether
    /// it's currently hidden or revealed -- lets a full-document clear (disabling the toggle) find
    /// every range it needs to restore without re-deriving spans from the current text.
    static let livePreviewTouched = NSAttributedString.Key("FenLivePreviewTouched")
}

/// Pure, platform-independent live-preview (WYSIWYG-in-source) editing logic (issue #2):
/// detecting which ranges of a paragraph are markdown markers to hide off-focus, and which
/// ranges are content to style with the real visual weight/size/color the markup implies. Kept
/// separate from `MarkdownTextView`/`MarkdownTextView_iOS`'s Coordinator wiring, mirroring
/// `FocusModeEditing`'s existing pure-function pattern, so every rule is unit-testable without
/// constructing a real text view. This is a lightweight, single-pass heuristic layer, not a full
/// CommonMark parser (see issue #2's "Alternatives considered": the editor's `NSTextStorage` --
/// not a re-parsed AST -- is the single source of truth, so this only ever needs to recognize
/// enough structure to style it, never enough to round-trip it).
public enum LivePreviewEditing {
    /// Posted by `FenApp_macOS.swift`'s "Toggle Live Preview" menu command, mirroring
    /// `FocusModeEditing.toggleFocusModeNotification`'s pattern (issue #19 rule 5.3): a single
    /// notification name shared by the poster (FenMacOS) and the subscriber
    /// (`SplitEditorView`, in FenCore) since `editorLivePreviewEnabled` itself is `internal` and
    /// can't be mutated directly across that module boundary.
    public static let toggleLivePreviewNotification = Notification.Name("toggleLivePreview")

    public enum Kind: Equatable {
        case bold
        case italic
        case strikethrough
        case inlineCode
        case heading(level: Int)
        case blockquote
        case link(url: String)
        case checkbox(checked: Bool)
        case image(altText: String, path: String)
    }

    /// One markdown construct found within a paragraph: `markerRanges` are the delimiter/syntax
    /// characters to hide off-focus (rule: reveal-on-cursor); `contentRange` is where the
    /// construct's real visual style (bold font, header size, dimmed color, checkbox look, image
    /// attachment) applies.
    public struct Span: Equatable {
        public let kind: Kind
        public let markerRanges: [NSRange]
        public let contentRange: NSRange

        public init(kind: Kind, markerRanges: [NSRange], contentRange: NSRange) {
            self.kind = kind
            self.markerRanges = markerRanges
            self.contentRange = contentRange
        }
    }

    // MARK: - Block-level (line-prefix) constructs

    /// Detects a heading/blockquote/checkbox prefix at the very start of `line` (no trailing
    /// newline), if any. `lineStart` is that line's offset within the whole document/paragraph,
    /// added to every returned range so callers never need to re-offset.
    public static func blockPrefixSpan(line: String, lineStart: Int) -> Span? {
        let ns = line as NSString
        return checkboxSpan(ns, lineStart: lineStart)
            ?? headingSpan(ns, lineStart: lineStart)
            ?? blockquoteSpan(ns, lineStart: lineStart)
    }

    /// Matches exactly the two prefixes `MarkdownFormatting.apply(.taskItem, ...)` recognizes
    /// (`Shared/Editor/MarkdownFormatting.swift`'s `applyTaskItem`) -- rendering a checkbox as
    /// clickable that the toggle logic wouldn't actually recognize would silently corrupt the
    /// line on click instead of toggling it.
    private static func checkboxSpan(_ ns: NSString, lineStart: Int) -> Span? {
        if ns.hasPrefix("- [ ] ") {
            return checkboxSpanResult(lineStart: lineStart, checked: false)
        }
        if ns.hasPrefix("- [x] ") {
            return checkboxSpanResult(lineStart: lineStart, checked: true)
        }
        return nil
    }

    private static func checkboxSpanResult(lineStart: Int, checked: Bool) -> Span {
        Span(
            kind: .checkbox(checked: checked),
            markerRanges: [
                NSRange(location: lineStart, length: 2), // "- "
                NSRange(location: lineStart + 5, length: 1), // the space after "]"
            ],
            contentRange: NSRange(location: lineStart + 2, length: 3) // "[ ]" / "[x]"
        )
    }

    private static func headingSpan(_ ns: NSString, lineStart: Int) -> Span? {
        let hash = UInt16(UnicodeScalar("#").value)
        let space = UInt16(UnicodeScalar(" ").value)
        var level = 0
        while level < ns.length, level < 6, ns.character(at: level) == hash {
            level += 1
        }
        guard level > 0, level < ns.length, ns.character(at: level) == space else { return nil }
        let contentLength = ns.length - level - 1
        guard contentLength > 0 else { return nil }
        return Span(
            kind: .heading(level: level),
            markerRanges: [NSRange(location: lineStart, length: level + 1)],
            contentRange: NSRange(location: lineStart + level + 1, length: contentLength)
        )
    }

    private static func blockquoteSpan(_ ns: NSString, lineStart: Int) -> Span? {
        guard ns.length > 0, ns.character(at: 0) == UInt16(UnicodeScalar(">").value) else { return nil }
        let hasSpace = ns.length > 1 && ns.character(at: 1) == UInt16(UnicodeScalar(" ").value)
        let markerLength = hasSpace ? 2 : 1
        return Span(
            kind: .blockquote,
            markerRanges: [NSRange(location: lineStart, length: markerLength)],
            contentRange: NSRange(location: lineStart + markerLength, length: ns.length - markerLength)
        )
    }

    // MARK: - Inline constructs

    /// Scans `text` (typically one paragraph) for inline bold/italic/strikethrough/inline-code/
    /// link/image constructs, offsetting every returned range by `textStart`. A single
    /// left-to-right pass: once a delimiter run opens a construct, scanning resumes after its
    /// closing delimiter, so constructs never overlap or nest -- a deliberate limitation of this
    /// lightweight heuristic layer, not a full CommonMark parser.
    public static func inlineSpans(in text: String, textStart: Int) -> [Span] {
        let ns = text as NSString
        var spans: [Span] = []
        var index = 0
        while index < ns.length {
            if let (span, next) = matchImageOrLink(ns, at: index, textStart: textStart) {
                spans.append(span)
                index = next
                continue
            }
            if let (span, next) = matchWrapped(ns, at: index, textStart: textStart, delimiter: "`", kind: .inlineCode) {
                spans.append(span)
                index = next
                continue
            }
            if let (span, next) = matchWrapped(ns, at: index, textStart: textStart, delimiter: "**", kind: .bold)
                ?? matchWrapped(ns, at: index, textStart: textStart, delimiter: "__", kind: .bold) {
                spans.append(span)
                index = next
                continue
            }
            if let (span, next) = matchWrapped(
                ns, at: index, textStart: textStart, delimiter: "~~", kind: .strikethrough
            ) {
                spans.append(span)
                index = next
                continue
            }
            if let (span, next) = matchWrapped(ns, at: index, textStart: textStart, delimiter: "*", kind: .italic)
                ?? matchWrapped(ns, at: index, textStart: textStart, delimiter: "_", kind: .italic) {
                spans.append(span)
                index = next
                continue
            }
            index += 1
        }
        return spans
    }

    /// Matches a `delimiter...delimiter` run starting at `index`: finds the next occurrence of
    /// `delimiter` after at least one content character, and returns a span whose marker ranges
    /// are the two delimiter runs and whose content range is what's between them, plus the index
    /// just past the closing delimiter (so the caller resumes scanning there). Returns `nil` if
    /// `delimiter` doesn't literally start at `index`, no closing run exists, or the content
    /// between them would be empty.
    private static func matchWrapped(
        _ ns: NSString, at index: Int, textStart: Int, delimiter: String, kind: Kind
    ) -> (Span, Int)? {
        let delimiterLength = (delimiter as NSString).length
        guard index + delimiterLength <= ns.length,
              ns.substring(with: NSRange(location: index, length: delimiterLength)) == delimiter else { return nil }

        let searchStart = index + delimiterLength
        guard searchStart < ns.length else { return nil }

        let closing = ns.range(of: delimiter, range: NSRange(location: searchStart, length: ns.length - searchStart))
        guard closing.location != NSNotFound, closing.location > searchStart else { return nil }

        let span = Span(
            kind: kind,
            markerRanges: [
                NSRange(location: textStart + index, length: delimiterLength),
                NSRange(location: textStart + closing.location, length: delimiterLength),
            ],
            contentRange: NSRange(location: textStart + searchStart, length: closing.location - searchStart)
        )
        return (span, closing.location + delimiterLength)
    }

    /// Matches `![alt](path)` or `[text](url)` starting at `index`.
    private static func matchImageOrLink(_ ns: NSString, at index: Int, textStart: Int) -> (Span, Int)? {
        var cursor = index
        var isImage = false
        if cursor < ns.length, ns.character(at: cursor) == UInt16(UnicodeScalar("!").value) {
            isImage = true
            cursor += 1
        }
        guard cursor < ns.length, ns.character(at: cursor) == UInt16(UnicodeScalar("[").value) else { return nil }
        let labelStart = cursor + 1

        let closeBracket = ns.range(of: "]", range: NSRange(location: labelStart, length: ns.length - labelStart))
        guard closeBracket.location != NSNotFound else { return nil }
        let labelRange = NSRange(location: labelStart, length: closeBracket.location - labelStart)

        let afterBracket = closeBracket.location + 1
        guard afterBracket < ns.length, ns.character(at: afterBracket) == UInt16(UnicodeScalar("(").value) else {
            return nil
        }
        let urlStart = afterBracket + 1

        let closeParen = ns.range(of: ")", range: NSRange(location: urlStart, length: ns.length - urlStart))
        guard closeParen.location != NSNotFound else { return nil }
        let urlRange = NSRange(location: urlStart, length: closeParen.location - urlStart)

        let label = ns.substring(with: labelRange)
        let url = ns.substring(with: urlRange)
        let fullStart = isImage ? index : cursor
        let span = Span(
            kind: isImage ? .image(altText: label, path: url) : .link(url: url),
            markerRanges: [
                NSRange(location: textStart + fullStart, length: labelStart - fullStart),
                NSRange(location: textStart + closeBracket.location, length: 1),
                NSRange(location: textStart + afterBracket, length: 1),
                NSRange(location: textStart + urlRange.location, length: urlRange.length),
                NSRange(location: textStart + closeParen.location, length: 1),
            ],
            contentRange: NSRange(location: textStart + labelRange.location, length: labelRange.length)
        )
        return (span, closeParen.location + 1)
    }

    /// Rule 5.3: live preview must never touch table syntax, leaving `MarkdownFormatting`'s own
    /// table-insertion template as the only thing that ever shapes a pipe table's rendering. A
    /// line is treated as part of a table if it contains a `|` at all -- tables are the only
    /// construct built from that character, so this is a safe, simple signal without needing to
    /// track "am I inside a table" state across lines (this heuristic layer's deliberate
    /// limitation; see the type's own doc comment).
    public static func isTableRow(line: String) -> Bool {
        line.contains("|")
    }
}

/// Resolves a Markdown image reference's `path` for local-only, on-disk loading (issue #2 rule
/// 2.2). Mirrors `ExportAssetResolver.isLocalRelativeReference`/`resolvedLocalFileURL`'s
/// symlink-resolve-then-prefix-check traversal guard verbatim -- the same technique already
/// independently mirrored by `PreviewSchemeHandler.resolvedFileURL` and `ImageSidecarWriter`'s
/// write-direction guard, kept here as its own pure, directly unit-testable copy since none of
/// those three existing call sites is public/reachable from `Shared/Editor/`.
public enum LivePreviewImageResolution {
    /// A reference is "local relative" if it isn't an absolute filesystem path and isn't an
    /// absolute URI with its own scheme (`data:`, `http:`, `https:`, or anything else with a
    /// `scheme:` prefix) -- matches `ExportAssetResolver.isLocalRelativeReference` exactly, so
    /// live preview never triggers a remote fetch for the same reasons HTML export doesn't.
    public static func isLocalRelativeReference(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        guard let colonIndex = path.firstIndex(of: ":") else { return true }
        let scheme = path[path.startIndex ..< colonIndex]
        return scheme.contains("/") // e.g. "notes.assets/foo:bar.png" has no real scheme
    }

    /// Resolves `relativePath` against `documentDirectory`, rejecting anything that isn't a
    /// local relative reference, escapes `documentDirectory` (including via a symlink), or
    /// doesn't exist on disk.
    public static func resolvedFileURL(relativePath: String, documentDirectory: URL) -> URL? {
        guard isLocalRelativeReference(relativePath),
              let candidate = URL(string: relativePath, relativeTo: documentDirectory) else { return nil }
        let resolved = candidate.resolvingSymlinksInPath()
        let resolvedBase = documentDirectory.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(resolvedBase.path),
              FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }
}
