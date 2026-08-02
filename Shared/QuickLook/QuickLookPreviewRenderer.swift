import Foundation

/// Renders a `.md` file for Quick Look's preview panel (issue #49), reusing
/// `DocumentHTMLExporter`'s existing pipeline exactly as `ExportCLIRunner` already does from
/// outside the main `DocumentGroup` app (rule 5.1) -- `FenQuickLook/PreviewViewController.swift`
/// is thin `QLPreviewingController` glue that calls this and loads the result into a `WKWebView`.
/// Holds no stored state: every call is a pure function of its arguments and the filesystem at
/// call time, so two concurrent renders in one process never share or leak state (rule 1.1).
public struct QuickLookPreviewRenderer: Sendable {
    public enum RenderError: Error, Equatable {
        case fileTooLarge(byteCount: Int)
        case unreadable
    }

    /// Above this, Finder's preview panel would otherwise wait on rendering a document no one
    /// can usefully skim in a Quick Look popup anyway -- surfacing QuickLook's own "preview
    /// unavailable" fallback here is a better experience than a multi-second hang on a
    /// pathological input (rule 4.1).
    public static let maxPreviewableFileBytes = 5 * 1024 * 1024

    public init() {}

    /// Renders `fileURL`'s Markdown to a self-contained HTML string (images inlined as `data:`
    /// URIs via `ExportAssetResolver`, so the extension never needs its own `WKURLSchemeHandler`
    /// or base-URL file access -- the traversal guard `ExportAssetResolverSecurityTests` already
    /// proves is the only filesystem gate this path exercises). `preferences` defaults to a fresh
    /// instance per call, matching `ExportCLIRunner.run`'s precedent for callers outside the main
    /// app's `DocumentGroup` (issue #34) -- the extension constructs its own rather than reaching
    /// for `Preferences.shared` across a process boundary, where that singleton wouldn't apply
    /// anyway.
    @MainActor
    public func render(fileURL: URL, preferences: Preferences = Preferences()) async throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? Int) ?? 0
        guard byteCount <= Self.maxPreviewableFileBytes else {
            throw RenderError.fileTooLarge(byteCount: byteCount)
        }
        guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw RenderError.unreadable
        }
        let exported = await DocumentHTMLExporter().export(
            markdown: markdown, documentURL: fileURL, preferences: preferences, mode: .selfContained
        )
        return exported.html
    }
}
