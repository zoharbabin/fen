import Foundation

/// Per-document heading tree and fold state for the outline/TOC navigator (issue #12:
/// https://github.com/zoharbabin/fen/issues/12). Owned by one `SplitEditorView` instance --
/// never shared across documents or windows (see issue #12 rule 1.1/1.2).
@Observable
public final class DocumentOutline {
    /// Posted by `FenApp_macOS.swift`'s "Toggle Outline" menu command (Cmd+Shift+O) to ask the
    /// focused `SplitEditorView` to show/hide its outline sidebar (issue #12 rule 5.3 -- reuses
    /// the same `NotificationCenter` pattern as `togglePreview`/`toggleEditor`, defined here
    /// rather than in the macOS app target since `SplitEditorView` (in `FenCore`) is the observer).
    public static let toggleOutlineNotification = Notification.Name("toggleOutline")

    public private(set) var headings: [MarkdownRenderer.Heading] = []
    private var collapsedSlugs: Set<String> = []

    public init() {}

    /// Replaces the heading list, e.g. after a debounced re-render (see `SplitEditorView`'s
    /// `scheduleRender`). Collapsed state for slugs that still exist is preserved; state for
    /// slugs that no longer exist is dropped so it can't resurrect on an unrelated heading that
    /// happens to reuse the same slug later.
    public func update(headings: [MarkdownRenderer.Heading]) {
        self.headings = headings
        let currentSlugs = Set(headings.map(\.slug))
        collapsedSlugs.formIntersection(currentSlugs)
    }

    public func isCollapsed(slug: String) -> Bool {
        collapsedSlugs.contains(slug)
    }

    public func toggleCollapse(slug: String) {
        if collapsedSlugs.contains(slug) {
            collapsedSlugs.remove(slug)
        } else {
            collapsedSlugs.insert(slug)
        }
    }

    /// Headings visible in the outline list after applying fold state: a heading is hidden
    /// when any ancestor heading (a preceding heading of a strictly lower `level`) is collapsed.
    public var visibleHeadings: [MarkdownRenderer.Heading] {
        var visible: [MarkdownRenderer.Heading] = []
        var collapsedAncestorLevels: [Int] = []
        for heading in headings {
            collapsedAncestorLevels.removeAll { $0 >= heading.level }
            if collapsedAncestorLevels.isEmpty {
                visible.append(heading)
            }
            if isCollapsed(slug: heading.slug) {
                collapsedAncestorLevels.append(heading.level)
            }
        }
        return visible
    }
}

/// Convenience alias so call sites and tests can write `Heading` instead of the fully
/// qualified `MarkdownRenderer.Heading`.
public typealias Heading = MarkdownRenderer.Heading
