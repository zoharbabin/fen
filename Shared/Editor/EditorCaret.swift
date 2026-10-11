import Foundation

/// Where the caret or selection is right now (issue #6). The editor writes it on every change. A
/// plain class, so moving the caret never redraws the document view.
final class EditorCaret {
    var range = NSRange(location: 0, length: 0)
}
