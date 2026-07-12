import SwiftUI

/// The outline/TOC navigator's sidebar list (issue #12), split out of `SplitEditorView` to keep
/// that view focused on the editor/preview split itself. Reads and mutates fold state directly
/// on the `DocumentOutline` instance it's given -- it owns no state of its own.
struct DocumentOutlineSidebar: View {
    let outline: DocumentOutline
    let onSelectHeading: (Heading) -> Void

    /// Rows visible in the outline list, each paired with whether it has a nested descendant --
    /// the sidebar shows a fold chevron only for those, per issue #12 rule 1.1's per-instance
    /// fold state (owned by `outline`, not this view).
    private var rows: [(heading: Heading, hasChildren: Bool)] {
        let all = outline.headings
        var hasChildBySlug: [String: Bool] = [:]
        for (index, heading) in all.enumerated() {
            hasChildBySlug[heading.slug] = index + 1 < all.count && all[index + 1].level > heading.level
        }
        return outline.visibleHeadings.map { ($0, hasChildBySlug[$0.slug] ?? false) }
    }

    var body: some View {
        List(rows, id: \.heading.slug) { row in
            HStack(spacing: 4) {
                if row.hasChildren {
                    Button {
                        outline.toggleCollapse(slug: row.heading.slug)
                    } label: {
                        Image(systemName: outline
                            .isCollapsed(slug: row.heading.slug) ? "chevron.right" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Button {
                    onSelectHeading(row.heading)
                } label: {
                    Text(row.heading.text)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(row.heading.level - 1) * 12)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180, idealWidth: 220)
        .accessibilityIdentifier("OutlineSidebar")
    }
}
