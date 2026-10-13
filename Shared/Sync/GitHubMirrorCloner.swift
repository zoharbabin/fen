import Foundation

/// Copies a GitHub repository into a new folder and adds it as a workspace, where git can't run (issue #60).
/// The folder holds only the repository's files. The sync state lives in `FenHome`.
@MainActor
struct GitHubMirrorCloner {
    let library: WorkspaceLibrary
    var mirror = GitHubMirror()

    /// Copies `repo` into `parent/<repo name>`. `token` is checked first and saved to the keychain only
    /// after the copy worked, so a wrong token isn't kept.
    func clone(_ repo: GitHubRepo, token: String?, into parent: URL) async throws -> Workspace {
        let token = try token
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try GitHubToken.validate($0) }
        let target = parent.appendingPathComponent(repo.name, isDirectory: true)
        let existed = FileManager.default.fileExists(atPath: target.path)
        if existed {
            guard (try? FileManager.default.contentsOfDirectory(atPath: target.path))?.isEmpty == true else {
                throw GitHubCloner.CloneError.notEmpty(repo.name)
            }
        } else {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        }
        var workspaceID: UUID?
        do {
            try library.registry.validate(folder: target)
            let state = try await mirror.download(repo, token: token, into: target)
            let workspace = try library.add(folder: target, name: repo.name)
            workspaceID = workspace.id
            try mirror.save(state, id: workspace.id)
            if let token {
                try mirror.secrets.write(token, account: repo.tokenAccount)
            }
            return workspace
        } catch {
            if let workspaceID {
                try? library.remove(id: workspaceID)
            }
            if !existed {
                try? FileManager.default.removeItem(at: target)
            }
            throw error
        }
    }
}
