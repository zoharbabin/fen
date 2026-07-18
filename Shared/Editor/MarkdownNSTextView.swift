#if os(macOS)
    import AppKit
    import UniformTypeIdentifiers

    /// Lets `MarkdownNSTextView`'s pasteboard override call back into its owning
    /// `MarkdownTextView.Coordinator` (issue #18) without a circular type reference between the
    /// two files' declaration order.
    @MainActor protocol ImagePasteCoordinating: AnyObject {
        func insertPastedImage(data: Data, contentType: UTType, into textView: NSTextView) -> Bool
    }

    /// Custom NSTextView with scroll-past-end and editor features.
    class MarkdownNSTextView: NSTextView {
        var scrollsPastEnd = true
        weak var imagePasteCoordinator: ImagePasteCoordinating?

        /// Pasteboard types AppKit offers here that carry raw image bytes -- e.g. a copied
        /// screenshot with no backing file. Each maps directly to a `UTType` via its raw
        /// identifier, empirically confirmed to conform to `.image` for `.tiff`/`.png` and not
        /// for `.string`/`.pdf`/`.rtf` (issue #18 Phase 3).
        private static let imageDataPasteboardTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]

        /// Both a Finder copy and a Finder drag of one or more files -- image or not -- offer
        /// this legacy type by default (confirmed empirically, issue #18 Phase 3: a modern
        /// `NSURL`-backed pasteboard item still surfaces it, and it's already present in
        /// `readablePasteboardTypes`/`acceptableDragTypes` with no override needed). Its payload
        /// is a property-list array of absolute file paths, not a single `.fileURL` string.
        private static let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

        /// Intercepts an image paste or drop before AppKit's own default rich-text handling
        /// embeds it as an inline `NSTextAttachment` (issue #18) -- this single override point
        /// is where both `paste(_:)` and drag-drop insertion funnel through for a supported
        /// type, per `NSTextView.h`'s own documented override pattern. Any type this method
        /// doesn't specifically handle, or a filename batch containing no image, falls through
        /// to `super`, unchanged.
        override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            guard let imagePasteCoordinator else {
                return super.readSelection(from: pasteboard, type: type)
            }

            if type == Self.filenamesPasteboardType {
                guard let paths = pasteboard.propertyList(forType: type) as? [String], !paths.isEmpty else {
                    return super.readSelection(from: pasteboard, type: type)
                }
                var insertedAny = false
                for path in paths {
                    let fileURL = URL(fileURLWithPath: path)
                    guard let contentType = UTType(filenameExtension: fileURL.pathExtension),
                          contentType.conforms(to: .image),
                          let data = try? Data(contentsOf: fileURL) else { continue }
                    if imagePasteCoordinator.insertPastedImage(data: data, contentType: contentType, into: self) {
                        insertedAny = true
                    }
                }
                return insertedAny ? true : super.readSelection(from: pasteboard, type: type)
            }

            if Self.imageDataPasteboardTypes.contains(type),
               let data = pasteboard.data(forType: type),
               let contentType = UTType(type.rawValue),
               imagePasteCoordinator.insertPastedImage(data: data, contentType: contentType, into: self) {
                return true
            }

            return super.readSelection(from: pasteboard, type: type)
        }

        // MARK: - Limit editor width (issue #50)

        var baseHorizontalInset: CGFloat = 15
        var verticalInset: CGFloat = 30
        var isWidthLimited = false
        var maximumWidth: CGFloat = 800

        /// Recomputes `textContainerInset`'s horizontal component from the view's current
        /// width -- call on every width change and once on initial load (see
        /// `widthLimitedHorizontalInset`'s doc comment for why both call sites matter).
        func applyWidthLimitedInset() {
            let inset = MarkdownTextEditing.widthLimitedHorizontalInset(
                viewWidth: frame.width,
                baseInset: baseHorizontalInset,
                isWidthLimited: isWidthLimited,
                maximumWidth: maximumWidth
            )
            textContainerInset = NSSize(width: inset, height: verticalInset)
        }

        /// The document's real content height, excluding the blank padding
        /// `setFrameSize` adds below the last line when `scrollsPastEnd` is
        /// on. Scroll-fraction math must use this instead of `frame.height`,
        /// or fraction 1.0 lands inside that padding instead of on the
        /// actual last line.
        var contentHeightExcludingScrollPastEnd: CGFloat {
            guard let layoutManager, let textContainer else { return frame.height }
            let usedRect = layoutManager.usedRect(for: textContainer)
            return usedRect.height + 2 * textContainerInset.height
        }

        /// The laid-out y-position of the line fragment containing `index`, in the
        /// same coordinate space as `contentHeightExcludingScrollPastEnd`. Returns
        /// nil for an out-of-range index (e.g. the trailing empty line after a
        /// final newline) so callers can skip that sample.
        func lineTop(forCharacterIndex index: Int) -> CGFloat? {
            guard let layoutManager, let textContainer else { return nil }
            let length = (string as NSString).length
            guard index >= 0, index < length else { return nil }
            layoutManager.ensureLayout(for: textContainer)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            return rect.origin.y + textContainerInset.height
        }

        override func setFrameSize(_ newSize: NSSize) {
            var adjustedSize = newSize
            if scrollsPastEnd, let scrollView = enclosingScrollView {
                let visibleHeight = scrollView.contentSize.height
                let usedRect = layoutManager?.usedRect(for: textContainer!) ?? .zero
                let contentHeight = usedRect.height + 2 * textContainerInset.height
                let extraSpace = max(0, visibleHeight - 50) // Leave 50pt at bottom
                if contentHeight > visibleHeight {
                    adjustedSize.height = max(adjustedSize.height, contentHeight + extraSpace)
                }
            }
            let widthChanged = adjustedSize.width != frame.width
            super.setFrameSize(adjustedSize)
            // Recompute on every width change, not just once -- MacDown's own issue #288 was
            // exactly this check being skipped on resize.
            if widthChanged, isWidthLimited {
                applyWidthLimitedInset()
            }
        }
    }
#endif
