import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Stashes a dimmed run's real foreground color (whatever Highlightr's syntax highlighting, or
/// the plain default, set) before `.foregroundColor` is overwritten with a dimmed variant --
/// added via `addAttribute` alongside the still-present `.foregroundColor` key, never replacing
/// the attribute dictionary, so undimming can restore the exact original color (issue #19
/// rule 4.3).
public extension NSAttributedString.Key {
    static let focusModeOriginalForegroundColor = NSAttributedString.Key("FenFocusModeOriginalForegroundColor")
}

/// Raw (front-matter-inclusive) 1-based source line bounds of the editor's active Focus Mode
/// range (issue #127 rule 3.3), passed to the preview pane so it can dim every rendered block
/// outside `[startLine, endLine]`. A small `Equatable` struct rather than a raw tuple so
/// `PreviewWebView.Coordinator` can diff successive values the same way it diffs `lastFontSize`.
public struct FocusLineRange: Equatable, Sendable {
    public let startLine: Int
    public let endLine: Int

    public init(startLine: Int, endLine: Int) {
        self.startLine = startLine
        self.endLine = endLine
    }
}

/// Pure, platform-independent focus/typewriter mode logic (issue #19): paragraph-boundary
/// detection, active-range computation, and typewriter centering-offset math. Kept separate from
/// `MarkdownTextView`/`MarkdownTextView_iOS`'s Coordinator wiring, mirroring
/// `MarkdownTextEditing`'s existing pure-function pattern, so every rule is unit-testable without
/// constructing a real text view.
public enum FocusModeEditing {
    /// Posted by `FenApp_macOS.swift`'s "Toggle Focus Mode" menu command, mirroring
    /// `DocumentOutline.toggleOutlineNotification`'s pattern (issue #19 rule 5.3): a single
    /// notification name shared by the poster (FenMacOS) and the subscriber
    /// (`SplitEditorView`, in FenCore) since `editorFocusModeEnabled` itself is `internal` and
    /// can't be mutated directly across that module boundary.
    public static let toggleFocusModeNotification = Notification.Name("toggleFocusMode")

    /// Alpha applied to a dimmed run's original foreground color.
    public static let dimmedAlpha: CGFloat = 0.35

    /// The dimmed variant of `color`, applied over Highlightr's real syntax-highlighting color
    /// (or the plain default) without changing its hue.
    public static func dimmedColor(from color: PlatformColor) -> PlatformColor {
        color.withAlphaComponent(dimmedAlpha)
    }

    // MARK: - Active paragraph range

    /// The `NSRange` of the paragraph (a run of non-blank lines, bounded by blank lines or the
    /// document's edges) containing `caretLocation`. If the caret sits on a blank line itself
    /// (between paragraphs, or on an empty document), returns a zero-length range at that line's
    /// start rather than expanding into either neighboring paragraph. `caretLocation` is clamped
    /// into `text`'s bounds, so an out-of-range caret never produces an out-of-range result.
    public static func activeParagraphRange(text: String, caretLocation: Int) -> NSRange {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let location = max(0, min(caretLocation, length))

        let caretLineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        guard !isBlankLine(ns, caretLineRange) else {
            return NSRange(location: caretLineRange.location, length: 0)
        }

        var start = caretLineRange.location
        while start > 0 {
            let previousLineRange = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            guard !isBlankLine(ns, previousLineRange) else { break }
            start = previousLineRange.location
        }

        var end = caretLineRange.location + caretLineRange.length
        while end < length {
            let nextLineRange = ns.lineRange(for: NSRange(location: end, length: 0))
            guard !isBlankLine(ns, nextLineRange) else { break }
            end = nextLineRange.location + nextLineRange.length
        }

        return NSRange(location: start, length: end - start)
    }

    /// Whether `range` within `ns` contains only whitespace/newline characters (an empty line
    /// separating two paragraphs).
    private static func isBlankLine(_ ns: NSString, _ range: NSRange) -> Bool {
        ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `activeParagraphRange` extended to include a heading directly above it, if any (issue
    /// #127 rules 1.2--1.4). "Directly above" means separated from the active paragraph by
    /// zero or more blank lines but no other non-blank line -- a heading two paragraphs up is
    /// never pulled in. A no-op when the active paragraph already starts with a heading (rule
    /// 1.3, since `activeParagraphRange`'s own blank-line rule already merged it in) or when the
    /// active paragraph *is* the heading line itself (rule 1.4).
    public static func activeDisplayRange(text: String, caretLocation: Int) -> NSRange {
        let ns = text as NSString
        let activeRange = activeParagraphRange(text: text, caretLocation: caretLocation)
        guard activeRange.location > 0 else { return activeRange }

        var probe = activeRange.location - 1
        while probe > 0 {
            let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
            guard isBlankLine(ns, lineRange) else { break }
            probe = lineRange.location - 1
        }
        guard probe >= 0 else { return activeRange }

        let candidateLineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
        guard !isBlankLine(ns, candidateLineRange), isHeadingLine(ns, candidateLineRange) else {
            return activeRange
        }
        // Rule 1.3/1.4: the candidate heading line is already inside the active range (either
        // it merged in via the no-blank-line case, or it *is* the active paragraph itself).
        guard candidateLineRange.location < activeRange.location else { return activeRange }

        let newLength = activeRange.location + activeRange.length - candidateLineRange.location
        return NSRange(location: candidateLineRange.location, length: newLength)
    }

    /// Whether `range` within `ns` starts with an ATX heading marker (`#` through `######`,
    /// followed by a space) -- the same prefix `LivePreviewEditing.headingSpan` recognizes.
    private static func isHeadingLine(_ ns: NSString, _ range: NSRange) -> Bool {
        let hash = UInt16(UnicodeScalar("#").value)
        let space = UInt16(UnicodeScalar(" ").value)
        var level = 0
        while level < range.length, level < 6, ns.character(at: range.location + level) == hash {
            level += 1
        }
        return level > 0 && level < range.length && ns.character(at: range.location + level) == space
    }

    /// Converts `range` (character offsets into `text`) to raw 1-based source line bounds
    /// (issue #127 rule 3.3), for handing to the preview pane's `setFocusRange`. A zero-length
    /// range (caret on a blank line) still resolves to a valid single-line span.
    public static func lineRange(forCharacterRange range: NSRange, in text: String) -> FocusLineRange {
        let offsets = computeLineStartOffsets(text: text)
        let startLine = sourceLine(forCharacterIndex: range.location, lineStartOffsets: offsets)
        let endLine = sourceLine(
            forCharacterIndex: max(range.location, range.location + range.length - 1),
            lineStartOffsets: offsets
        )
        return FocusLineRange(startLine: startLine, endLine: endLine)
    }

    // MARK: - Dimmed ranges

    /// The ranges of `text` outside `activeRange` that should be dimmed -- zero, one (active
    /// range at an edge), or two (active range in the middle) ranges, empty when `activeRange`
    /// already spans the whole document (nothing to dim, e.g. a single-paragraph document).
    public static func dimmedRanges(text: String, activeRange: NSRange) -> [NSRange] {
        let length = (text as NSString).length
        var ranges: [NSRange] = []
        if activeRange.location > 0 {
            ranges.append(NSRange(location: 0, length: activeRange.location))
        }
        let activeEnd = activeRange.location + activeRange.length
        if activeEnd < length {
            ranges.append(NSRange(location: activeEnd, length: length - activeEnd))
        }
        return ranges
    }

    // MARK: - Typewriter centering

    /// The vertical scroll offset that centers a line whose top edge is at `caretLineTop` within
    /// a viewport of `visibleHeight`, clamped to never go negative. Callers are responsible for
    /// clamping the upper bound to the scrollable content's actual height.
    public static func centeringOffset(caretLineTop: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        max(0, caretLineTop - visibleHeight / 2)
    }
}
