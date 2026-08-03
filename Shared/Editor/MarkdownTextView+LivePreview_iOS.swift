#if !os(macOS)
    import UIKit

    /// Live-preview (WYSIWYG-in-source) editing mode (issue #2) Coordinator methods, split out
    /// of `MarkdownTextView_iOS.swift` to keep that file under the project's file-length lint
    /// limit -- mirrors `MarkdownTextView+LivePreview.swift`'s macOS implementation; see that
    /// file's doc comments for the rules each method satisfies.
    extension MarkdownTextView.Coordinator {
        @MainActor func applyLivePreviewStylingIfNeeded(in textView: UITextView, fullDocument: Bool) {
            let textStorage = textView.textStorage
            guard let widthLimitedTextView = textView as? MarkdownTextView.MarkdownUITextView else { return }
            guard parent.isLivePreviewEnabled else {
                guard livePreviewStyledText != nil else { return }
                clearLivePreviewStyling(in: NSRange(location: 0, length: textStorage.length), textStorage: textStorage)
                removeAllLivePreviewOverlays()
                livePreviewStyledText = nil
                livePreviewCaretParagraphRange = nil
                return
            }

            let text = textView.text ?? ""
            let caretLocation = textView.selectedRange.location
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
                    textView: widthLimitedTextView
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
                    textView: widthLimitedTextView
                )
            }
            restyleLines(
                in: newActiveRange,
                text: text,
                textStorage: textStorage,
                activeRange: newActiveRange,
                textView: widthLimitedTextView
            )
        }

        @MainActor func reapplyLivePreviewStylingAfterHighlight(_ range: NSRange) {
            guard parent.isLivePreviewEnabled, let textView = textView as? MarkdownTextView.MarkdownUITextView
            else { return }
            let activeRange = livePreviewCaretParagraphRange ?? NSRange(location: 0, length: 0)
            restyleLines(
                in: range,
                text: textView.text ?? "",
                textStorage: textView.textStorage,
                activeRange: activeRange,
                textView: textView
            )
        }

        // MARK: - Line-by-line restyling

        @MainActor private func restyleLines(
            in range: NSRange,
            text: String,
            textStorage: NSTextStorage,
            activeRange: NSRange,
            textView: MarkdownTextView.MarkdownUITextView
        ) {
            let ns = text as NSString
            guard ns.length > 0 else { return }
            let expandedRange = ns.lineRange(for: boundedRange(range, in: ns))
            clearLivePreviewStyling(in: expandedRange, textStorage: textStorage)
            removeOverlays(overlapping: expandedRange)
            guard expandedRange.length > 0 else { return }
            // Rule 2.1/2.2 (issue #128): computed once per call, not per line -- a fence spans
            // multiple lines, so each line's membership can't be decided from that line alone.
            let fencedRanges = LivePreviewEditing.fencedRanges(text: text)

            // Collects checkbox/image spans that need an overlay positioned, so that work --
            // which calls `rect(forCharacterRange:)` and thus triggers glyph generation -- can
            // happen only after `endEditing()` below. Calling it while textStorage is still
            // mid-edit crashes with "attempted glyph generation while textStorage is editing"
            // (mirrors the macOS implementation's identical fix).
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

        @MainActor private func styleLine(
            _ line: String, lineStart: Int, textStorage: NSTextStorage, textView: MarkdownTextView.MarkdownUITextView,
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

        /// Checkbox/image overlays are only created/updated here -- never positioned, since
        /// positioning calls `rect(forCharacterRange:)`, which triggers glyph generation and
        /// crashes if run while `textStorage` is still inside `beginEditing()`/`endEditing()`.
        /// Instead, this appends `span` to `pendingOverlaySpans` so the caller can position it
        /// once editing ends.
        @MainActor private func applySpan(
            _ span: LivePreviewEditing.Span, textStorage: NSTextStorage, textView: MarkdownTextView.MarkdownUITextView,
            pendingOverlaySpans: inout [LivePreviewEditing.Span]
        ) {
            // Rule 3.1: an image whose path doesn't resolve/decode must leave its raw
            // `![alt](path)` syntax fully visible -- checked before any marker-hiding happens,
            // never hidden-then-shown-blank.
            if case let .image(altText, path) = span.kind {
                guard addImageOverlay(altText: altText, path: path, range: fullSpanRange(span), in: textView)
                else { return }
            }
            let backgroundColor = textView.backgroundColor ?? .systemBackground
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

        // MARK: - Marker hiding / content styling

        @MainActor private func stashOriginalIfNeeded(_ range: NSRange, in textStorage: NSTextStorage) {
            guard range.length > 0 else { return }
            textStorage.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
                guard textStorage.attribute(.livePreviewTouched, at: subrange.location, effectiveRange: nil) == nil
                else { return }
                let originalColor = attributes[.foregroundColor] as? UIColor ?? .label
                let originalFont = attributes[.font] as? UIFont ?? .systemFont(ofSize: UIFont.systemFontSize)
                textStorage.addAttribute(.livePreviewOriginalForegroundColor, value: originalColor, range: subrange)
                textStorage.addAttribute(.livePreviewOriginalFont, value: originalFont, range: subrange)
                textStorage.addAttribute(.livePreviewTouched, value: true, range: subrange)
            }
        }

        @MainActor private func applyMarkerHidden(
            _ range: NSRange,
            in textStorage: NSTextStorage,
            backgroundColor: UIColor
        ) {
            guard range.length > 0 else { return }
            stashOriginalIfNeeded(range, in: textStorage)
            let font = currentFont(at: range.location, in: textStorage)
            textStorage.addAttribute(.foregroundColor, value: backgroundColor, range: range)
            textStorage.addAttribute(.font, value: hiddenFont(from: font), range: range)
        }

        /// Shrinks `font` to near-zero size, so a hidden marker run still occupies almost no
        /// horizontal space instead of leaving a gap-sized hole in the line.
        private func hiddenFont(from font: UIFont) -> UIFont {
            font.withSize(0.01)
        }

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
                break
            case let .heading(level):
                applyHeadingStyle(level: level, to: range, in: textStorage)
            case .blockquote:
                let font = currentFont(at: range.location, in: textStorage)
                textStorage.addAttribute(.font, value: italicFont(font), range: range)
                let color = (textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
                    as? UIColor ?? .label).withAlphaComponent(0.7)
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

        private func currentFont(at location: Int, in textStorage: NSTextStorage) -> UIFont {
            (textStorage.attribute(.font, at: location, effectiveRange: nil) as? UIFont)
                ?? .systemFont(ofSize: UIFont.systemFontSize)
        }

        private func boldFont(_ font: UIFont) -> UIFont {
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(.traitBold)
            ) else { return font }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }

        private func italicFont(_ font: UIFont) -> UIFont {
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(.traitItalic)
            ) else { return font }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }

        private func applyHeadingStyle(level: Int, to range: NSRange, in textStorage: NSTextStorage) {
            let font = currentFont(at: range.location, in: textStorage)
            let scale = max(1.0, 1.6 - CGFloat(level - 1) * 0.12)
            let scaledFont = font.withSize(font.pointSize * scale)
            textStorage.addAttribute(.font, value: boldFont(scaledFont), range: range)
        }

        @MainActor private func clearLivePreviewStyling(in range: NSRange, textStorage: NSTextStorage) {
            guard range.length > 0 else { return }
            textStorage.beginEditing()
            textStorage.enumerateAttribute(.livePreviewTouched, in: range, options: []) { value, subrange, _ in
                guard value != nil else { return }
                if let originalColor = textStorage.attribute(
                    .livePreviewOriginalForegroundColor, at: subrange.location, effectiveRange: nil
                ) as? UIColor {
                    textStorage.addAttribute(.foregroundColor, value: originalColor, range: subrange)
                }
                if let originalFont = textStorage.attribute(
                    .livePreviewOriginalFont, at: subrange.location, effectiveRange: nil
                ) as? UIFont {
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

        // MARK: - Checkbox overlay (tap-to-toggle)

        /// Creates (or updates the checked state of) the checkbox button for `range`. Never calls
        /// `rect(forCharacterRange:)` -- positioning happens later in `positionOverlay`, once the
        /// caller's `textStorage` edit transaction has ended.
        @MainActor private func addCheckboxOverlay(
            checked: Bool, range: NSRange, in textView: MarkdownTextView.MarkdownUITextView
        ) {
            let key = range.location
            let button: UIButton
            if let existing = livePreviewCheckboxOverlays[key] {
                button = existing
            } else {
                button = UIButton(type: .system)
                button.addTarget(self, action: #selector(livePreviewCheckboxToggled(_:)), for: .touchUpInside)
                livePreviewCheckboxOverlays[key] = button
                textView.addSubview(button)
            }
            let symbolName = checked ? "checkmark.square.fill" : "square"
            button.setImage(UIImage(systemName: symbolName), for: .normal)
            button.tag = key
        }

        @MainActor @objc private func livePreviewCheckboxToggled(_ sender: UIButton) {
            guard let textView else { return }
            let ns = (textView.text ?? "") as NSString
            let clampedLocation = max(0, min(sender.tag, max(0, ns.length - 1)))
            let lineRange = ns.lineRange(for: NSRange(location: clampedLocation, length: 0))
            let result = MarkdownFormatting.apply(.taskItem, to: textView.text ?? "", selection: lineRange)
            textView.text = result.text
            textView.selectedRange = result.selection
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
            altText: String, path: String, range: NSRange, in textView: MarkdownTextView.MarkdownUITextView
        ) -> Bool {
            guard let documentURL,
                  let resolved = LivePreviewImageResolution.resolvedFileURL(
                      relativePath: path, documentDirectory: documentURL.deletingLastPathComponent()
                  ) else { return false }
            let image: UIImage
            if let cached = livePreviewImageCache[resolved.path] {
                image = cached
            } else if let loaded = UIImage(contentsOfFile: resolved.path) {
                livePreviewImageCache[resolved.path] = loaded
                image = loaded
            } else {
                return false
            }

            let key = range.location
            let imageView: UIImageView
            if let existing = livePreviewImageOverlays[key] {
                imageView = existing
            } else {
                imageView = UIImageView()
                imageView.contentMode = .scaleAspectFit
                livePreviewImageOverlays[key] = imageView
                textView.addSubview(imageView)
            }
            imageView.image = image
            imageView.accessibilityLabel = altText
            return true
        }

        /// Positions the checkbox/image overlay `span` created, now that `restyleLines`' edit
        /// transaction has ended and `rect(forCharacterRange:)` can safely trigger glyph
        /// generation. A missing `rect` (layout not yet available this pass) just skips
        /// positioning -- the overlay stays wherever it last was, or at its default frame.
        @MainActor private func positionOverlay(
            for span: LivePreviewEditing.Span, in textView: MarkdownTextView.MarkdownUITextView
        ) {
            let range = fullSpanRange(span)
            guard let rect = textView.rect(forCharacterRange: range) else { return }
            let key = range.location
            switch span.kind {
            case .checkbox:
                guard let button = livePreviewCheckboxOverlays[key] else { return }
                let side = max(rect.height, 20)
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

        @MainActor private func removeOverlays(overlapping range: NSRange) {
            let end = range.location + range.length
            for (key, button) in livePreviewCheckboxOverlays where key >= range.location && key < end {
                button.removeFromSuperview()
                livePreviewCheckboxOverlays.removeValue(forKey: key)
            }
            for (key, imageView) in livePreviewImageOverlays where key >= range.location && key < end {
                imageView.removeFromSuperview()
                livePreviewImageOverlays.removeValue(forKey: key)
            }
        }

        @MainActor private func removeAllLivePreviewOverlays() {
            for button in livePreviewCheckboxOverlays.values {
                button.removeFromSuperview()
            }
            livePreviewCheckboxOverlays.removeAll()
            for imageView in livePreviewImageOverlays.values {
                imageView.removeFromSuperview()
            }
            livePreviewImageOverlays.removeAll()
        }
    }
#endif
