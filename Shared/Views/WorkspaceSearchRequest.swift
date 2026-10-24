import Foundation

/// Asks the Workspaces window to search for `query`, such as from the find bar's "other notes match" link.
/// The window takes the query when it sees it.
@MainActor @Observable
public final class WorkspaceSearchRequest {
    public static let shared = WorkspaceSearchRequest()
    public var query: String?
    public init() {}
}
