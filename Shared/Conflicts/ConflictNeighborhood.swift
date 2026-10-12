import Foundation

/// Picks the notes to compare a changed note against (issue #94). Not the whole workspace: the
/// notes it links to or from, the notes the index finds close in meaning, and its folder mates.
enum ConflictNeighborhood {
    /// Up to `limit` paths without `path` itself or repeats. Links come first, then meaning, then folder.
    static func order(
        of path: String,
        linked: [String],
        similar: [String],
        folder: [String],
        limit: Int
    ) -> [String] {
        var seen: Set<String> = [path]
        var result: [String] = []
        for candidate in linked + similar + folder where result.count < limit {
            if seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    /// Notes in the same folder as `path`, nearest name first. A note at the top level has none, so
    /// the whole workspace's root files are not all pulled in.
    static func folderMates(of path: String, in paths: [String]) -> [String] {
        let folder = (path as NSString).deletingLastPathComponent
        guard !folder.isEmpty else { return [] }
        return paths.filter { $0 != path && ($0 as NSString).deletingLastPathComponent == folder }.sorted()
    }
}
