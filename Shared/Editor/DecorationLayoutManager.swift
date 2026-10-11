import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

public extension NSAttributedString.Key {
    /// Marks a range `DecorationLayoutManager` draws behind or over the text. The value is a `BlockDecoration` raw
    /// value.
    static let fenBlockDecoration = NSAttributedString.Key("FenBlockDecoration")
    /// The color decorations are drawn in, as a full-strength `PlatformColor`. The layout manager applies the alpha.
    static let fenBlockInk = NSAttributedString.Key("FenBlockInk")
    /// Set on a table's separator `|`. The pipe is hidden and the layout manager draws a column line in its place.
    static let fenTablePipe = NSAttributedString.Key("FenTablePipe")
    /// A `ParagraphStash` holding the paragraph style a block styler replaced.
    static let livePreviewOriginalParagraphStyle = NSAttributedString.Key("FenLivePreviewOriginalParagraphStyle")
}

public enum BlockDecoration: String {
    /// A thematic break: the line's text is hidden and a thin line is drawn across the text column.
    case rule
    /// A fenced code block: a rounded panel behind all of its lines.
    case codeBlock
    /// A table header line: a shaded band with a line on top.
    case tableHeader
    /// The delimiter line (`|---|---|`). It collapses to a line between the header and the body.
    case tableDelimiter
    /// A table body line: a line under it.
    case tableRow
}

/// Draws the block decorations Live Preview sets as `fenBlockDecoration` attributes. The text view uses it
/// instead of a plain `NSLayoutManager`. Drawing happens at draw time, so a decoration follows the layout
/// on every resize, font change and wrap with no extra bookkeeping.
public final class DecorationLayoutManager: NSLayoutManager {
    override public func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.fenBlockDecoration, in: characters) { value, range, _ in
            guard let name = value as? String, let decoration = BlockDecoration(rawValue: name) else { return }
            switch decoration {
            case .rule:
                drawRule(over: range, origin: origin, in: storage)
            case .codeBlock:
                drawCodePanel(containing: range, origin: origin, in: storage)
            case .tableHeader, .tableDelimiter, .tableRow:
                drawTableLines(decoration, over: range, origin: origin, in: storage)
            }
        }
        storage.enumerateAttribute(.fenTablePipe, in: characters) { value, range, _ in
            guard value != nil else { return }
            drawColumnLine(at: range.location, origin: origin, in: storage)
        }
    }

    // MARK: - Shapes

    private func ink(at location: Int, in storage: NSTextStorage, alpha: CGFloat) -> PlatformColor {
        let color = storage.attribute(.fenBlockInk, at: location, effectiveRange: nil) as? PlatformColor
        return (color ?? Self.fallbackInk).withAlphaComponent(alpha)
    }

    /// The text column of `container`, in view coordinates.
    private func column(_ container: NSTextContainer, origin: CGPoint) -> (x: CGFloat, width: CGFloat) {
        let inset = container.lineFragmentPadding
        return (origin.x + inset, max(container.size.width - 2 * inset, 0))
    }

    private func drawRule(over characters: NSRange, origin: CGPoint, in storage: NSTextStorage) {
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphs.length > 0,
              let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
        let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let column = column(container, origin: origin)
        fill(
            CGRect(x: column.x, y: origin.y + line.midY - 0.5, width: column.width, height: 1),
            ink(at: characters.location, in: storage, alpha: 0.4)
        )
    }

    /// One panel for the whole block. `range` can be a clipped piece of a redraw, so the block's full extent is
    /// looked up first. A panel drawn from the piece would have the wrong corners.
    private func drawCodePanel(containing range: NSRange, origin: CGPoint, in storage: NSTextStorage) {
        var block = NSRange()
        let whole = NSRange(location: 0, length: storage.length)
        _ = storage.attribute(.fenBlockDecoration, at: range.location, longestEffectiveRange: &block, in: whole)
        let glyphs = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
        guard glyphs.length > 0,
              let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
        let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let column = column(container, origin: origin)
        let panel = CGRect(
            x: column.x - 4, y: origin.y + first.minY, width: column.width + 8, height: last.maxY - first.minY
        )
        fillRounded(panel, radius: 6, ink(at: block.location, in: storage, alpha: 0.07))
    }

    private func drawTableLines(
        _ decoration: BlockDecoration, over characters: NSRange, origin: CGPoint, in storage: NSTextStorage
    ) {
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        let text = storage.string as NSString
        enumerateLineFragments(forGlyphRange: glyphs) { rect, _, container, fragmentGlyphs, _ in
            let column = self.column(container, origin: origin)
            let band = CGRect(x: column.x, y: origin.y + rect.minY, width: column.width, height: rect.height)
            let line = self.ink(at: characters.location, in: storage, alpha: 0.35)
            switch decoration {
            case .tableHeader:
                self.fill(band, self.ink(at: characters.location, in: storage, alpha: 0.08))
                if fragmentGlyphs.location == glyphs.location {
                    self.fill(CGRect(x: band.minX, y: band.minY, width: band.width, height: 1), line)
                }
            case .tableDelimiter:
                self.fill(CGRect(x: band.minX, y: band.minY, width: band.width, height: 1.5), line)
            case .tableRow:
                // Only the end of a source line closes a row. A wrapped row has no line inside it.
                let end = NSMaxRange(self.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil))
                if end >= text.length || text.character(at: end - 1) == 10 {
                    self.fill(CGRect(x: band.minX, y: band.maxY - 1, width: band.width, height: 1), line)
                }
            case .rule, .codeBlock:
                break
            }
        }
    }

    private func drawColumnLine(at character: Int, origin: CGPoint, in storage: NSTextStorage) {
        let glyph = glyphIndexForCharacter(at: character)
        guard let container = textContainer(forGlyphAt: glyph, effectiveRange: nil) else { return }
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let box = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        fill(
            CGRect(x: (origin.x + box.midX).rounded(), y: origin.y + fragment.minY, width: 1, height: fragment.height),
            ink(at: character, in: storage, alpha: 0.35)
        )
    }

    // MARK: - Platform

    private func fill(_ rect: CGRect, _ color: PlatformColor) {
        color.setFill()
        #if canImport(AppKit)
            rect.fill()
        #else
            UIRectFill(rect)
        #endif
    }

    private func fillRounded(_ rect: CGRect, radius: CGFloat, _ color: PlatformColor) {
        color.setFill()
        #if canImport(AppKit)
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        #else
            UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
        #endif
    }

    private static var fallbackInk: PlatformColor {
        #if canImport(AppKit)
            .textColor
        #else
            .label
        #endif
    }
}
