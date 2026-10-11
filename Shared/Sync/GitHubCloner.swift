import Foundation

/// Clones a GitHub repository into a new folder and adds it as a workspace (issue #60).
/// It is one workspace among any others, and the folder can't overlap another one.
@MainActor
struct GitHubCloner {
    enum CloneError: Error, Equatable, LocalizedError {
        case notEmpty(String)

        var errorDescription: String? {
            switch self {
            case let .notEmpty(name):
                "There is already a folder called “\(name)” with files in it. Pick another place."
            }
        }
    }

    let library: WorkspaceLibrary
    let sync: GitSync

    /// Clones `repo` into `parent/<repo name>`. `token` is checked first and saved to the keychain only
    /// after the clone worked, so a wrong token isn't kept. `remote` replaces the GitHub address in tests.
    func clone(_ repo: GitHubRepo, token: String?, into parent: URL, remote: URL? = nil) async throws -> Workspace {
        let token = try token
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try GitHubToken.validate($0) }
        let target = parent.appendingPathComponent(repo.name, isDirectory: true)
        let existed = FileManager.default.fileExists(atPath: target.path)
        if existed {
            guard (try? FileManager.default.contentsOfDirectory(atPath: target.path))?.isEmpty == true else {
                throw CloneError.notEmpty(repo.name)
            }
        } else {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        }
        do {
            try library.registry.validate(folder: target)
            try await sync.clone(remote ?? repo.cloneURL, into: target, token: token)
            if let token {
                try sync.secrets.write(token, account: repo.tokenAccount)
            }
            return try library.add(folder: target, name: repo.name)
        } catch {
            if !existed {
                try? FileManager.default.removeItem(at: target)
            }
            throw error
        }
    }
}
