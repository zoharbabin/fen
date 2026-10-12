import Foundation

/// The agent-branch path through the gate (issue #93). An MCP client's change in a git workspace
/// is committed to that client's own `fen/<client>` branch instead of your files. Every other
/// change, and every file git doesn't track, takes the ordinary path.
///
/// The checks are the same as for a write in place: scope, path rules, compare-and-swap, policy,
/// pre-image, activity log. Only the last step differs: a commit instead of a file write.
extension WriteGate {
    /// What an agent should read for a file: the branch's view, or `nil` when the file isn't on a
    /// branch and the caller reads it from the workspace.
    public struct AgentRead: Sendable, Equatable {
        public var data: Data
        public var branch: String
    }

    /// A change routed to a branch, with the state it was planned from.
    private struct Route {
        var branch: AgentBranch
        var tip: String?
        var mode: String?
        var prefetched: Prefetched
    }

    // MARK: - Reading

    public func agentRead(workspaceID: UUID, path: String, client: String) async throws -> AgentRead? {
        let context = try context(for: workspaceID)
        guard let branch = await branch(for: client, invokedByUser: false, context) else { return nil }
        // The same rules as a read from your folder: git may hold a file the workspace leaves out.
        _ = try resolveListed(path, context, checkingInclude: true)
        return try await locks.run(lockKey(branch)) {
            try await agentBranches.fastForwardIfMerged(branch)
            guard let file = try await agentBranches.read(path, on: branch) else { return nil }
            let limit = context.workspace.settings.maxFileBytes
            guard let data = try check(file.data, path: path, limit: limit) else { return nil }
            return AgentRead(data: data, branch: branch.name)
        }
    }

    // MARK: - Submit and approve

    /// Like `submit`, but an agent's change goes to its branch. Use this for MCP changes.
    @discardableResult
    public func submitRouted(_ change: ProposedChange, exemptFromReplacingOptIn: Bool = false) async throws -> Outcome {
        let context = try context(for: change.workspaceID)
        guard let branch = await branch(
            for: change.branchAs ?? change.client,
            invokedByUser: change.invokedByUser,
            context
        ) else {
            return try submit(change, exemptFromReplacingOptIn: exemptFromReplacingOptIn)
        }
        return try await locks.run(lockKey(branch)) {
            guard let route = try await route(change, branch, context) else {
                return try submit(change, exemptFromReplacingOptIn: exemptFromReplacingOptIn)
            }
            let plan = try makePlan(for: change, context, prefetched: route.prefetched)
            switch decide(plan, change, context, exemptFromReplacingOptIn: exemptFromReplacingOptIn, branched: true) {
            case .blocked:
                return .blocked
            case let .ask(reason):
                let item = Pending(change: change, reason: reason, diff: plan.diff, tier: plan.tier)
                try enqueue(item)
                return .pending(item)
            case .apply:
                let entry = try await land(
                    plan,
                    change,
                    context,
                    route,
                    approvedBy: change.invokedByUser ? .invoked : .auto
                )
                if !change.invokedByUser {
                    count(.auto, change)
                }
                return .applied(entry)
            }
        }
    }

    /// Like `approve`, but a change from an agent is committed to its branch.
    @discardableResult
    public func approveRouted(_ id: UUID) async throws -> ActivityEntry {
        guard let item = pending.first(where: { $0.id == id }) else { throw WriteError.unknownChange }
        let context = try context(for: item.change.workspaceID)
        guard let branch = await branch(
            for: item.change.branchAs ?? item.change.client,
            invokedByUser: item.change.invokedByUser,
            context
        )
        else {
            return try approve(id)
        }
        return try await locks.run(lockKey(branch)) {
            guard pending.contains(where: { $0.id == id }) else { throw WriteError.unknownChange }
            guard let route = try await route(item.change, branch, context) else { return try approve(id) }
            defer { dequeue(id) }
            let plan = try makePlan(for: item.change, context, prefetched: route.prefetched)
            let entry = try await land(plan, item.change, context, route, approvedBy: .user)
            count(.accepted, item.change)
            return entry
        }
    }

    // MARK: - Undo

    /// Like `undo`. A change on an agent branch is undone by a new commit on that branch, so the
    /// history keeps both.
    @discardableResult
    public func undoRouted(_ entryID: UUID, workspaceID: UUID) async throws -> ActivityEntry {
        guard let entry = entries(for: workspaceID).first(where: { $0.id == entryID }), let branchName = entry.branch
        else { return try undo(entryID, workspaceID: workspaceID) }
        guard !entry.isUndone else { throw WriteError.alreadyUndone }
        let context = try context(for: workspaceID)
        guard let branch = await agentBranches.open(
            directory: context.root,
            client: entry.agent ?? entry.provenance.model
        ),
            branch.name == branchName else { throw WriteError.unknownChange }
        try await locks.run(lockKey(branch)) {
            try await revert(entry, on: branch, context)
        }
        return try markUndone(entry)
    }

    public func revertRunRouted(_ runID: UUID, workspaceID: UUID) async -> RevertResult {
        var result = RevertResult(undone: 0, failures: [])
        for entry in entries(for: workspaceID).reversed() where entry.runID == runID && !entry.isUndone {
            do {
                try await undoRouted(entry.id, workspaceID: workspaceID)
                result.undone += 1
            } catch {
                result.failures.append("\(entry.path): \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: - Steps

    private func branch(for client: String?, invokedByUser: Bool, _ context: GateContext) async -> AgentBranch? {
        guard let client, !invokedByUser, context.workspace.settings.agentBranches == .perAgent else { return nil }
        return await agentBranches.open(directory: context.root, client: client)
    }

    private func lockKey(_ branch: AgentBranch) -> String {
        branch.directory.path + "\u{0}" + branch.name
    }

    /// Reads the file from the branch. Returns `nil` for an edit to a file git doesn't track, which
    /// then takes the ordinary path.
    private func route(_ change: ProposedChange, _ branch: AgentBranch, _ context: GateContext) async throws -> Route? {
        for path in change.edit.paths where !change.scope.contains(path) {
            throw WriteError.outsideScope(path)
        }
        let path = change.edit.primaryPath
        let url = try resolveListed(path, context)
        try await agentBranches.fastForwardIfMerged(branch)
        let tip = try await agentBranches.tip(of: branch)
        let file = try await agentBranches.read(path, on: branch, tip: tip)
        var taken = false
        if case let .move(_, destination) = change.edit {
            let target = try resolveListed(destination, context)
            let onBranch = try await agentBranches.read(destination, on: branch, tip: tip)
            taken = onBranch != nil || FileManager.default.fileExists(atPath: target.path)
        }
        if case .createFile = change.edit {
            // A new file must not exist on the branch or in your folder, tracked or not.
            guard file == nil, !FileManager.default.fileExists(atPath: url.path) else {
                throw WriteError.alreadyExists(path)
            }
        } else if file == nil {
            return nil
        }
        return Route(
            branch: branch,
            tip: tip,
            mode: file?.mode,
            prefetched: Prefetched(before: file?.data, destinationTaken: taken)
        )
    }

    /// Saves the pre-image, claims new paths, commits, and logs it.
    private func land(
        _ plan: WritePlan,
        _ change: ProposedChange,
        _ context: GateContext,
        _ route: Route,
        approvedBy: ApprovedBy
    ) async throws -> ActivityEntry {
        let branch = route.branch
        try savePreImage(plan, context)
        // Only a new path is claimed: nobody else holds a version of it yet.
        if route.prefetched.before == nil {
            try await agentBranches.claim(plan.path, for: branch, now: now())
        }
        if let toPath = plan.toPath {
            try await agentBranches.claim(toPath, for: branch, now: now())
        }
        var changes: [AgentFileChange] = []
        switch change.edit {
        case .delete:
            changes = [AgentFileChange(path: plan.path, data: nil, mode: nil)]
        case .move:
            changes = [
                AgentFileChange(path: plan.path, data: nil, mode: nil),
                AgentFileChange(path: plan.toPath ?? plan.path, data: plan.before, mode: route.mode),
            ]
        default:
            changes = [AgentFileChange(path: plan.path, data: plan.after, mode: route.mode)]
        }
        let id = UUID()
        let commit = try await agentBranches.commit(
            changes,
            message: message(for: change, plan, approvedBy: approvedBy, activityID: id),
            on: branch,
            expectedTip: route.tip
        )
        return try log(
            plan,
            change,
            context,
            approvedBy: approvedBy,
            id: id,
            landed: Landed(branch: branch.name, commit: commit, agent: branch.client)
        )
    }

    private func message(
        for change: ProposedChange,
        _ plan: WritePlan,
        approvedBy: ApprovedBy,
        activityID: UUID
    ) -> AgentCommitMessage {
        let clean = { (text: String) in text.replacingOccurrences(of: "\n", with: " ") }
        let target = plan.toPath.map { "\(plan.path) to \($0)" } ?? plan.path
        return AgentCommitMessage(
            subject: clean("\(change.edit.name): \(target)"),
            trailers: [
                ("Fen-Agent", clean(change.branchAs ?? change.client ?? "")),
                ("Fen-Operation", clean(change.operation)),
                ("Fen-Run", change.runID.uuidString.lowercased()),
                ("Fen-Activity", activityID.uuidString.lowercased()),
                ("Fen-Approved-By", approvedBy.rawValue),
                (
                    change.provenance.commitTrailer.components(separatedBy: ": ")[0],
                    change.provenance.commitTrailer.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
                ),
            ]
        )
    }

    /// Commits the reverse of `entry`, unless the branch's file changed after it.
    private func revert(_ entry: ActivityEntry, on branch: AgentBranch, _ context: GateContext) async throws {
        let tip = try await agentBranches.tip(of: branch)
        let visiblePath = entry.toPath ?? entry.path
        let current = try await agentBranches.read(visiblePath, on: branch, tip: tip)
        guard current.map({ ContentHash.of($0.data) }) == entry.postHash else {
            throw WriteError.changedSinceApply(visiblePath)
        }
        var changes: [AgentFileChange]
        if entry.toPath != nil {
            changes = [
                AgentFileChange(path: visiblePath, data: nil, mode: nil),
                AgentFileChange(path: entry.path, data: current?.data, mode: current?.mode),
            ]
        } else if let preHash = entry.preHash {
            let store = PreImageStore(directory: home.preImagesDirectory(id: context.workspace.id))
            guard let data = store.load(path: entry.path, hash: preHash) else {
                throw WriteError.preImageMissing(entry.path)
            }
            changes = [AgentFileChange(path: entry.path, data: data, mode: current?.mode)]
        } else {
            changes = [AgentFileChange(path: entry.path, data: nil, mode: nil)]
        }
        _ = try await agentBranches.commit(
            changes,
            message: AgentCommitMessage(
                subject: "Undo: \(entry.edit) \(entry.path)",
                trailers: [("Fen-Agent", entry.provenance.model), ("Fen-Undo-Of", entry.id.uuidString.lowercased())]
            ),
            on: branch,
            expectedTip: tip
        )
    }
}
