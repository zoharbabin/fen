import Foundation

/// What the gate does with a change (issue #140).
public enum WriteDecision: Sendable, Equatable {
    case apply
    case ask(AskReason)
    case blocked

    public enum AskReason: String, Sendable, Equatable {
        case modeIsAsk
        case destructive
        case replacingNotOptedIn
        case paused
        case overCap
    }
}

/// What an override rule matches on. Most specific first in `WritePolicy.precedence`.
public enum WriteRuleKind: String, Codable, Sendable, CaseIterable {
    case client
    case pathGlob
    case documentType
    case operation

    public var title: String {
        switch self {
        case .client: "MCP client"
        case .pathGlob: "Path pattern"
        case .documentType: "Document type"
        case .operation: "Operation"
        }
    }
}

/// The rules for AI writes in one workspace. The default mode lives in `WorkspaceSettings.approvalMode`.
/// Auto-approve never applies until you confirm it once.
public struct WritePolicy: Codable, Sendable, Equatable {
    public struct Override: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var kind: WriteRuleKind
        public var match: String
        public var mode: ApprovalMode
        /// Auto-approve in this rule is ignored until you confirm it.
        public var confirmed: Bool

        public init(
            id: UUID = UUID(),
            kind: WriteRuleKind,
            match: String,
            mode: ApprovalMode,
            confirmed: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.match = match
            self.mode = mode
            self.confirmed = confirmed
        }
    }

    public static let defaultMaxFilesPerRun = 20
    public static let defaultMaxChangedFraction = 0.5
    /// Most specific first.
    static let precedence: [WriteRuleKind] = [.client, .pathGlob, .documentType, .operation]

    public var overrides: [Override]
    /// You confirmed auto-approve for the workspace default.
    public var autoApproveConfirmed: Bool
    /// Operations whose replacing edits may be auto-approved.
    public var autoApproveReplacing: Set<String>
    public var maxFilesPerRun: Int
    /// Most of a document one replacing edit may change before it asks. 0.5 is half.
    public var maxChangedFraction: Double

    public init(
        overrides: [Override] = [],
        autoApproveConfirmed: Bool = false,
        autoApproveReplacing: Set<String> = [],
        maxFilesPerRun: Int = WritePolicy.defaultMaxFilesPerRun,
        maxChangedFraction: Double = WritePolicy.defaultMaxChangedFraction
    ) {
        self.overrides = overrides
        self.autoApproveConfirmed = autoApproveConfirmed
        self.autoApproveReplacing = autoApproveReplacing
        self.maxFilesPerRun = maxFilesPerRun
        self.maxChangedFraction = maxChangedFraction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            overrides: container.decodeIfPresent([Override].self, forKey: .overrides) ?? [],
            autoApproveConfirmed: container.decodeIfPresent(Bool.self, forKey: .autoApproveConfirmed) ?? false,
            autoApproveReplacing: container.decodeIfPresent(Set<String>.self, forKey: .autoApproveReplacing) ?? [],
            maxFilesPerRun: container.decodeIfPresent(Int.self, forKey: .maxFilesPerRun)
                ?? WritePolicy.defaultMaxFilesPerRun,
            maxChangedFraction: container.decodeIfPresent(Double.self, forKey: .maxChangedFraction)
                ?? WritePolicy.defaultMaxChangedFraction
        )
    }

    /// The mode that applies to a change. The most specific kind of rule that matches decides.
    /// Several matches of one kind resolve to the strictest. An unconfirmed auto-approve counts as Ask.
    public func mode(
        workspaceDefault: ApprovalMode,
        operation: String,
        documentType: String?,
        paths: [String],
        client: String?
    ) -> ApprovalMode {
        let globs = overrides.filter { $0.kind == .pathGlob }
        for kind in Self.precedence {
            let matching: [Override] = switch kind {
            case .client: overrides.filter { $0.kind == .client && $0.match == client }
            case .documentType: overrides.filter { $0.kind == .documentType && $0.match == documentType }
            case .operation: overrides.filter { $0.kind == .operation && $0.match == operation }
            case .pathGlob: globs.filter { rule in
                    let set = GlobSet([rule.match])
                    return paths.contains { set.matches($0) }
                }
            }
            if !matching.isEmpty {
                return matching.map { effective($0.mode, confirmed: $0.confirmed) }
                    .max { strictness($0) < strictness($1) }
                    ?? .ask
            }
        }
        return effective(workspaceDefault, confirmed: autoApproveConfirmed)
    }

    private func effective(_ mode: ApprovalMode, confirmed: Bool) -> ApprovalMode {
        mode == .autoApprove && !confirmed ? .ask : mode
    }

    private func strictness(_ mode: ApprovalMode) -> Int {
        switch mode {
        case .autoApprove: 0
        case .ask: 1
        case .off: 2
        }
    }

    /// The one decision.
    public func decide(_ facts: WriteFacts) -> WriteDecision {
        if facts.mode == .off {
            return .blocked
        }
        if facts.tier == .destructive {
            return .ask(.destructive)
        }
        if facts.invokedByUser {
            return .apply
        }
        if facts.mode == .ask {
            return .ask(.modeIsAsk)
        }
        if facts.paused {
            return .ask(.paused)
        }
        if facts.tier == .replacing, !facts.exemptFromReplacingOptIn,
           !autoApproveReplacing.contains(facts.operation) {
            return .ask(.replacingNotOptedIn)
        }
        return facts.overCap ? .ask(.overCap) : .apply
    }
}

/// What `WritePolicy.decide` looks at.
public struct WriteFacts: Sendable, Equatable {
    public var mode: ApprovalMode
    public var tier: EditTier
    public var operation: String
    public var invokedByUser: Bool
    public var paused = false
    public var overCap = false
    /// For schema migrations (#7), which replace text by design.
    public var exemptFromReplacingOptIn = false
}
