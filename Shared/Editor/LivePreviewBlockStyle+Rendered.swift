import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

extension LivePreviewBlockStyle {
    /// Space above and below a picture.
    static let pictureMargin: CGFloat = 4

    /// Replaces a block's lines with `image`. The text shrinks to nothing and stays in the document. The first
    /// line grows to the picture's height, and `DecorationLayoutManager` draws the picture there.
    static func applyRendered(
        _ image: PlatformImage, block: NSRange, storage: NSTextStorage, background: PlatformColor
    ) {
        guard block.length > 0 else { return }
        let first = (storage.string as NSString).lineRange(for: NSRange(location: block.location, length: 0))
        let hidden = scaled(font(at: block.location, in: storage), to: 0.01)
        stashOriginal(block, in: storage)
        stashParagraphStyle(first, in: storage)
        storage.addAttribute(.foregroundColor, value: background, range: block)
        storage.addAttribute(.font, value: hidden, range: block)
        storage.enumerateAttribute(.paragraphStyle, in: first) { value, subrange, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            let height = image.size.height + 2 * pictureMargin
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            storage.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        decorate(first, as: .renderedImage, background: background, in: storage)
        storage.addAttribute(.fenBlockImage, value: image, range: first)
    }

    /// Whether the caret or the selection is in `block`, so the block shows its source. The end of the last line
    /// counts as inside.
    static func isEditing(_ block: RenderedBlock, active: NSRange, selection: NSRange, in text: NSString) -> Bool {
        if NSIntersectionRange(block.range, active).length > 0 {
            return true
        }
        var end = NSMaxRange(block.range)
        if end > block.range.location, text.character(at: end - 1) == 10 {
            end -= 1
        }
        return selection.location >= block.range.location && selection.location <= end
            || NSIntersectionRange(block.range, selection).length > 0
    }
}
