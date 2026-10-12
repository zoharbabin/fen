import Foundation

/// One row of the folder tree shown for a workspace.
public struct FileTreeNode: Identifiable, Hashable, Sendable {
    /// Path below the workspace root. Unique per node.
    public let id: String
    public let name: String
    /// `nil` for a file. A folder has at least one child.
    public var children: [FileTreeNode]?
    public let file: WorkspaceFile?

    public var isFolder: Bool {
        children != nil
    }
}

public enum WorkspaceFileTree {
    /// Folders first, then files, each in Finder order.
    public static func build(from files: [WorkspaceFile]) -> [FileTreeNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [WorkspaceFile] = []
        }
        let root = Folder()
        for file in files {
            var folder = root
            for part in file.relativePath.split(separator: "/").dropLast().map(String.init) {
                if let next = folder.folders[part] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.append(file)
        }
        func nodes(_ folder: Folder, path: String) -> [FileTreeNode] {
            let subfolders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { name in
                    let childPath = path.isEmpty ? name : path + "/" + name
                    return FileTreeNode(
                        id: childPath,
                        name: name,
                        children: nodes(folder.folders[name]!, path: childPath),
                        file: nil
                    )
                }
            let leaves = folder.files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map {
                FileTreeNode(id: $0.relativePath, name: $0.name, children: nil, file: $0)
            }
            return subfolders + leaves
        }
        return nodes(root, path: "")
    }
}
