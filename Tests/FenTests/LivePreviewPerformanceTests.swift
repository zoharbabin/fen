import AppKit
@testable import FenCore
import Foundation
import Highlightr
import Testing

/// Issue #135: restyling a long note must stay linear. `CodeAttributedString` once made every attribute write
/// cost more as the note grew, so 6000 lines took about 5 seconds and a second pass took minutes.
@MainActor
struct LivePreviewPerformanceTests {
    private func makeNote(blocks: Int) -> String {
        var note = ""
        for index in 0 ..< blocks {
            note += "# Heading \(index)\n\nSome **bold** and *italic* text with `code` and [link](http://x.y).\n\n"
            note += "- item one\n- item two\n  - nested\n\n| a | b |\n|---|---|\n| \(index) | **x** |\n\n"
            note += "```swift\nlet x = \(index)\n```\n\n---\n\n> quote\n\n"
        }
        return note
    }

    @Test func restylingALongNoteStaysFast() {
        let note = makeNote(blocks: 300)
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let storage = CodeAttributedString()
        storage.language = "markdown"
        let layoutManager = DecorationLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let view = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.isRichText = true
        view.font = font
        view.string = note
        let parent = MarkdownTextView(
            text: .constant(note),
            font: font,
            highlightThemeName: "xcode",
            lineSpacing: 0,
            horizontalInset: 0,
            verticalInset: 0,
            isEditable: true,
            scrollsPastEnd: false,
            isLivePreviewEnabled: true,
            documentURL: nil
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = view
        storage.highlightDelegate = coordinator
        view.setSelectedRange(NSRange(location: 5, length: 0))

        let clock = ContinuousClock()
        let full = clock.measure { coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true) }
        let again = clock.measure { coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true) }
        let move = clock.measure {
            view.setSelectedRange(NSRange(location: 2000, length: 0))
            coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: false)
        }
        // About 0.3 s, 0.5 s and 0.01 s on a laptop. The limits leave room for a slow CI machine and still fail
        // on the quadratic version, which took 5 s, 6 s and 0.1 s.
        #expect(full < .seconds(3), "full restyle took \(full)")
        #expect(again < .seconds(3), "second restyle took \(again)")
        #expect(move < .seconds(0.5), "caret move took \(move)")
    }

    /// The cause: a batch of attribute writes must cost the same per write at any size.
    @Test func attributeWritesInABatchScaleLinearly() {
        let key = NSAttributedString.Key("fen.test")
        func seconds(lines: Int) -> Double {
            let storage = CodeAttributedString()
            storage.language = "markdown"
            storage.replaceCharacters(
                in: NSRange(location: 0, length: 0), with: String(repeating: "hello world line\n", count: lines)
            )
            let elapsed = ContinuousClock().measure {
                storage.beginEditing()
                for line in 0 ..< lines {
                    storage.addAttribute(key, value: line, range: NSRange(location: line * 17, length: 5))
                }
                storage.endEditing()
            }
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        let small = max(seconds(lines: 3000), 0.001)
        let large = seconds(lines: 12000)
        // Four times the writes. Linear is 4x. The quadratic version was about 11x.
        #expect(large / small < 8, "3000 lines took \(small) s and 12000 lines took \(large) s")
    }
}
