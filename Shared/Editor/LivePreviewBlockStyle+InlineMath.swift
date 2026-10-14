import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

public extension NSAttributedString.Key {
    /// The `InlinePicture` `DecorationLayoutManager` draws over a formula inside a line.
    static let fenInlinePicture = NSAttributedString.Key("FenInlinePicture")
}

/// A rendered formula and where its baseline is. A class, so two formulas side by side stay two runs.
public final class InlinePicture: NSObject {
    let image: PlatformImage
    /// The distance from the top of `image` to the text baseline.
    let baseline: CGFloat

    init(image: PlatformImage, baseline: CGFloat) {
        self.image = image
        self.baseline = baseline
    }
}

extension LivePreviewBlockStyle {
    /// Space kept on each side of a formula.
    static let formulaMargin: CGFloat = 1

    /// Replaces a formula's source with its picture. The source shrinks to nothing and stays in the document. The
    /// first character carries a kern as wide as the picture, and `DecorationLayoutManager` draws the picture
    /// there, on the baseline. A line grows when the picture is taller than the font.
    static func applyInlineMath(
        _ picture: LivePreviewSnapshots.Picture, range: NSRange, storage: NSTextStorage, background: PlatformColor
    ) {
        guard range.length > 0 else { return }
        let font = font(at: range.location, in: storage)
        stashOriginal(range, in: storage)
        storage.addAttribute(.foregroundColor, value: background, range: range)
        storage.addAttribute(.font, value: scaled(font, to: 0.01), range: range)
        storage.addAttribute(
            .kern, value: picture.image.size.width + 2 * formulaMargin, range: NSRange(
                location: range.location,
                length: 1
            )
        )
        storage.addAttribute(
            .fenInlinePicture,
            value: InlinePicture(image: picture.image, baseline: picture.baseline),
            range: range
        )
        growLine(for: picture, font: font, at: range.location, in: storage)
    }

    /// Makes room above and below the baseline for a picture bigger than the text. The typesetter puts the extra
    /// of a minimum line height above the baseline, so the room below comes from line spacing.
    private static func growLine(
        for picture: LivePreviewSnapshots.Picture, font: PlatformFont, at location: Int, in storage: NSTextStorage
    ) {
        let descent = -font.descender
        let above = max(picture.baseline, font.ascender)
        let below = max(picture.image.size.height - picture.baseline, descent)
        guard above > font.ascender || below > descent else { return }
        let line = (storage.string as NSString).lineRange(for: NSRange(location: location, length: 0))
        stashParagraphStyle(line, in: storage)
        storage.enumerateAttribute(.paragraphStyle, in: line) { value, subrange, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            style.minimumLineHeight = max(style.minimumLineHeight, (above + descent).rounded(.up))
            style.lineSpacing += (below - descent).rounded(.up)
            storage.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
    }
}
