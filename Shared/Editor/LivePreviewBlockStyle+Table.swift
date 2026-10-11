import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// What each line of a document is, for block-level Live Preview. Computed once per restyle, because a fence or
/// a table spans lines and no single line can tell if it belongs to one.
struct LivePreviewBlockContext {
    enum Kind: Equatable {
        /// An ordinary line: rule, list, footnote and inline styling can apply.
        case text
        /// Front matter. Left as it is.
        case skipped
        /// A line of a fenced code block. Its text is never styled, only framed.
        case code
        case table(LivePreviewBlockStyle.TableRole)
    }

    private let fenced: [NSRange]
    private let frontMatterEnd: Int
    private let tableRoles: [Int: LivePreviewBlockStyle.TableRole]
    /// Blocks shown as a picture of their rendered result, for the kinds passed to `init`.
    let rendered: [RenderedBlock]

    init(text: String, rendering kinds: Set<RenderedBlock.Kind> = []) {
        fenced = LivePreviewEditing.fencedRanges(text: text)
        rendered = LivePreviewEditing.renderedBlocks(in: text, fenced: fenced, kinds: kinds)
        frontMatterEnd = LivePreviewEditing.frontMatterRange(text: text).map { NSMaxRange($0) } ?? 0
        var roles: [Int: LivePreviewBlockStyle.TableRole] = [:]
        for table in LivePreviewEditing.tables(in: text, excluding: fenced) {
            for (index, line) in table.lines.enumerated() {
                roles[line.location] = index == 0 ? .header : (index == 1 ? .delimiter : .row)
            }
        }
        tableRoles = roles
    }

    /// `start` is where the line begins. Fenced ranges are whole lines, so a line is in one if its start is.
    func kind(ofLineAt start: Int) -> Kind {
        if start < frontMatterEnd {
            return .skipped
        }
        if fenced.contains(where: { start >= $0.location && start < NSMaxRange($0) }) {
            return .code
        }
        return tableRoles[start].map(Kind.table) ?? .text
    }

    /// `range` grown to cover every rendered block it touches, so a block is always restyled as a whole.
    func widened(_ range: NSRange) -> NSRange {
        var result = range
        for block in rendered where NSIntersectionRange(block.range, range).length > 0
            || NSLocationInRange(range.location, block.range) {
            result = NSUnionRange(result, block.range)
        }
        return result
    }

    func renderedBlock(at start: Int) -> RenderedBlock? {
        rendered.first { NSLocationInRange(start, $0.range) }
    }
}

extension LivePreviewBlockStyle {
    enum TableRole: Equatable {
        case header
        case delimiter
        case row
    }

    /// Tags `range` for `DecorationLayoutManager`. The ink contrasts with the editor background.
    static func decorate(
        _ range: NSRange, as decoration: BlockDecoration, background: PlatformColor, in storage: NSTextStorage
    ) {
        guard range.length > 0 else { return }
        storage.addAttribute(.fenBlockDecoration, value: decoration.rawValue, range: range)
        storage.addAttribute(.fenBlockInk, value: ink(on: background), range: range)
    }

    /// Frames a fenced code line. The text keeps its own colors and font.
    static func applyCodeBlock(lineRange: NSRange, storage: NSTextStorage, background: PlatformColor) {
        decorate(lineRange, as: .codeBlock, background: background, in: storage)
    }

    /// Styles one table line and returns the ranges of its cells, so the caller can style inline Markdown in each.
    /// `fullRange` is the line with its line break.
    static func applyTable(
        _ role: TableRole,
        line: String,
        fullRange: NSRange,
        storage: NSTextStorage,
        background: PlatformColor
    ) -> [NSRange] {
        let lineStart = fullRange.location
        switch role {
        case .delimiter:
            // Collapsed to a line. The header and the body need a rule between them, not a row of dashes.
            stashOriginal(fullRange, in: storage)
            storage.addAttribute(.foregroundColor, value: background, range: fullRange)
            storage.addAttribute(.font, value: scaled(font(at: lineStart, in: storage), to: 0.01), range: fullRange)
            decorate(fullRange, as: .tableDelimiter, background: background, in: storage)
            return []
        case .header, .row:
            let content = NSRange(location: lineStart, length: (line as NSString).length)
            if role == .header {
                stashOriginal(content, in: storage)
                storage.addAttribute(.font, value: bolded(font(at: lineStart, in: storage)), range: content)
            }
            for pipe in LivePreviewEditing.tablePipes(line: line, lineStart: lineStart) {
                stashOriginal(pipe, in: storage)
                storage.addAttribute(.foregroundColor, value: background, range: pipe)
                storage.addAttribute(.fenTablePipe, value: true, range: pipe)
            }
            decorate(fullRange, as: role == .header ? .tableHeader : .tableRow, background: background, in: storage)
            return LivePreviewEditing.tableCells(line: line, lineStart: lineStart)
        }
    }

    // MARK: - Platform

    static func ink(on background: PlatformColor) -> PlatformColor {
        luminance(of: background) < 0.5 ? .white : .black
    }

    static func luminance(of color: PlatformColor) -> CGFloat {
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        #if canImport(AppKit)
            guard let rgb = color.usingColorSpace(.sRGB) else { return 1 }
            rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }

    static func bolded(_ font: PlatformFont) -> PlatformFont {
        #if canImport(AppKit)
            NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        #else
            font.fontDescriptor.withSymbolicTraits(.traitBold)
                .map { PlatformFont(descriptor: $0, size: font.pointSize) }
                ?? font
        #endif
    }
}
