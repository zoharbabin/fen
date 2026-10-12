@testable import FenCore
import Testing

@Suite("Write policy: a client's change asks unless a rule names that client (issue #10)")
struct MCPWritePolicyTests {
    func mode(_ policy: WritePolicy, workspace: ApprovalMode = .autoApprove, client: String?) -> ApprovalMode {
        policy.mode(
            workspaceDefault: workspace,
            operation: "mcp.append",
            documentType: nil,
            paths: ["a.md"],
            client: client
        )
    }

    @Test("Fen's own features keep the workspace default")
    func ownFeaturesUnchanged() {
        let policy = WritePolicy(autoApproveConfirmed: true)
        #expect(mode(policy, client: nil) == .autoApprove)
    }

    @Test("A client asks even when the workspace default, a path rule or an operation rule auto-approves")
    func clientAsks() {
        var policy = WritePolicy(autoApproveConfirmed: true)
        #expect(mode(policy, client: "Agent") == .ask)
        policy.overrides = [
            .init(kind: .pathGlob, match: "*.md", mode: .autoApprove, confirmed: true),
            .init(kind: .operation, match: "mcp.append", mode: .autoApprove, confirmed: true),
        ]
        #expect(mode(policy, client: "Agent") == .ask)
    }

    @Test("A confirmed rule for that client name auto-approves. An unconfirmed one and another client's do not")
    func clientRule() {
        var policy = WritePolicy()
        policy.overrides = [.init(kind: .client, match: "Agent", mode: .autoApprove, confirmed: true)]
        #expect(mode(policy, workspace: .ask, client: "Agent") == .autoApprove)
        #expect(mode(policy, workspace: .ask, client: "Other") == .ask)
        policy.overrides = [.init(kind: .client, match: "Agent", mode: .autoApprove, confirmed: false)]
        #expect(mode(policy, client: "Agent") == .ask)
    }

    @Test("Off stays off for a client")
    func off() {
        let policy = WritePolicy(overrides: [.init(kind: .client, match: "Agent", mode: .off)])
        #expect(mode(policy, client: "Agent") == .off)
        #expect(mode(WritePolicy(), workspace: .off, client: "Agent") == .off)
    }
}
