import Foundation

/// The one containment check between a path and a granted root (issue #5).
///
/// `PreviewSchemeHandler.resolvedFileURL(for:baseDirectory:)` and every workspace file access
/// call this, so a document's folder and a workspace root share the exact same boundary rule.
///
/// Paths are resolved component by component, like `realpath(3)`, but they don't have to exist:
/// - A symlink anywhere in the path is followed before the comparison, including a dangling one
///   (`URL.resolvingSymlinksInPath()` leaves those alone, so a write through one could escape).
/// - `..` applies to the already-resolved parent, not to the text of the path.
/// - The comparison is by path component, so `/notes-evil` is never inside `/notes`.
public enum PathGate {
    /// `true` when `candidate` is `root` itself or sits below it.
    public static func isContained(_ candidate: URL, in root: URL) -> Bool {
        guard let candidateComponents = canonicalComponents(of: candidate),
              let rootComponents = canonicalComponents(of: root) else { return false }
        return candidateComponents.starts(with: rootComponents)
    }

    /// Resolves a root-relative path to a file URL, or `nil` if it escapes `root`.
    /// Absolute paths, `..` segments, and symlinks that leave the root all fail.
    public static func resolve(relativePath: String, in root: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              let rootComponents = canonicalComponents(of: root),
              let candidate = canonicalComponents(of: root.appendingPathComponent(relativePath)),
              candidate.starts(with: rootComponents) else { return nil }
        return fileURL(from: candidate)
    }

    /// `true` when two folders overlap: they are the same folder, or one contains the other.
    public static func overlaps(_ first: URL, _ second: URL) -> Bool {
        isContained(first, in: second) || isContained(second, in: first)
    }

    /// The fully resolved location of `url`, or `nil` for a symlink loop.
    public static func canonicalURL(of url: URL) -> URL? {
        canonicalComponents(of: url).map(fileURL(from:))
    }

    // MARK: - Resolution

    private static let maxSymlinkDepth = 40

    private static func fileURL(from components: [String]) -> URL {
        URL(fileURLWithPath: "/" + components.joined(separator: "/"))
    }

    private static func canonicalComponents(of url: URL) -> [String]? {
        var pending = pathParts(url.path)
        var resolved: [String] = []
        var followed = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            switch part {
            case ".":
                continue
            case "..":
                _ = resolved.popLast()
            default:
                let probe = "/" + (resolved + [part]).joined(separator: "/")
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: probe) else {
                    resolved.append(part)
                    continue
                }
                followed += 1
                guard followed <= maxSymlinkDepth else { return nil }
                if target.hasPrefix("/") {
                    resolved = []
                }
                pending = pathParts(target) + pending
            }
        }
        return resolved
    }

    private static func pathParts(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
