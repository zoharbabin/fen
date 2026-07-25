@testable import FenCore
import Foundation
import Testing

/// Proves rule 2.1 from issue #19's spec: adversarial document text (embedded null bytes,
/// RTL/bidi override characters, and pathologically large single paragraphs) never crashes
/// or escapes `FocusModeEditing`'s range computation -- every returned range stays within the
/// document's bounds regardless of what the text contains.
struct FocusModeSecurityTests {
    @Test func adversarialTextDoesNotCrashOrEscapeRangeComputation() {
        let withNullBytes = "First paragraph.\0with a null byte\0inside it.\n\n\0\0\0\n\nThird\0paragraph."
        assertRangeComputationStaysInBounds(withNullBytes)

        // U+202E (RIGHT-TO-LEFT OVERRIDE) and friends can make naive index math walk off the
        // end of a string when combined with NSString's UTF-16 view.
        let withBidiOverrides =
            "Normal text.\n\n\u{202E}dnoces\u{202C} paragraph with an override.\n\n\u{200F}\u{200E}Third."
        assertRangeComputationStaysInBounds(withBidiOverrides)

        // A multi-megabyte single paragraph with no blank lines anywhere -- the pathological
        // case for any algorithm that scans forward/backward from the caret to find paragraph
        // boundaries, since there is no boundary to find until the very start/end.
        let hugeParagraph = String(repeating: "a", count: 5_000_000)
        assertRangeComputationStaysInBounds(hugeParagraph, caretLocations: [0, 2_500_000, 5_000_000 + 1000])
    }

    private func assertRangeComputationStaysInBounds(
        _ text: String,
        caretLocations: [Int]? = nil
    ) {
        let length = (text as NSString).length
        let locations = caretLocations ?? [0, length / 2, length, length + 1000, -1]

        for caretLocation in locations {
            let activeRange = FocusModeEditing.activeParagraphRange(text: text, caretLocation: caretLocation)
            #expect(activeRange.location >= 0)
            #expect(NSMaxRange(activeRange) <= length)

            let dimmed = FocusModeEditing.dimmedRanges(text: text, activeRange: activeRange)
            for range in dimmed {
                #expect(range.location >= 0)
                #expect(NSMaxRange(range) <= length)
            }

            // centeringOffset takes no text at all, but must still never produce a negative
            // or non-finite offset regardless of what drove the caretLineTop computation.
            let offset = FocusModeEditing.centeringOffset(caretLineTop: CGFloat(caretLocation), visibleHeight: 400)
            #expect(offset.isFinite)
        }
    }
}
