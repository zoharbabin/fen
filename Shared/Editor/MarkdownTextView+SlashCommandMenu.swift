#if os(macOS)
    import AppKit
    import SwiftUI

    /// Slash-command menu (issue #1) Coordinator methods, split out of `MarkdownTextView.swift`
    /// to keep that file under the project's file-length lint limit -- mirrors
    /// `MarkdownTextView+FocusMode.swift`'s precedent.
    extension MarkdownTextView.Coordinator {
        /// Recomputes `slashMenuState` from the caret's current position (issue #1 rules 3.2,
        /// 4.2) and shows/hides/repositions the popup subview to match -- called from both
        /// `textDidChange` and `textViewDidChangeSelection`, exactly like
        /// `applyFocusModeIfNeeded`. A click/tap that moves the caret off the trigger span
        /// closes the menu here for free, satisfying rule 3.4's dismissal requirement with no
        /// separate dismissal-specific code.
        @MainActor func recomputeSlashMenu(in textView: MarkdownNSTextView) {
            let cursorLocation = textView.selectedRange().location
            let match = SlashCommandMenu.triggerMatch(text: textView.string, cursorLocation: cursorLocation)
            slashMenuState.triggerMatch = match
            guard let match else {
                hideSlashMenuPopup()
                return
            }
            slashMenuState.caretRect = textView.caretRect(forCharacterIndex: match.range.location)
            showSlashMenuPopup(in: textView)
        }

        /// Handles Escape while the menu is open (issue #1 rule 3.4): dismisses without
        /// mutating text. Returns `false` (let AppKit handle Escape normally) when the menu
        /// isn't open, so this never swallows Escape's other editor behavior.
        @MainActor func dismissSlashMenuIfOpenOnEscape() -> Bool {
            guard slashMenuState.isOpen else { return false }
            slashMenuState.dismiss()
            hideSlashMenuPopup()
            return true
        }

        /// Selecting a menu entry (issue #1 rule 3.5): removes exactly the triggering
        /// `/`+filter-text range, then posts through the existing `.insertMarkdownFormatting`
        /// notification path (rule 5.1) -- never duplicates `MarkdownFormatting.apply`'s logic.
        @MainActor func commitSlashCommandMenuEntry(_ action: FormattingAction) {
            guard let match = slashMenuState.triggerMatch, let textView else { return }
            slashMenuState.dismiss()
            hideSlashMenuPopup()
            guard textView.shouldChangeText(in: match.range, replacementString: "") else { return }
            textView.textStorage?.replaceCharacters(in: match.range, with: "")
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: match.range.location, length: 0))
            parent.text = textView.string
            parent.onTextChange?()
            NotificationCenter.default.post(name: .insertMarkdownFormatting, object: action.identifier)
        }

        @MainActor private func showSlashMenuPopup(in textView: MarkdownNSTextView) {
            guard let caretRect = slashMenuState.caretRect else { return }
            let hostingView: NSHostingView<SlashCommandMenuView>
            if let existing = slashMenuHostingView {
                hostingView = existing
            } else {
                hostingView = NSHostingView(rootView: SlashCommandMenuView(state: slashMenuState))
                hostingView.translatesAutoresizingMaskIntoConstraints = true
                slashMenuHostingView = hostingView
                textView.addSubview(hostingView)
                // See `MarkdownNSTextView.accessibilityOverlaySubviews`'s doc comment (issue #1):
                // without this, the popup is visible on screen but invisible to XCUITest/VoiceOver.
                textView.accessibilityOverlaySubviews.append(hostingView)
            }
            let size = hostingView.fittingSize
            hostingView.frame = CGRect(
                x: caretRect.minX, y: caretRect.maxY, width: max(size.width, 180), height: size.height
            )
        }

        @MainActor private func hideSlashMenuPopup() {
            guard let hostingView = slashMenuHostingView else { return }
            hostingView.removeFromSuperview()
            textView?.accessibilityOverlaySubviews.removeAll { $0 === hostingView }
            slashMenuHostingView = nil
        }
    }
#endif
