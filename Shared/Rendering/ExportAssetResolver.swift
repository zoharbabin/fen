import Foundation
import UniformTypeIdentifiers

/// How `ExportAssetResolver` should treat relative image references found in exported HTML.
public enum ExportAssetMode: Sendable {
    /// Read each referenced image and rewrite its `src` to a base64 `data:` URI.
    case selfContained
    /// Rewrite each referenced image's `src` to `<exportBaseName>.assets/<leaf>` and report the
    /// source file so the caller can copy or embed it -- `resolve` never writes to disk itself,
    /// since where (or whether) that write happens differs by platform (macOS copies to a
    /// destination directory chosen via `NSSavePanel`; iOS reads the source data directly into
    /// an in-memory `FileWrapper` for `.fileExporter`, with no destination directory known yet).
    case linkedAssets(exportBaseName: String)
}

/// One image reference rewritten in `linkedAssets` mode: the new relative path written into the
/// HTML, and the original file it should be copied or read from.
public struct ExportResolvedAsset: Sendable, Equatable {
    public let relativePath: String
    public let sourceFileURL: URL
}

/// Rewrites relative `<img src="...">` references in composed export HTML -- either inlining
/// them as `data:` URIs or reporting them for the caller to copy/embed -- issue #31. Holds no
/// stored state: every call is a pure function of its arguments (self-contained mode reads
/// source image bytes but writes nothing), so concurrent exports of different documents never
/// interact.
public struct ExportAssetResolver: Sendable {
    /// Largest single image `ExportAssetResolver` will read into memory to inline, in bytes.
    /// An image over this size is left un-rewritten (its original relative `src` kept) rather
    /// than risk holding an unbounded amount of image data in memory during export.
    public static let maxInlineImageBytes = 10 * 1024 * 1024

    /// Largest number of distinct image references a single export will resolve. Mirrors
    /// `ImageSidecarWriter.nextAvailableFilename`'s `1...10000` bound: a defensive cap against a
    /// pathological document, not a limit any real document is expected to reach.
    public static let maxImageReferences = 10000

    /// Matches `<img ... src="...">` / `<img ... src='...'>`, capturing the quote character and
    /// the src value so `resolve` can rewrite only that attribute and leave the rest of the tag
    /// untouched. Non-greedy on the src value so it stops at the closing quote rather than
    /// spanning into a later attribute.
    private static let imgSrcRegex = try? NSRegularExpression(
        pattern: #"<img\b[^>]*?\ssrc=("|')((?:(?!\1).)*)\1"#, options: [.caseInsensitive]
    )

    public init() {}

    /// Rewrites every relative, local `<img src="...">` reference in `html` per `mode`.
    /// `documentDirectory` is the directory of the document being exported, used to resolve each
    /// relative `src` and to guard against traversal outside it. References that are already
    /// absolute URIs (`data:`, `http:`, `https:`, or any other URL scheme) are left unchanged in
    /// both modes -- HTML export never fetches a remote resource (rule 2.3).
    ///
    /// Returns the rewritten HTML. In `linkedAssets` mode, also returns one `ExportResolvedAsset`
    /// per rewritten reference for the caller to copy or embed; in `selfContained` mode this is
    /// always empty, since inlining happens entirely inside this call.
    public func resolve(
        html: String,
        documentDirectory: URL,
        mode: ExportAssetMode
    ) -> (html: String, assets: [ExportResolvedAsset]) {
        guard let regex = Self.imgSrcRegex else { return (html, []) }

        let resolvedDocumentDirectory = documentDirectory.resolvingSymlinksInPath()
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        var result = ""
        var assets: [ExportResolvedAsset] = []
        var usedLeafNames = Set<String>()
        var lastEnd = 0
        var resolvedCount = 0

        for match in matches {
            let fullRange = match.range(at: 0)
            let srcRange = match.range(at: 2)
            result += nsHTML.substring(with: NSRange(location: lastEnd, length: fullRange.location - lastEnd))

            let originalSrc = nsHTML.substring(with: srcRange)
            guard resolvedCount < Self.maxImageReferences,
                  let rewritten = rewrittenSrc(
                      originalSrc: originalSrc,
                      documentDirectory: resolvedDocumentDirectory,
                      mode: mode,
                      usedLeafNames: &usedLeafNames,
                      assets: &assets
                  ) else {
                result += nsHTML.substring(with: fullRange)
                lastEnd = fullRange.location + fullRange.length
                continue
            }
            resolvedCount += 1

            let tag = nsHTML.substring(with: fullRange) as NSString
            let rewrittenTag = tag.replacingCharacters(in: srcRange.shifted(by: -fullRange.location), with: rewritten)
            result += rewrittenTag
            lastEnd = fullRange.location + fullRange.length
        }
        result += nsHTML.substring(with: NSRange(location: lastEnd, length: nsHTML.length - lastEnd))

        return (result, assets)
    }

    /// Returns the rewritten `src` value for one image reference, or `nil` if it should be left
    /// unchanged (remote URL, already a `data:` URI, resolves outside the document's directory,
    /// too large to inline, or unreadable).
    private func rewrittenSrc(
        originalSrc: String,
        documentDirectory: URL,
        mode: ExportAssetMode,
        usedLeafNames: inout Set<String>,
        assets: inout [ExportResolvedAsset]
    ) -> String? {
        guard isLocalRelativeReference(originalSrc) else { return nil }

        guard let sourceFileURL = resolvedLocalFileURL(relativePath: originalSrc, documentDirectory: documentDirectory)
        else { return nil }

        switch mode {
        case .selfContained:
            return dataURI(for: sourceFileURL)
        case let .linkedAssets(exportBaseName):
            let directoryName = "\(exportBaseName).assets"
            let leaf = uniqueLeafName(for: sourceFileURL.lastPathComponent, in: &usedLeafNames)
            let relativePath = "\(directoryName)/\(leaf)"
            assets.append(ExportResolvedAsset(relativePath: relativePath, sourceFileURL: sourceFileURL))
            return relativePath
        }
    }

    /// A reference is "local relative" if it isn't an absolute URI with its own scheme --
    /// `data:`, `http:`, `https:`, or anything else with a `scheme:` prefix stays untouched, and
    /// an absolute filesystem path (`/...`) is also left alone since it isn't relative to the
    /// document.
    private func isLocalRelativeReference(_ src: String) -> Bool {
        guard !src.hasPrefix("/") else { return false }
        guard let colonIndex = src.firstIndex(of: ":") else { return true }
        let scheme = src[src.startIndex ..< colonIndex]
        return scheme.contains("/") // e.g. "notes.assets/foo:bar.png" has no real scheme
    }

    /// Resolves `relativePath` against `documentDirectory`, applying the same symlink-resolve +
    /// directory-prefix traversal guard as `PreviewSchemeHandler.resolvedFileURL` and
    /// `ImageSidecarWriter.write` (rule 2.2) -- a path that escapes the document's own directory
    /// is rejected, never read.
    private func resolvedLocalFileURL(relativePath: String, documentDirectory: URL) -> URL? {
        guard let candidate = URL(string: relativePath, relativeTo: documentDirectory) else { return nil }
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(documentDirectory.path),
              FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    /// Reads `fileURL` and returns a `data:` URI, or `nil` if it's missing, unreadable, over
    /// `maxInlineImageBytes`, or not an image content type.
    private func dataURI(for fileURL: URL) -> String? {
        guard let contentType = UTType(filenameExtension: fileURL.pathExtension),
              contentType.conforms(to: .image),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? Int,
              fileSize <= Self.maxInlineImageBytes,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        let mimeType = contentType.preferredMIMEType ?? "application/octet-stream"
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    /// Returns a leaf name unique within this export call, adding a numeric suffix if `leaf` was
    /// already used by an earlier reference (e.g. two different relative paths that happen to
    /// share a filename).
    private func uniqueLeafName(for leaf: String, in usedLeafNames: inout Set<String>) -> String {
        guard usedLeafNames.contains(leaf) else {
            usedLeafNames.insert(leaf)
            return leaf
        }
        let baseName = (leaf as NSString).deletingPathExtension
        let fileExtension = (leaf as NSString).pathExtension
        for suffix in 1 ... Self.maxImageReferences {
            let candidate = fileExtension.isEmpty ? "\(baseName)-\(suffix)" : "\(baseName)-\(suffix).\(fileExtension)"
            if !usedLeafNames.contains(candidate) {
                usedLeafNames.insert(candidate)
                return candidate
            }
        }
        return leaf
    }
}

private extension NSRange {
    func shifted(by offset: Int) -> NSRange {
        NSRange(location: location + offset, length: length)
    }
}
