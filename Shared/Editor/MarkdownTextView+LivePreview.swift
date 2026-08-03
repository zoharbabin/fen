#if os(macOS)
    import AppKit

    /// Live-preview (WYSIWYG-in-source) editing mode (issue #2) Coordinator methods, split out
    /// of `MarkdownTextView.swift` to keep that file under the project's file-length lint limit --
    /// mirrors `MarkdownTextView+FocusMode.swift`'s precedent.
    extension MarkdownTextView.Coordinator {
        /// Recomputes live-preview styling from the caret's current position and the document's
        /// current text, applying rules 4.1/4.2's staleness gating: a text change (or the toggle
        /// just flipping, `fullDocument: true`) re-styles the whole document; a pure caret move
        /// only re-styles the previous and new active paragraphs. The active paragraph -- the one
        /// containing the caret -- is always shown as plain, unstyled source text so it stays
        /// directly editable; every other paragraph gets markers hidden and content styled.
        @MainActor func applyLivePreviewStylingIfNeeded(in textView: MarkdownNSTextView, fullDocument: Bool) {
            guard let textStorage = textView.textStorage else { return }
            guard parent.isLivePreviewEnabled else {
                guard livePreviewStyledText != nil else { return }
                clearLivePreviewStyling(in: NSRange(location: 0, length: textStorage.length), textStorage: textStorage)
                removeAllLivePreviewOverlays(in: textView)
                livePreviewStyledText = nil
                livePreviewCaretParagraphRange = nil
                return
            }

            let text = textView.string
            let caretLocation = textView.selectedRange().location
            let newActiveRange = FocusModeEditing.activeParagraphRange(text: text, caretLocation: caretLocation)
            let textChanged = text != livePreviewStyledText

            guard !fullDocument, !textChanged else {
                livePreviewStyledText = text
                livePreviewCaretParagraphRange = newActiveRange
                restyleLines(
                    in: NSRange(location: 0, length: (text as NSString).length),
                    text: text,
                    textStorage: textStorage,
                    activeRange: newActiveRange,
                    textView: textView
                )
                return
            }

            guard newActiveRange != livePreviewCaretParagraphRange else { return }
            let previousActiveRange = livePreviewCaretParagraphRange
            livePreviewCaretParagraphRange = newActiveRange
            if let previousActiveRange {
                restyleLines(
                    in: previousActiveRange,
                    text: text,
                    textStorage: textStorage,
                    activeRange: newActiveRange,
                    textView: textView
                )
            }
            restyleLines(
                in: newActiveRange,
                text: text,
                textStorage: textStorage,
                activeRange: newActiveRange,
                textView: textView
            )
        }

        /// Reapplies live-preview styling to whatever portion of Highlightr's just-completed
        /// re-highlight `range` this feature has an opinion about, composing over the fresh
        /// syntax-highlighting attributes `setAttributes` just replaced the whole range with --
        /// called from `didHighlight` (`MarkdownTextView+FocusMode.swift`) once that async pass
        /// lands, mirroring focus mode's own re-dim composition for the same reason: it would
        /// otherwise silently wipe out styling applied before it.
        @MainActor func reapplyLivePreviewStylingAfterHighlight(_ range: NSRange) {
            guard parent.isLivePreviewEnabled, let textView, let textStorage = textView.textStorage else { return }
            let activeRange = livePreviewCaretParagraphRange ?? NSRange(location: 0, length: 0)
            restyleLines(
                in: range,
                text: textView.string,
                textStorage: textStorage,
                activeRange: activeRange,
                textView: textView
            )
        }

        // MARK: - Line-by-line restyling

        /// Restyles every full line overlapping `range`: clears whatever this feature previously
        /// applied there, then either leaves each line plain (if it overlaps `activeRange`) or
        /// hides its markers and styles its content. Always widens `range` to whole lines first --
        /// a partial-line range would leave that line's spans half-styled.
        @MainActor private func restyleLines(
            in range: NSRange,
            text: String,
            textStorage: NSTextStorage,
            activeRange: NSRange,
            textView: MarkdownNSTextView
        ) {
            let ns = text as NSString
            guard ns.length > 0 else { return }
            let expandedRange = ns.lineRange(for: boundedRange(range, in: ns))
            clearLivePreviewStyling(in: expandedRange, textStorage: textStorage)
            removeOverlays(overlapping: expandedRange, textView: textView)
            guard expandedRange.length > 0 else { return }
            // Rule 2.1/2.2 (issue #128): computed once per call, not per line -- a fence spans
            // multiple lines, so each line's membership can't be decided from that line alone.
            let fencedRanges = LivePreviewEditing.fencedRanges(text: text)

            // Collects checkbox/image spans that need an overlay positioned, so that work --
            // which calls `rect(forCharacterRange:)` and thus triggers glyph generation -- can
            // happen only after `endEditing()` below. Calling it while textStorage is still
            // mid-edit crashes AppKit with "attempted glyph generation while textStorage is
            // editing".
            var pendingOverlaySpans: [LivePreviewEditing.Span] = []

            textStorage.beginEditing()
            var location = expandedRange.location
            let end = expandedRange.location + expandedRange.length
            while location < end {
                let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
                guard lineRange.length > 0 else { break }
                let contentLineRange = strippingTrailingNewline(lineRange, in: ns)
                let isActive = NSIntersectionRange(contentLineRange, activeRange).length > 0
                    || (contentLineRange.length == 0 && activeRange.length == 0
                        && contentLineRange.location == activeRange.location)
                if !isActive {
                    let line = ns.substring(with: contentLineRange)
                    // Fenced ranges are always whole lines (`LivePreviewEditing.fencedRanges`
                    // builds them from `lineRange(for:)`), so a line belongs to one if its start
                    // falls within it -- no need for a length-aware intersection check.
                    let isFenced = fencedRanges.contains {
                        contentLineRange.location >= $0.location
                            && contentLineRange.location < $0.location + $0.length
                    }
                    if !LivePreviewEditing.isTableRow(line: line), !isFenced {
                        styleLine(
                            line,
                            lineStart: contentLineRange.location,
                            textStorage: textStorage,
                            textView: textView,
                            pendingOverlaySpans: &pendingOverlaySpans
                        )
                    }
                }
                location = lineRange.location + lineRange.length
            }
            textStorage.endEditing()

            for span in pendingOverlaySpans {
                positionOverlay(for: span, in: textView)
            }
        }

        private func boundedRange(_ range: NSRange, in ns: NSString) -> NSRange {
            let location = max(0, min(range.location, ns.length))
            let length = max(0, min(range.length, ns.length - location))
            return NSRange(location: location, length: length)
        }

        private func strippingTrailingNewline(_ lineRange: NSRange, in ns: NSString) -> NSRange {
            var contentRange = lineRange
            guard contentRange.length > 0 else { return contentRange }
            let lastIndex = contentRange.location + contentRange.length - 1
            if ns.character(at: lastIndex) == 10 { // "\n"
                contentRange.length -= 1
            }
            if contentRange.length > 0 {
                let secondLastIndex = contentRange.location + contentRange.length - 1
                if ns.character(at: secondLastIndex) == 13 { // "\r"
                    contentRange.length -= 1
                }
            }
            return contentRange
        }

        /// Finds and applies every block-level and inline span on one (already newline-stripped)
        /// line, dispatching each to `applySpan`.
        @MainActor private func styleLine(
            _ line: String, lineStart: Int, textStorage: NSTextStorage, textView: MarkdownNSTextView,
            pendingOverlaySpans: inout [LivePreviewEditing.Span]
        ) {
            var content = line
            var contentStart = lineStart
            if let blockSpan = LivePreviewEditing.blockPrefixSpan(line: line, lineStart: lineStart) {
                applySpan(
                    blockSpan, textStorage: textStorage, textView: textView, pendingOverlaySpans: &pendingOverlaySpans
                )
                let consumed = blockSpan.contentRange.location - lineStart
                content = String(line.dropFirst(consumed))
                contentStart = blockSpan.contentRange.location
                // A checkbox's own content ("[ ]"/"[x]") isn't Markdown inline syntax -- don't
                // scan it for bold/italic/etc.
                if case .checkbox = blockSpan.kind {
                    return
                }
            }
            for inlineSpan in LivePreviewEditing.inlineSpans(in: content, textStart: contentStart) {
                applySpan(
                    inlineSpan,
                    textStorage: textStorage,
                    textView: textView,
                    pendingOverlaySpans: &pendingOverlaySpans
                )
            }
        }

        /// Hides every marker range and, for constructs with visible replacement UI (checkbox,
        /// image), also hides the raw content and shows an overlay in its place; every other kind
        /// gets its content range styled to reflect its markup (rule 5.1's shared hide-marker
        /// helper, `applyMarkerHidden`, is reused across every span kind here). Checkbox/image
        /// overlays are only created/updated here -- never positioned, since positioning calls
        /// `rect(forCharacterRange:)`, which triggers glyph generation and crashes AppKit if run
        /// while `textStorage` is still inside `beginEditing()`/`endEditing()`. Instead, this
        /// appends `span` to `pendingOverlaySpans` so the caller can position it once editing ends.
        @MainActor private func applySpan(
            _ span: LivePreviewEditing.Span, textStorage: NSTextStorage, textView: MarkdownNSTextView,
            pendingOverlaySpans: inout [LivePreviewEditing.Span]
        ) {
            // Rule 3.1: an image whose path doesn't resolve/decode must leave its raw
            // `![alt](path)` syntax fully visible -- checked before any marker-hiding happens,
            // never hidden-then-shown-blank.
            if case let .image(altText, path) = span.kind {
                guard addImageOverlay(altText: altText, path: path, range: fullSpanRange(span), in: textView)
                else { return }
            }
            let backgroundColor = textView.backgroundColor
            for marker in span.markerRanges {
                applyMarkerHidden(marker, in: textStorage, backgroundColor: backgroundColor)
            }
            switch span.kind {
            case let .checkbox(checked):
                applyMarkerHidden(span.contentRange, in: textStorage, backgroundColor: backgroundColor)
                addCheckboxOverlay(checked: checked, range: fullSpanRange(span), in: textView)
                pendingOverlaySpans.append(span)
            case .image:
                applyMarkerHidden(span.contentRange, in: textStorage, backgroundColor: backgroundColor)
                pendingOverlaySpans.append(span)
            default:
                applyContentStyle(span, in: textStorage)
            }
        }

        private func fullSpanRange(_ span: LivePreviewEditing.Span) -> NSRange {
            var minLocation = span.contentRange.location
            var maxEnd = span.contentRange.location + span.contentRange.length
            for marker in span.markerRanges {
                minLocation = min(minLocation, marker.location)
                maxEnd = max(maxEnd, marker.location + marker.length)
            }
            return NSRange(location: minLocation, length: maxEnd - minLocation)
        }

        // MARK: - Marker hiding / content styling (rule 5.1's shared stash-then-overwrite helper)

        /// Stashes `range`'s current font/color (unless already stashed) and marks it touched --
        /// shared by both marker-hiding and content-styling below, since both overwrite
        /// attributes that `clearLivePreviewStyling` must later be able to restore exactly.
        @MainActor private func stashOriginalIfNeeded(_ range: NSRange, in textStorage: NSTextStorage) {
            guard range.length > 0 else { return }
            textStorage.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
                guard textStorage.attribute(.livePreviewTouched, at: subrange.location, effectiveRange: nil) == nil
                else { return }
                let originalColor = attributes[.foregroundColor] as? NSColor ?? .textColor
                let originalFont = attributes[.font] as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
                textStorage.addAttribute(.livePreviewOriginalForegroundColor, value: originalColor, range: subrange)
                textStorage.addAttribute(.livePreviewOriginalFont, value: originalFont, range: subrange)
                textStorage.addAttribute(.livePreviewTouched, value: true, range: subrange)
            }
        }

        /// Shrinks `range`'s font to near-zero size and matches its color to `backgroundColor` --
        /// together, effectively invisible and taking almost no horizontal space -- reused across
        /// every span kind's marker ranges (rule 5.1).
        @MainActor private func applyMarkerHidden(
            _ range: NSRange,
            in textStorage: NSTextStorage,
            backgroundColor: NSColor
        ) {
            guard range.length > 0 else { return }
            stashOriginalIfNeeded(range, in: textStorage)
            let font = currentFont(at: range.location, in: textStorage)
            textStorage.addAttribute(.foregroundColor, value: backgroundColor, range: range)
            textStorage.addAttribute(.font, value: hiddenFont(from: font), range: range)
        }

        /// Shrinks `font` to near-zero size, so a hidden marker run still occupies almost no
        /// horizontal space instead of leaving a gap-sized hole in the line.
        private func hiddenFont(from font: NSFont) -> NSFont {
            NSFont(descriptor: font.fontDescriptor, size: 0.01) ?? font
        }

        /// Applies the real visual weight a span's markup implies to its content range: bold,
        /// italic, strikethrough, heading size, blockquote emphasis, or a real clickable link.
        /// Checkbox/image content is handled entirely by the overlay path in `applySpan`, never
        /// here.
        @MainActor private func applyContentStyle(_ span: LivePreviewEditing.Span, in textStorage: NSTextStorage) {
            let range = span.contentRange
            guard range.length > 0 else { return }
            stashOriginalIfNeeded(range, in: textStorage)
            switch span.kind {
            case .bold:
                textStorage.addAttribute(
                    .font,
                    value: boldFont(currentFont(at: range.location, in: textStorage)),
                    range: range
                )
            case .italic:
                textStorage.addAttribute(
                    .font, value: italicFont(currentFont(at: range.location, in: textStorage)), range: range
                )
            case .strikethrough:
                textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .inlineCode:
                break // marker-hiding alone is enough; content keeps its existing code styling
            case let .heading(level):
                applyHeadingStyle(level: level, to: range, in: textStorage)
            case .blockquote:
                let font = currentFont(at: range.location, in: textStorage)
                textStorage.addAttribute(.font, value: italicFont(font), range: range)
                let color = (textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
                    as? NSColor ?? .textColor).withAlphaComponent(0.7)
                textStorage.addAttribute(.foregroundColor, value: color, range: range)
            case let .link(url):
                textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                if let linkURL = URL(string: url) {
                    textStorage.addAttribute(.link, value: linkURL, range: range)
                }
            case .checkbox, .image:
                break
            }
        }

        private func currentFont(at location: Int, in textStorage: NSTextStorage) -> NSFont {
            (textStorage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
                ?? .systemFont(ofSize: NSFont.systemFontSize)
        }

        private func boldFont(_ font: NSFont) -> NSFont {
            NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }

        private func italicFont(_ font: NSFont) -> NSFont {
            NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }

        private func applyHeadingStyle(level: Int, to range: NSRange, in textStorage: NSTextStorage) {
            let font = currentFont(at: range.location, in: textStorage)
            let scale = max(1.0, 1.6 - CGFloat(level - 1) * 0.12)
            let scaledFont = NSFontManager.shared.convert(font, toSize: font.pointSize * scale)
            textStorage.addAttribute(.font, value: boldFont(scaledFont), range: range)
        }

        /// Restores every subrange this feature has touched within `range` to its stashed
        /// original font/color, and removes every attribute this feature might have added
        /// (rules 3.5/4.1: a text change or the toggle turning off must fully undo styling, never
        /// leave stale attributes behind for `clearLivePreviewStyling` calls that follow).
        @MainActor private func clearLivePreviewStyling(in range: NSRange, textStorage: NSTextStorage) {
            guard range.length > 0 else { return }
            textStorage.beginEditing()
            textStorage.enumerateAttribute(.livePreviewTouched, in: range, options: []) { value, subrange, _ in
                guard value != nil else { return }
                if let originalColor = textStorage.attribute(
                    .livePreviewOriginalForegroundColor, at: subrange.location, effectiveRange: nil
                ) as? NSColor {
                    textStorage.addAttribute(.foregroundColor, value: originalColor, range: subrange)
                }
                if let originalFont = textStorage.attribute(
                    .livePreviewOriginalFont, at: subrange.location, effectiveRange: nil
                ) as? NSFont {
                    textStorage.addAttribute(.font, value: originalFont, range: subrange)
                }
                textStorage.removeAttribute(.livePreviewOriginalForegroundColor, range: subrange)
                textStorage.removeAttribute(.livePreviewOriginalFont, range: subrange)
                textStorage.removeAttribute(.livePreviewTouched, range: subrange)
                textStorage.removeAttribute(.strikethroughStyle, range: subrange)
                textStorage.removeAttribute(.underlineStyle, range: subrange)
                textStorage.removeAttribute(.link, range: subrange)
            }
            textStorage.endEditing()
        }

        // MARK: - Checkbox overlay (click-to-toggle)

        /// Creates (or updates the checked state of) the checkbox button for `range`. Never calls
        /// `rect(forCharacterRange:)` -- positioning happens later in `positionOverlay`, once the
        /// caller's `textStorage` edit transaction has ended.
        @MainActor private func addCheckboxOverlay(checked: Bool, range: NSRange, in textView: MarkdownNSTextView) {
            let key = range.location
            let button: NSButton
            if let existing = livePreviewCheckboxOverlays[key] {
                button = existing
            } else {
                button = NSButton(
                    checkboxWithTitle: "",
                    target: self,
                    action: #selector(livePreviewCheckboxToggled(_:))
                )
                button.translatesAutoresizingMaskIntoConstraints = true
                button.setAccessibilityIdentifier("LivePreviewCheckboxOverlay")
                livePreviewCheckboxOverlays[key] = button
                textView.addSubview(button)
                textView.accessibilityOverlaySubviews.append(button)
            }
            button.state = checked ? .on : .off
            button.tag = key
        }

        /// Toggles the checkbox at this button's line, routing through the exact same
        /// `MarkdownFormatting.apply(.taskItem, ...)` logic the formatting toolbar/menu use, so
        /// live preview can never diverge from what a manual toggle would produce.
        @MainActor @objc private func livePreviewCheckboxToggled(_ sender: NSButton) {
            guard let textView else { return }
            let ns = textView.string as NSString
            let clampedLocation = max(0, min(sender.tag, max(0, ns.length - 1)))
            let lineRange = ns.lineRange(for: NSRange(location: clampedLocation, length: 0))
            let result = MarkdownFormatting.apply(.taskItem, to: textView.string, selection: lineRange)
            textView.string = result.text
            textView.setSelectedRange(result.selection)
            parent.text = result.text
            parent.onTextChange?()
            applyLivePreviewStylingIfNeeded(in: textView, fullDocument: true)
        }

        // MARK: - Inline image overlay (local files only, issue #2 rule 2.2)

        /// Resolves and decodes `path`, creating (or updating the image of) an overlay for
        /// `range` on success. Returns whether the image actually loaded -- rule 3.1: a `false`
        /// result tells the caller to leave the raw `![alt](path)` syntax visible instead of
        /// hiding it. Never calls `rect(forCharacterRange:)` -- positioning happens later in
        /// `positionOverlay`, once the caller's `textStorage` edit transaction has ended.
        @MainActor private func addImageOverlay(
            altText: String,
            path: String,
            range: NSRange,
            in textView: MarkdownNSTextView
        ) -> Bool {
            guard let documentURL,
                  let resolved = LivePreviewImageResolution.resolvedFileURL(
                      relativePath: path, documentDirectory: documentURL.deletingLastPathComponent()
                  ) else { return false }
            let image: NSImage
            if let cached = livePreviewImageCache[resolved.path] {
                image = cached
            } else if let loaded = NSImage(contentsOfFile: resolved.path) {
                livePreviewImageCache[resolved.path] = loaded
                image = loaded
            } else {
                return false
            }

            let key = range.location
            let imageView: NSImageView
            if let existing = livePreviewImageOverlays[key] {
                imageView = existing
            } else {
                imageView = NSImageView()
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.setAccessibilityIdentifier("LivePreviewImageOverlay")
                livePreviewImageOverlays[key] = imageView
                textView.addSubview(imageView)
                textView.accessibilityOverlaySubviews.append(imageView)
            }
            imageView.image = image
            imageView.setAccessibilityLabel(altText)
            return true
        }

        /// Positions the checkbox/image overlay `span` created, now that `restyleLines`' edit
        /// transaction has ended and `rect(forCharacterRange:)` can safely trigger glyph
        /// generation. A missing `rect` (layout not yet available this pass) just skips
        /// positioning -- the overlay stays wherever it last was, or at its `NSView` default.
        @MainActor private func positionOverlay(for span: LivePreviewEditing.Span, in textView: MarkdownNSTextView) {
            let range = fullSpanRange(span)
            guard let rect = textView.rect(forCharacterRange: range) else { return }
            let key = range.location
            switch span.kind {
            case .checkbox:
                guard let button = livePreviewCheckboxOverlays[key] else { return }
                let side = max(rect.height, 16)
                button.frame = CGRect(
                    x: rect.minX, y: rect.minY - (side - rect.height) / 2, width: side, height: side
                )
            case .image:
                guard let imageView = livePreviewImageOverlays[key], let image = imageView.image else { return }
                let maxWidth: CGFloat = 320
                let maxHeight: CGFloat = 240
                let aspectRatio = image.size.width > 0 ? image.size.height / image.size.width : 1
                let width = min(maxWidth, max(image.size.width, 1))
                let height = min(width * aspectRatio, maxHeight)
                imageView.frame = CGRect(x: rect.minX, y: rect.minY, width: width, height: height)
            default:
                break
            }
        }

        // MARK: - Overlay bookkeeping

        @MainActor private func removeOverlays(overlapping range: NSRange, textView: MarkdownNSTextView) {
            let end = range.location + range.length
            for (key, button) in livePreviewCheckboxOverlays where key >= range.location && key < end {
                button.removeFromSuperview()
                textView.accessibilityOverlaySubviews.removeAll { $0 === button }
                livePreviewCheckboxOverlays.removeValue(forKey: key)
            }
            for (key, imageView) in livePreviewImageOverlays where key >= range.location && key < end {
                imageView.removeFromSuperview()
                textView.accessibilityOverlaySubviews.removeAll { $0 === imageView }
                livePreviewImageOverlays.removeValue(forKey: key)
            }
        }

        @MainActor private func removeAllLivePreviewOverlays(in textView: MarkdownNSTextView) {
            for button in livePreviewCheckboxOverlays.values {
                button.removeFromSuperview()
                textView.accessibilityOverlaySubviews.removeAll { $0 === button }
            }
            livePreviewCheckboxOverlays.removeAll()
            for imageView in livePreviewImageOverlays.values {
                imageView.removeFromSuperview()
                textView.accessibilityOverlaySubviews.removeAll { $0 === imageView }
            }
            livePreviewImageOverlays.removeAll()
        }
    }
#endif
