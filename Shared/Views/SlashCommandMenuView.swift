import SwiftUI

/// Per-editor-instance slash-menu state (issue #1 rule 1.1) -- created and owned by exactly one
/// `MarkdownTextView.Coordinator` (see `slashMenuState` there), which hosts `SlashCommandMenuView`
/// as an `NSHostingView`/`UIHostingController` subview positioned at `caretRect`. Never a
/// static/shared instance: each open document's Coordinator constructs its own.
@MainActor
@Observable
public final class SlashCommandMenuState {
    public var triggerMatch: SlashCommandTriggerMatch?
    /// The caret's bounding rect in the hosting scroll/text view's own bounds coordinate space,
    /// already accounting for the current scroll offset -- usable to position an overlay with no
    /// further coordinate conversion by the view layer.
    public var caretRect: CGRect?
    /// Set by the owning Coordinator to its own commit method (issue #1 rule 5.1): removes the
    /// triggering `/`+query range, then posts `.insertMarkdownFormatting` -- this view never
    /// mutates text itself.
    public var commit: ((FormattingAction) -> Void)?

    public var isOpen: Bool {
        triggerMatch != nil
    }

    public var filteredEntries: [SlashCommandMenu.Entry] {
        SlashCommandMenu.filteredEntries(query: triggerMatch?.filterText ?? "")
    }

    public init() {}

    func clear() {
        triggerMatch = nil
        caretRect = nil
    }

    /// Dismisses the menu without committing anything (issue #1 rule 3.4) -- called for
    /// Escape/click-away; leaves the triggering `/`+filter text exactly as typed.
    public func dismiss() {
        clear()
    }
}

/// The slash-command menu popup: a static, bounded list of up to 7 rows (issue #1 rule 4.3),
/// positioned near the caret via `state.caretRect`. Hosted as an overlay from
/// `SplitEditorView.swift`; selecting a row calls `state.commit`, which removes the trigger range
/// and reuses the existing `.insertMarkdownFormatting` path (rule 5.1) -- this view never
/// duplicates `MarkdownFormatting.apply`'s logic.
public struct SlashCommandMenuView: View {
    var state: SlashCommandMenuState

    public init(state: SlashCommandMenuState) {
        self.state = state
    }

    public var body: some View {
        let entries = state.filteredEntries
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text("No matching blocks")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(entries, id: \.title) { entry in
                    Button {
                        state.commit?(entry.action)
                    } label: {
                        HStack {
                            Image(systemName: entry.action.systemImage)
                                .frame(width: 18)
                            Text(entry.title)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("SlashCommandMenuEntry-\(entry.action.identifier)")
                }
            }
        }
        .frame(minWidth: 180)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(radius: 6)
    }
}
