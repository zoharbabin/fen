#if !os(macOS)
    import UIKit

    /// Focus/typewriter mode (issue #19) Coordinator methods, split out of
    /// `MarkdownTextView_iOS.swift` to keep that file under the project's file-length lint limit.
    extension MarkdownTextView.Coordinator {
        /// Recomputes the active paragraph from the caret's current position and dims/undims
        /// only the paragraph(s) whose boundaries changed since the last call (rule 4.1) --
        /// never rewrites every paragraph's attributes on every keystroke. Also fully clears
        /// dimming the moment focus mode turns off (rule 3.5).
        func applyFocusModeIfNeeded(in textView: UITextView) {
            let textStorage = textView.textStorage
            guard parent.isFocusModeEnabled else {
                if focusModeActiveRange != nil {
                    undimRange(NSRange(location: 0, length: textStorage.length), in: textStorage)
                    focusModeActiveRange = nil
                    focusModeDimsCurrentlyApplied = false
                }
                notifyFocusRangeChangeIfNeeded(text: textView.text ?? "")
                return
            }

            let text = textView.text ?? ""
            let caretLocation = textView.selectedRange.location
            let newActiveRange = FocusModeEditing.activeDisplayRange(text: text, caretLocation: caretLocation)
            let rangeChanged = newActiveRange != focusModeActiveRange
            // Also re-evaluates when only `isFocusModeDimsTextEnabled` toggled with the caret
            // unchanged (issue #127 rule 2.2) -- mirrors the macOS Coordinator's same guard.
            guard rangeChanged || focusModeDimsCurrentlyApplied != parent.isFocusModeDimsTextEnabled else { return }
            let previousActiveRange = focusModeActiveRange
            focusModeActiveRange = newActiveRange

            guard parent.isFocusModeDimsTextEnabled else {
                if focusModeDimsCurrentlyApplied {
                    undimRange(NSRange(location: 0, length: textStorage.length), in: textStorage)
                    focusModeDimsCurrentlyApplied = false
                }
                notifyFocusRangeChangeIfNeeded(text: text)
                return
            }

            if let previousActiveRange, focusModeDimsCurrentlyApplied {
                dimRange(previousActiveRange, in: textStorage)
            } else {
                // First activation (or resuming after dimming was off): nothing in the document
                // is currently dimmed, so this one pass covers the whole document instead of a
                // single paragraph -- every later call only ever touches the previously-active
                // and newly-active paragraphs.
                for range in FocusModeEditing.dimmedRanges(text: text, activeRange: newActiveRange) {
                    dimRange(range, in: textStorage)
                }
            }
            undimRange(newActiveRange, in: textStorage)
            focusModeDimsCurrentlyApplied = true
            notifyFocusRangeChangeIfNeeded(text: text)
        }

        /// Mirrors the macOS Coordinator's `notifyFocusRangeChangeIfNeeded` doc comment (issue
        /// #127 rule 3.3/4.2).
        private func notifyFocusRangeChangeIfNeeded(text: String) {
            let newValue: FocusLineRange? = if parent.isFocusModeEnabled, parent.isFocusModeDimsTextEnabled,
                                               let activeRange = focusModeActiveRange {
                FocusModeEditing.lineRange(forCharacterRange: activeRange, in: text)
            } else {
                nil
            }
            guard lastNotifiedFocusRange != .some(newValue) else { return }
            lastNotifiedFocusRange = .some(newValue)
            parent.onFocusRangeChange?(newValue)
        }

        /// Applies the dimmed variant of each subrange's current foreground color, stashing
        /// the pre-dim color first so `undimRange` can restore it exactly. Skips any subrange
        /// already dimmed (has a stash present), so repeated calls never compound the dim.
        func dimRange(_ range: NSRange, in textStorage: NSTextStorage) {
            guard range.length > 0 else { return }
            textStorage.beginEditing()
            textStorage.enumerateAttribute(.foregroundColor, in: range, options: []) { value, subrange, _ in
                guard textStorage.attribute(
                    .focusModeOriginalForegroundColor, at: subrange.location, effectiveRange: nil
                ) == nil else { return }
                let original = value as? PlatformColor ?? .label
                textStorage.addAttribute(.focusModeOriginalForegroundColor, value: original, range: subrange)
                textStorage.addAttribute(
                    .foregroundColor, value: FocusModeEditing.dimmedColor(from: original), range: subrange
                )
            }
            textStorage.endEditing()
        }

        /// Restores each dimmed subrange's stashed original foreground color and removes the
        /// stash. Subranges with no stash present (never dimmed) are left untouched.
        func undimRange(_ range: NSRange, in textStorage: NSTextStorage) {
            guard range.length > 0 else { return }
            textStorage.beginEditing()
            textStorage.enumerateAttribute(
                .focusModeOriginalForegroundColor, in: range, options: []
            ) { value, subrange, _ in
                guard let original = value as? PlatformColor else { return }
                textStorage.addAttribute(.foregroundColor, value: original, range: subrange)
                textStorage.removeAttribute(.focusModeOriginalForegroundColor, range: subrange)
            }
            textStorage.endEditing()
        }

        /// Re-dims whatever portion of Highlightr's just-completed re-highlight `range` falls
        /// outside the active paragraph, composing over the fresh syntax-highlighting colors
        /// Highlightr's `setAttributes` just replaced the whole range with (rule 4.3) -- called
        /// from `CodeAttributedString.highlightDelegate` once that async pass lands, since it
        /// would otherwise silently wipe out a dim applied before it.
        func didHighlight(_ range: NSRange, success: Bool) {
            guard success else { return }
            if parent.isFocusModeEnabled, let activeRange = focusModeActiveRange,
               let textStorage = textView?.textStorage {
                for dimTarget in FocusModeEditing.dimmedRanges(text: textStorage.string, activeRange: activeRange) {
                    let overlap = NSIntersectionRange(range, dimTarget)
                    guard overlap.length > 0 else { continue }
                    dimRange(overlap, in: textStorage)
                }
            }
            reapplyLivePreviewStylingAfterHighlight(range)
        }

        /// Scrolls so the caret's own line sits vertically centered in the viewport (issue #19
        /// rules 4.4, 4.5). Scrolls `textView` (itself a `UIScrollView`) directly -- since
        /// `scrollViewDidScroll` already fires from any content-offset change and forwards
        /// through `onScroll`/`ScrollSync`, this reuses that existing path automatically
        /// rather than introducing a second scroll-notification mechanism; it never touches
        /// the preview's render pipeline.
        func recenterCaretOnActiveLine(in textView: UITextView) {
            guard parent.isFocusModeEnabled, parent.isFocusModeCentersCaretEnabled else { return }
            let contentHeight = textView.contentSize.height
            let visibleHeight = textView.bounds.height
            guard contentHeight > visibleHeight else { return }
            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            let caretLocation = textView.selectedRange.location
            let length = (textView.text as NSString).length
            guard caretLocation >= 0, caretLocation < length else { return }
            layoutManager.ensureLayout(for: textContainer)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: caretLocation)
            let caretLineTop = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                .origin.y + textView.textContainerInset.top
            let offset = FocusModeEditing.centeringOffset(caretLineTop: caretLineTop, visibleHeight: visibleHeight)
            let clampedOffset = max(0, min(offset, contentHeight - visibleHeight))
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: clampedOffset), animated: false)
        }
    }
#endif
