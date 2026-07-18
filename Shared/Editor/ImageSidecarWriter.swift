import Foundation
import UniformTypeIdentifiers

/// Writes pasted/dropped image data into a document's sidecar assets folder (issue #18) and
/// reports the relative path a Markdown link should use. Takes only raw `Data` + `UTType`, not
/// a live pasteboard/drag type, so it's identical on both platforms -- each platform's paste/drop
/// glue extracts the bytes and content type from its own pasteboard API, then calls this.
enum ImageSidecarWriter {
    /// `<document-basename>.assets`, sibling to the document itself -- namespaced per document
    /// so multiple documents sharing a folder never collide, and visible (not dot-prefixed) so
    /// it shows up in Finder/enumeration like `.xcassets`/`.bundle`.
    static func sidecarDirectoryName(documentBaseName: String) -> String {
        "\(documentBaseName).assets"
    }

    /// Writes `data` into `documentURL`'s sidecar assets folder and returns the relative path
    /// (e.g. `"notes.assets/image-1.png"`) to use in a Markdown link. Returns `nil` -- and writes
    /// nothing -- if `contentType` isn't an image, the resolved destination would escape the
    /// document's own directory (mirroring `PreviewSchemeHandler.resolvedFileURL`'s symlink guard
    /// in the write direction), or directory creation/writing fails for any reason (permissions,
    /// full disk). Callers must treat `nil` as "decline this paste/drop", not retry.
    static func write(data: Data, contentType: UTType, documentURL: URL) -> String? {
        guard contentType.conforms(to: .image),
              let fileExtension = contentType.preferredFilenameExtension else { return nil }

        let documentDirectory = documentURL.deletingLastPathComponent()
        let resolvedDocumentDirectory = documentDirectory.resolvingSymlinksInPath()
        let baseName = documentURL.deletingPathExtension().lastPathComponent
        let directoryName = sidecarDirectoryName(documentBaseName: baseName)
        let sidecarDirectory = documentDirectory.appendingPathComponent(directoryName, isDirectory: true)

        guard (try? FileManager.default.createDirectory(
            at: sidecarDirectory, withIntermediateDirectories: true
        )) != nil else { return nil }

        // Resolve the sidecar directory itself, not the not-yet-written file inside it --
        // resolvingSymlinksInPath() on a path whose leaf doesn't exist can't call through
        // realpath(3), and silently falls back to returning the unresolved path, which would
        // make this guard a no-op against a symlinked sidecar directory (issue #18 rule 2.2).
        let resolvedSidecarDirectory = sidecarDirectory.resolvingSymlinksInPath()
        guard resolvedSidecarDirectory.path.hasPrefix(resolvedDocumentDirectory.path) else { return nil }

        guard let filename = nextAvailableFilename(in: resolvedSidecarDirectory, extension: fileExtension) else {
            return nil
        }
        let fileURL = resolvedSidecarDirectory.appendingPathComponent(filename)

        guard (try? data.write(to: fileURL, options: .withoutOverwriting)) != nil else { return nil }

        return "\(directoryName)/\(filename)"
    }

    /// The first `image-N.<extension>` (1-based) not already present in `directory`. Always
    /// re-derived from the real filesystem on every call -- no cached counter -- so concurrent
    /// writes from independent instances never share or skip numbers (issue #18 rule 1.1).
    /// Bounded so a pathological directory can't spin this forever (issue #18 rule 4.1).
    private static func nextAvailableFilename(in directory: URL, extension fileExtension: String) -> String? {
        let fileManager = FileManager.default
        for index in 1 ... 10000 {
            let candidate = "image-\(index).\(fileExtension)"
            if !fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        return nil
    }
}
