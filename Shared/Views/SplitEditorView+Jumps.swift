import Observation
import SwiftUI

/// A request to open a document at a line, such as a citation in an answer (issue #141). The
/// editor takes the request once its text has rendered, so a document that is not open yet lands
/// on the line when it appears.
@MainActor @Observable
public final class DocumentJumps {
    public static let shared = DocumentJumps()

    /// Bumps on every request, so an open editor notices.
    public private(set) var revision = 0
    @ObservationIgnored private var lines: [String: Int] = [:]

    public init() {}

    public func request(line: Int, in url: URL) {
        lines[Self.key(url)] = max(1, line)
        revision += 1
    }

    /// The pending line for `url`, once. `nil` when there is none.
    func take(for url: URL?) -> Int? {
        guard let url else { return nil }
        return lines.removeValue(forKey: Self.key(url))
    }

    private static func key(_ url: URL) -> String {
        (PathGate.canonicalURL(of: url) ?? url.standardizedFileURL).path
    }
}

extension View {
    /// Scrolls to the line `DocumentJumps` holds for `fileURL`, once the document has rendered.
    func requestedLineJumps(fileURL: URL?, lineCount: Int, jump: @escaping (Int) -> Void) -> some View {
        modifier(RequestedLineJumps(fileURL: fileURL, lineCount: lineCount, jump: jump))
    }
}

private struct RequestedLineJumps: ViewModifier {
    let fileURL: URL?
    let lineCount: Int
    let jump: (Int) -> Void

    private struct Key: Equatable {
        let revision: Int
        let lineCount: Int
        let fileURL: URL?
    }

    func body(content: Content) -> some View {
        content.task(id: Key(revision: DocumentJumps.shared.revision, lineCount: lineCount, fileURL: fileURL)) {
            // The first render sets the real line count. Before it, the count is the default of 1.
            guard lineCount > 1, let line = DocumentJumps.shared.take(for: fileURL) else { return }
            jump(line)
        }
    }
}

extension SplitEditorView {
    /// Scrolls both panes to a heading's source line, expressed as the same source-fraction
    /// `ScrollSync` already shares between the editor and preview -- reusing the identical
    /// `(startLine - 1 + lineOffset) / totalLines` formula `scroll-sync.js` uses for its own
    /// `data-sourcepos` anchors, so a jump lands exactly where scroll-sync would place that line.
    func jumpToHeading(_ heading: Heading) {
        guard let startLine = heading.startLine else { return }
        jumpToLine(startLine + sourceLineOffset)
    }

    /// Scrolls both panes to a 1-based line of the file, front matter included.
    func jumpToLine(_ line: Int) {
        guard sourceLineCount > 0 else { return }
        let fraction = CGFloat(line - 1) / CGFloat(sourceLineCount)
        scrollSync.jumpToSourceFraction(min(1, max(0, fraction)))
    }
}
