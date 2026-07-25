#if !os(macOS)
    import SwiftUI
    import UIKit

    /// Slash-command menu (issue #1) Coordinator methods, split out of
    /// `MarkdownTextView_iOS.swift` to keep that file under the project's file-length lint
    /// limit -- mirrors `MarkdownTextView+FocusMode_iOS.swift`'s precedent.
    extension MarkdownTextView.Coordinator {
        /// Recomputes `slashMenuState` from the caret's current position (issue #1 rules 3.2,
        /// 4.2) and shows/hides/repositions the popup subview to match -- called from both
        /// `textViewDidChange` and `textViewDidChangeSelection`, exactly like
        /// `applyFocusModeIfNeeded`. A tap that moves the caret off the trigger span closes the
        /// menu here for free, satisfying rule 3.4's dismissal requirement with no separate
        /// dismissal-specific code.
        @MainActor func recomputeSlashMenu(in textView: UITextView) {
            let cursorLocation = textView.selectedRange.location
            let match = SlashCommandMenu.triggerMatch(text: textView.text, cursorLocation: cursorLocation)
            slashMenuState.triggerMatch = match
            guard let match, let widthLimitedTextView = textView as? MarkdownTextView.MarkdownUITextView else {
                hideSlashMenuPopup()
                return
            }
            slashMenuState.caretRect = widthLimitedTextView.caretRect(forCharacterIndex: match.range.location)
            showSlashMenuPopup(in: widthLimitedTextView)
        }

        /// Selecting a menu entry (issue #1 rule 3.5): removes exactly the triggering
        /// `/`+filter-text range, then posts through the existing `.insertMarkdownFormatting`
        /// notification path (rule 5.1) -- never duplicates `MarkdownFormatting.apply`'s logic.
        @MainActor func commitSlashCommandMenuEntry(_ action: FormattingAction) {
            guard let match = slashMenuState.triggerMatch, let textView else { return }
            slashMenuState.dismiss()
            hideSlashMenuPopup()
            let ns = textView.text as NSString
            textView.text = ns.replacingCharacters(in: match.range, with: "")
            textView.selectedRange = NSRange(location: match.range.location, length: 0)
            parent.text = textView.text
            parent.onTextChange?()
            NotificationCenter.default.post(name: .insertMarkdownFormatting, object: action.identifier)
        }

        @MainActor private func showSlashMenuPopup(in textView: MarkdownTextView.MarkdownUITextView) {
            guard let caretRect = slashMenuState.caretRect else { return }
            let hostingController: UIHostingController<SlashCommandMenuView>
            if let existing = slashMenuHostingController {
                hostingController = existing
            } else {
                hostingController = UIHostingController(rootView: SlashCommandMenuView(state: slashMenuState))
                hostingController.view.backgroundColor = .clear
                slashMenuHostingController = hostingController
                textView.addSubview(hostingController.view)
            }
            let size = hostingController.view.sizeThatFits(UIView.layoutFittingCompressedSize)
            hostingController.view.frame = CGRect(
                x: caretRect.minX, y: caretRect.maxY, width: max(size.width, 180), height: size.height
            )
        }

        @MainActor private func hideSlashMenuPopup() {
            slashMenuHostingController?.view.removeFromSuperview()
            slashMenuHostingController = nil
        }
    }
#endif
