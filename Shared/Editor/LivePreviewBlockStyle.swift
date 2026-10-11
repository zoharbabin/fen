import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// The paragraph style a block styler replaced, or `nil` when the range had none.
final class ParagraphStash: NSObject {
    let style: NSParagraphStyle?

    init(_ style: NSParagraphStyle?) {
        self.style = style
    }
}

/// Live Preview styling for horizontal rules, lists and footnotes (issue #135, phase 1). It only sets
/// attributes, so it works the same on macOS and iOS and needs no overlay views. It records what it
/// replaces, and `restore(in:storage:)` puts that back.
enum LivePreviewBlockStyle {
    /// Styles one inactive line. `line` has no line break. Call it between `beginEditing()` and `endEditing()`.
    /// Returns `true` when the line is a horizontal rule, which needs no inline styling.
    @discardableResult
    static func apply(
        line: String,
        lineStart: Int,
        previousLine: String?,
        storage: NSTextStorage,
        background: PlatformColor
    ) -> Bool {
        guard !line.isEmpty else { return false }
        let lineRange = NSRange(location: lineStart, length: (line as NSString).length)
        if LivePreviewEditing.isHorizontalRule(line: line, previousLine: previousLine) {
            stashOriginal(lineRange, in: storage)
            storage.addAttribute(.foregroundColor, value: background, range: lineRange)
            decorate(lineRange, as: .rule, background: background, in: storage)
            return true
        }
        if let item = LivePreviewEditing.listItem(line: line, lineStart: lineStart) {
            styleList(item, lineRange: lineRange, storage: storage, background: background)
        }
        for footnote in LivePreviewEditing.footnoteSpans(in: line, lineStart: lineStart) {
            styleFootnote(footnote, storage: storage, background: background)
        }
        return false
    }

    /// Undoes what `apply` did inside `range`. The caller restores color and font from their own stash.
    static func restore(in range: NSRange, storage: NSTextStorage) {
        storage.enumerateAttribute(.livePreviewOriginalParagraphStyle, in: range) { value, subrange, _ in
            guard let stash = value as? ParagraphStash else { return }
            if let style = stash.style {
                storage.addAttribute(.paragraphStyle, value: style, range: subrange)
            } else {
                storage.removeAttribute(.paragraphStyle, range: subrange)
            }
            storage.removeAttribute(.livePreviewOriginalParagraphStyle, range: subrange)
        }
        for key: NSAttributedString.Key in [.fenBlockDecoration, .fenBlockInk, .fenTablePipe, .fenBlockImage] {
            storage.removeAttribute(key, range: range)
        }
        storage.removeAttribute(.baselineOffset, range: range)
    }

    // MARK: - Lists

    private static func styleList(
        _ item: LivePreviewEditing.ListItem, lineRange: NSRange, storage: NSTextStorage, background: PlatformColor
    ) {
        let font = font(at: item.marker.location, in: storage)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let text = storage.string as NSString
        let indent = text.substring(with: item.indent).replacingOccurrences(of: "\t", with: "    ")
        let prefix = text.substring(with: item.prefix)
        let hang = (indent as NSString).size(withAttributes: attributes).width
            + (prefix as NSString).size(withAttributes: attributes).width

        stashParagraphStyle(lineRange, in: storage)
        storage.enumerateAttribute(.paragraphStyle, in: lineRange) { value, subrange, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            style.headIndent = hang
            storage.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        stashOriginal(item.marker, in: storage)
        storage.addAttribute(.foregroundColor, value: accentColor, range: item.marker)
        guard !item.isOrdered, !isTask(item, in: text) else { return }
        // The dash stays in the text and keeps its width. A round bullet is drawn over it.
        storage.addAttribute(.foregroundColor, value: background, range: item.marker)
        decorate(item.marker, as: .bullet, background: background, in: storage)
        storage.addAttribute(.fenBlockInk, value: accentColor, range: item.marker)
    }

    /// `- [ ] ` and `- [x] ` items already get a checkbox, so they keep their marker.
    private static func isTask(_ item: LivePreviewEditing.ListItem, in text: NSString) -> Bool {
        let box = NSRange(location: NSMaxRange(item.prefix), length: 3)
        guard NSMaxRange(box) <= text.length else { return false }
        return ["[ ]", "[x]", "[X]"].contains(text.substring(with: box))
    }

    // MARK: - Footnotes

    private static func styleFootnote(
        _ footnote: LivePreviewEditing.FootnoteSpan, storage: NSTextStorage, background: PlatformColor
    ) {
        let range = footnote.range
        stashOriginal(range, in: storage)
        if footnote.isDefinition {
            storage.addAttribute(.foregroundColor, value: accentColor, range: range)
            return
        }
        let base = font(at: range.location, in: storage)
        // "[^" and "]" shrink away. The id stays, smaller and raised.
        let hidden = scaled(base, to: 0.01)
        let opening = NSRange(location: range.location, length: 2)
        let closing = NSRange(location: NSMaxRange(range) - 1, length: 1)
        for edge in [opening, closing] {
            storage.addAttribute(.foregroundColor, value: background, range: edge)
            storage.addAttribute(.font, value: hidden, range: edge)
        }
        let id = NSRange(location: range.location + 2, length: range.length - 3)
        guard id.length > 0 else { return }
        storage.addAttribute(.font, value: scaled(base, to: base.pointSize * 0.75), range: id)
        storage.addAttribute(.baselineOffset, value: base.pointSize * 0.35, range: id)
        storage.addAttribute(.foregroundColor, value: accentColor, range: id)
    }

    // MARK: - Stash

    /// Same rule as the platform stash: only the first touch records the original color and font.
    static func stashOriginal(_ range: NSRange, in storage: NSTextStorage) {
        guard range.length > 0 else { return }
        storage.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            guard storage.attribute(.livePreviewTouched, at: subrange.location, effectiveRange: nil) == nil else {
                return
            }
            storage.addAttribute(
                .livePreviewOriginalForegroundColor,
                value: attributes[.foregroundColor] as? PlatformColor ?? defaultColor,
                range: subrange
            )
            storage.addAttribute(
                .livePreviewOriginalFont,
                value: attributes[.font] as? PlatformFont ?? .systemFont(ofSize: PlatformFont.systemFontSize),
                range: subrange
            )
            storage.addAttribute(.livePreviewTouched, value: true, range: subrange)
        }
    }

    static func stashParagraphStyle(_ range: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
            guard storage.attribute(.livePreviewOriginalParagraphStyle, at: subrange.location, effectiveRange: nil)
                == nil else { return }
            storage.addAttribute(
                .livePreviewOriginalParagraphStyle,
                value: ParagraphStash(value as? NSParagraphStyle),
                range: subrange
            )
        }
        // A range with no paragraph style yet is still a range to put back. Mark the gaps too.
        if storage.attribute(.livePreviewOriginalParagraphStyle, at: range.location, effectiveRange: nil) == nil {
            storage.addAttribute(.livePreviewOriginalParagraphStyle, value: ParagraphStash(nil), range: range)
        }
    }

    // MARK: - Platform

    static func font(at location: Int, in storage: NSTextStorage) -> PlatformFont {
        storage.attribute(.font, at: location, effectiveRange: nil) as? PlatformFont
            ?? .systemFont(ofSize: PlatformFont.systemFontSize)
    }

    static func scaled(_ font: PlatformFont, to size: CGFloat) -> PlatformFont {
        #if canImport(AppKit)
            NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        #else
            font.withSize(size)
        #endif
    }

    static var accentColor: PlatformColor {
        #if canImport(AppKit)
            .controlAccentColor
        #else
            .tintColor
        #endif
    }

    static var defaultColor: PlatformColor {
        #if canImport(AppKit)
            .textColor
        #else
            .label
        #endif
    }
}
