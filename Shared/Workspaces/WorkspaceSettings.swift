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

    /// Plain words first. Git words in the second line of the menu.
    public var title: String {
        switch self {
        case .directCommit: "Back up to GitHub"
        case .pushAsPR: "Review with pull requests"
        }
    }
}

/// How often Fen enriches the files that changed in a workspace while it runs (issue #6).
public enum EnrichSchedule: String, Codable, CaseIterable, Sendable {
    case off
    case daily
    case weekly

    public var title: String {
        switch self {
        case .off: "Off"
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }

    /// Time between runs. `nil` when off.
    public var interval: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }
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
    /// Overrides, opt-ins and caps for AI writes (issue #140). `approvalMode` is the default.
    public var writePolicy: WritePolicy
    /// Where an MCP client's changes land in a git workspace (#93).
    public var agentBranches: AgentBranchMode
    /// Set when you connect a remote (#61). `nil` until then.
    public var syncMode: SyncMode?
    /// Direct-commit only: back up notes with AI changes along with the rest (#61). Off by default,
    /// so an AI change never reaches GitHub before you have looked at it.
    public var pushesAIChanges: Bool
    /// Fen made this folder with Clone from GitHub (#60), so its git settings are Fen's own. Sync
    /// checks the settings of any other folder before it runs git there with your token.
    public var clonedByFen: Bool
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var maxFileBytes: Int
    /// Saving a document here enriches its short bullets, under `approvalMode` (issue #6). Off by default.
    public var enrichOnSave: Bool
    /// Enriches the files that changed since the last run, while Fen is running (issue #6). Off by default.
    public var enrichSchedule: EnrichSchedule

    public init(
        aiDataAccess: AIDataAccess = .localProvidersOnly,
        approvalMode: ApprovalMode = .ask,
        mcpAccess: MCPAccess = .disabled,
        writePolicy: WritePolicy = WritePolicy(),
        agentBranches: AgentBranchMode = .perAgent,
        syncMode: SyncMode? = nil,
        pushesAIChanges: Bool = false,
        clonedByFen: Bool = false,
        includeGlobs: [String] = WorkspaceSettings.defaultIncludeGlobs,
        excludeGlobs: [String] = [],
        maxFileBytes: Int = WorkspaceSettings.defaultMaxFileBytes,
        enrichOnSave: Bool = false,
        enrichSchedule: EnrichSchedule = .off
    ) {
        self.aiDataAccess = aiDataAccess
        self.approvalMode = approvalMode
        self.mcpAccess = mcpAccess
        self.writePolicy = writePolicy
        self.agentBranches = agentBranches
        self.syncMode = syncMode
        self.pushesAIChanges = pushesAIChanges
        self.clonedByFen = clonedByFen
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.maxFileBytes = maxFileBytes
        self.enrichOnSave = enrichOnSave
        self.enrichSchedule = enrichSchedule
    }

    /// Missing keys fall back to defaults, so a registry written by an older Fen still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            aiDataAccess: container.decodeIfPresent(AIDataAccess.self, forKey: .aiDataAccess) ?? .localProvidersOnly,
            approvalMode: container.decodeIfPresent(ApprovalMode.self, forKey: .approvalMode) ?? .ask,
            mcpAccess: container.decodeIfPresent(MCPAccess.self, forKey: .mcpAccess) ?? .disabled,
            writePolicy: container.decodeIfPresent(WritePolicy.self, forKey: .writePolicy) ?? WritePolicy(),
            agentBranches: container.decodeIfPresent(AgentBranchMode.self, forKey: .agentBranches) ?? .perAgent,
            syncMode: container.decodeIfPresent(SyncMode.self, forKey: .syncMode),
            pushesAIChanges: container.decodeIfPresent(Bool.self, forKey: .pushesAIChanges) ?? false,
            clonedByFen: container.decodeIfPresent(Bool.self, forKey: .clonedByFen) ?? false,
            includeGlobs: container.decodeIfPresent([String].self, forKey: .includeGlobs)
                ?? WorkspaceSettings.defaultIncludeGlobs,
            excludeGlobs: container.decodeIfPresent([String].self, forKey: .excludeGlobs) ?? [],
            maxFileBytes: container.decodeIfPresent(Int.self, forKey: .maxFileBytes)
                ?? WorkspaceSettings.defaultMaxFileBytes,
            enrichOnSave: container.decodeIfPresent(Bool.self, forKey: .enrichOnSave) ?? false,
            enrichSchedule: container.decodeIfPresent(EnrichSchedule.self, forKey: .enrichSchedule) ?? .off
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
