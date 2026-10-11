import Foundation

/// What a text view remembers between calls for related documents (issue #8). A class, because a
/// SwiftUI view's coordinator can't hold new stored properties from an extension.
final class RelatedEditorState {
    /// How long after your last keystroke the caret's paragraph still counts as "being written".
    static let writingWindow: Duration = .seconds(3)

    private(set) var lastEdit: ContinuousClock.Instant?
    var appliedInsertion: UUID?

    func noteEdit() {
        lastEdit = .now
    }

    var isWriting: Bool {
        lastEdit.map { .now - $0 < Self.writingWindow } ?? false
    }
}
