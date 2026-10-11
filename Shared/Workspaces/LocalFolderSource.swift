import Foundation

public enum WorkspaceFileError: Error, Equatable {
    case excluded(ExclusionReason)
}

/// A workspace backed by a folder on disk (issue #5). Read-only: it lists and reads files, and
/// writes nothing. In a git work tree it honors `.gitignore` and skips `.git`.
public struct LocalFolderSource: WorkspaceSource {
    public let rootURL: URL

    private let settings: WorkspaceSettings
    private let include: GlobSet
    private let exclude: GlobSet
    private let repository: GitRepository?
    private let baseIgnore: GitIgnoreStack
    /// Where `rootURL` sits below the git work tree. Empty when the root is the work tree.
    private let rootPrefix: String
    private static let schemaPath = ".fen/schema.yaml"

    public init(root: URL, settings: WorkspaceSettings) {
        rootURL = PathGate.canonicalURL(of: root) ?? root
        self.settings = settings
        include = GlobSet(settings.includeGlobs)
        exclude = GlobSet(settings.excludeGlobs)
        repository = GitRepository.detect(from: rootURL)
        baseIgnore = repository?.ignoreStack(forRoot: rootURL) ?? GitIgnoreStack()
        rootPrefix = repository?.relativeParts(of: rootURL)?.joined(separator: "/") ?? ""
    }

    // MARK: - Scan

    public func scan(progress: @Sendable (Int) -> Void) async throws -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot()
        try await walk(directory: rootURL, relativePath: "", stack: baseIgnore, into: &snapshot, progress: progress)
        if case let .success(schema) = evaluate(relativePath: Self.schemaPath) {
            snapshot.files[schema.relativePath] = schema
        }
        snapshot.git = gitState(for: snapshot)
        progress(snapshot.files.count)
        return snapshot
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]

    private func walk(
        directory: URL,
        relativePath: String,
        stack: GitIgnoreStack,
        into snapshot: inout WorkspaceSnapshot,
        progress: @Sendable (Int) -> Void
    ) async throws {
        var work = [(directory, relativePath, stack)]
        while let (directory, relativePath, stack) = work.popLast() {
            try Task.checkCancellation()
            await Task.yield()
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Self.resourceKeys
            )) ?? []
            for entry in entries {
                let name = entry.lastPathComponent
                if name.hasPrefix(".") {
                    continue
                }
                let childPath = relativePath.isEmpty ? name : relativePath + "/" + name
                let values = try? entry.resourceValues(forKeys: Set(Self.resourceKeys))
                if values?.isSymbolicLink == true {
                    // Symlinks to folders are not followed. Symlinks to files are judged by their target.
                    if case let .success(file) = evaluate(relativePath: childPath) {
                        snapshot.files[childPath] = file
                    }
                } else if values?.isDirectory == true {
                    guard !stack.isIgnored(gitPath(childPath), isDirectory: true), !exclude.matches(childPath) else {
                        continue
                    }
                    let next = repository == nil ? stack : stack.addingIgnoreFile(in: entry, base: gitPath(childPath))
                    work.append((entry, childPath, next))
                } else if case let .success(file) = evaluateFile(
                    at: entry,
                    relativePath: childPath,
                    size: values?.fileSize,
                    modified: values?.contentModificationDate,
                    stack: stack
                ) {
                    snapshot.files[childPath] = file
                    if snapshot.files.count.isMultiple(of: 200) {
                        progress(snapshot.files.count)
                    }
                }
            }
        }
    }

    // MARK: - Update

    public func update(_ snapshot: WorkspaceSnapshot, changedPaths paths: [String]) async throws -> WorkspaceSnapshot {
        let relative = Set(paths)
        // A changed ignore file can re-include or hide any file, so list again.
        if relative
            .contains(where: { ($0 as NSString).lastPathComponent == ".gitignore" || $0 == ".git/info/exclude" }) {
            return try await scan { _ in }
        }
        var result = snapshot
        for path in relative.sorted() where path != ".git" && !path.hasPrefix(".git/") {
            try Task.checkCancellation()
            let location = rootURL.appendingPathComponent(path)
            // lstat: a symlink is judged as a file, never followed as a folder.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: location.path) else {
                result.removeAll(under: path)
                continue
            }
            let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
            if isDirectory {
                result.removeAll(under: path)
                if let stack = stack(forDirectory: path) {
                    try await walk(directory: location, relativePath: path, stack: stack, into: &result) { _ in }
                }
            } else {
                switch evaluate(relativePath: path) {
                case let .success(file): result.files[path] = file
                case .failure: result.files[path] = nil
                }
            }
        }
        result.git = gitState(for: result)
        return result
    }

    // MARK: - Git

    public func gitState(for snapshot: WorkspaceSnapshot) -> GitRepositoryState? {
        guard let repository, let branch = repository.branch() else { return nil }
        return GitRepositoryState(
            branch: branch.name,
            isDetached: branch.isDetached,
            isDirty: repository.isDirty(root: rootURL, eligible: Array(snapshot.files.keys))
        )
    }

    private func gitPath(_ relativePath: String) -> String {
        rootPrefix.isEmpty ? relativePath : rootPrefix + "/" + relativePath
    }

    // MARK: - Access

    public func fileURL(forRelativePath path: String) -> URL? {
        PathGate.resolve(relativePath: path, in: rootURL)
    }

    public func read(relativePath path: String) throws -> Data {
        switch evaluate(relativePath: path) {
        case let .failure(reason): throw WorkspaceFileError.excluded(reason)
        case .success: return try Data(contentsOf: rootURL.appendingPathComponent(path))
        }
    }

    public func exclusionReason(forRelativePath path: String) -> ExclusionReason? {
        if case let .failure(reason) = evaluate(relativePath: path) {
            return reason
        }
        return nil
    }

    // MARK: - Eligibility

    /// The ignore rules in force inside `directory`, or `nil` if the folder itself is out.
    private func stack(forDirectory directory: String) -> GitIgnoreStack? {
        var stack = baseIgnore
        var path = ""
        for part in directory.split(separator: "/").map(String.init) {
            path = path.isEmpty ? part : path + "/" + part
            if part.hasPrefix(".") || stack.isIgnored(gitPath(path), isDirectory: true) || exclude.matches(path) {
                return nil
            }
            if repository != nil {
                stack = stack.addingIgnoreFile(in: rootURL.appendingPathComponent(path), base: gitPath(path))
            }
        }
        return stack
    }

    /// Judges one path, including the folders above it.
    private func evaluate(relativePath: String) -> Result<WorkspaceFile, ExclusionReason> {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard !relativePath.hasPrefix("/"), !parts.isEmpty, !parts.contains("..") else { return .failure(.outsideRoot) }
        guard let resolved = fileURL(forRelativePath: relativePath) else { return .failure(.symlinkOutsideRoot) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .failure(.notAFile)
        }
        let values = try? resolved.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if relativePath == Self.schemaPath {
            return .success(WorkspaceFile(
                relativePath: relativePath,
                size: values?.fileSize ?? 0,
                modified: values?.contentModificationDate ?? .distantPast,
                isSchema: true
            ))
        }
        if parts.contains(where: { $0.hasPrefix(".") }) {
            return .failure(.hidden)
        }
        guard let stack = stack(forDirectory: parts.dropLast().joined(separator: "/")) else {
            return .failure(parts.dropLast().isEmpty ? .hidden : .gitignored)
        }
        return evaluateFile(
            at: resolved,
            relativePath: relativePath,
            size: values?.fileSize,
            modified: values?.contentModificationDate,
            stack: stack
        )
    }

    private func evaluateFile(
        at url: URL,
        relativePath: String,
        size: Int?,
        modified: Date?,
        stack: GitIgnoreStack
    ) -> Result<WorkspaceFile, ExclusionReason> {
        let name = (relativePath as NSString).lastPathComponent
        if FileEligibility.looksSecret(fileName: name) {
            return .failure(.secretLooking)
        }
        if stack.isIgnored(gitPath(relativePath), isDirectory: false) {
            return .failure(.gitignored)
        }
        if exclude.matches(relativePath) {
            return .failure(.excludedByGlob)
        }
        if !include.isEmpty, !include.matches(relativePath) {
            return .failure(.notIncluded)
        }
        let bytes = size ?? 0
        if bytes > settings.maxFileBytes {
            return .failure(.tooLarge)
        }
        if FileEligibility.looksBinary(at: url) {
            return .failure(.binary)
        }
        return .success(WorkspaceFile(relativePath: relativePath, size: bytes, modified: modified ?? .distantPast))
    }
}
