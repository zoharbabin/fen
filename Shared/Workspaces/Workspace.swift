import Foundation

/// A folder you granted to Fen (issue #5). Any number of them can exist, and none is "main".
public struct Workspace: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    /// Last known location of the root. The bookmark wins when both resolve.
    public var path: String
    public var settings: WorkspaceSettings
    public let addedAt: Date
    /// Security-scoped bookmark: keeps the grant across launches in a sandbox and on iOS.
    var bookmark: Data?

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        settings: WorkspaceSettings = WorkspaceSettings(),
        addedAt: Date = Date(),
        bookmark: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.settings = settings
        self.addedAt = addedAt
        self.bookmark = bookmark
    }
}

/// Why a folder can't become a workspace. Messages name the workspace in the way.
public enum WorkspaceError: Error, Equatable, LocalizedError {
    case notAFolder
    case homeFolder
    case volumeRoot
    case fenHome
    case sameAsWorkspace(name: String)
    case insideWorkspace(name: String)
    case containsWorkspace(name: String)
    case unknownWorkspace
    case accessLost(name: String)
    case listUnreadable

    public var errorDescription: String? {
        switch self {
        case .notAFolder:
            "Pick a folder."
        case .homeFolder:
            "Your home folder is too broad to be a workspace. Pick a folder inside it."
        case .volumeRoot:
            "A whole disk is too broad to be a workspace. Pick a folder on it."
        case .fenHome:
            "This folder holds Fen's own data and can't be a workspace."
        case let .sameAsWorkspace(name):
            "This folder is already the workspace “\(name)”."
        case let .insideWorkspace(name):
            "This folder is inside the workspace “\(name)”. Remove that workspace first, or use it as is."
        case let .containsWorkspace(name):
            "This folder contains the workspace “\(name)”. Remove that workspace first."
        case .unknownWorkspace:
            "That workspace no longer exists."
        case let .accessLost(name):
            "Fen can no longer reach the folder for “\(name)”. Remove the workspace and add the folder again."
        case .listUnreadable:
            "Fen couldn't read your saved workspace list, so it won't change it. "
                + "Fix or move ~/.fen/workspaces.json, then reopen Fen."
        }
    }
}
