import Foundation

/// Which models may receive a workspace's content (issues #4, #5). Embeddings are always local
/// and don't depend on this setting.
public enum AIDataAccess: String, Codable, Sendable, CaseIterable {
    case none
    case localProvidersOnly
    case anyConfiguredProvider

    public var title: String {
        switch self {
        case .none: "None"
        case .localProvidersOnly: "Local providers only"
        case .anyConfiguredProvider: "Any configured provider"
        }
    }
}

/// Where an AI request would send content. The provider layer (#4) classifies its endpoint.
public enum ModelDestination: Sendable {
    /// The in-process model or a loopback endpoint.
    case local
    /// A remote or LAN endpoint.
    case remote
}

/// How AI changes in a workspace are applied (issue #140).
public enum ApprovalMode: String, Codable, Sendable, CaseIterable {
    case ask
    case autoApprove
    /// The operation never runs.
    case off

    public var title: String {
        switch self {
        case .ask: "Ask"
        case .autoApprove: "Auto-approve"
        case .off: "Off"
        }
    }
}

/// Whether agents and other tools may reach a workspace over MCP (issue #10).
public enum MCPAccess: String, Codable, Sendable, CaseIterable {
    case disabled
    case enabled

    public var title: String {
        switch self {
        case .disabled: "Off"
        case .enabled: "On"
        }
    }
}

/// How a connected remote receives changes (issue #61).
public enum SyncMode: String, Codable, Sendable, CaseIterable {
    case directCommit
    case pushAsPR
}

/// Per-workspace settings. Defaults are the safest useful values: Local providers only, Ask, and
/// MCP access Off.
public struct WorkspaceSettings: Codable, Sendable, Equatable {
    public static let defaultIncludeGlobs = ["**/*.md", "**/*.markdown", "**/*.mdx", "**/*.txt"]
    /// Files above this size are skipped.
    public static let defaultMaxFileBytes = 2_000_000

    public var aiDataAccess: AIDataAccess
    public var approvalMode: ApprovalMode
    public var mcpAccess: MCPAccess
    /// Set when you connect a remote (#61). `nil` until then.
    public var syncMode: SyncMode?
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var maxFileBytes: Int

    public init(
        aiDataAccess: AIDataAccess = .localProvidersOnly,
        approvalMode: ApprovalMode = .ask,
        mcpAccess: MCPAccess = .disabled,
        syncMode: SyncMode? = nil,
        includeGlobs: [String] = WorkspaceSettings.defaultIncludeGlobs,
        excludeGlobs: [String] = [],
        maxFileBytes: Int = WorkspaceSettings.defaultMaxFileBytes
    ) {
        self.aiDataAccess = aiDataAccess
        self.approvalMode = approvalMode
        self.mcpAccess = mcpAccess
        self.syncMode = syncMode
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.maxFileBytes = maxFileBytes
    }

    /// Missing keys fall back to defaults, so a registry written by an older Fen still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            aiDataAccess: container.decodeIfPresent(AIDataAccess.self, forKey: .aiDataAccess) ?? .localProvidersOnly,
            approvalMode: container.decodeIfPresent(ApprovalMode.self, forKey: .approvalMode) ?? .ask,
            mcpAccess: container.decodeIfPresent(MCPAccess.self, forKey: .mcpAccess) ?? .disabled,
            syncMode: container.decodeIfPresent(SyncMode.self, forKey: .syncMode),
            includeGlobs: container.decodeIfPresent([String].self, forKey: .includeGlobs)
                ?? WorkspaceSettings.defaultIncludeGlobs,
            excludeGlobs: container.decodeIfPresent([String].self, forKey: .excludeGlobs) ?? [],
            maxFileBytes: container.decodeIfPresent(Int.self, forKey: .maxFileBytes)
                ?? WorkspaceSettings.defaultMaxFileBytes
        )
    }

    /// MCP access is unavailable when AI data access is None.
    public var effectiveMCPAccess: MCPAccess {
        aiDataAccess == .none ? .disabled : mcpAccess
    }

    /// Whether content may go to a model at `destination`. The one place this rule lives.
    public func allowsModel(at destination: ModelDestination) -> Bool {
        switch (aiDataAccess, destination) {
        case (.none, _): false
        case (.localProvidersOnly, .remote): false
        case (.localProvidersOnly, .local), (.anyConfiguredProvider, _): true
        }
    }
}
