import Foundation
import Observation

/// The only way an AI feature changes a file in a workspace (issue #140).
///
/// Every change passes the same checks, whatever its source:
/// 1. It names a workspace Fen has, and every path is inside the run's scope and the workspace root
///    (`PathGate`), not hidden, not secret-looking, and valid UTF-8 text.
/// 2. The file still has the hash the result was computed from (compare-and-swap).
/// 3. `WritePolicy` decides: apply, ask, or block.
/// 4. A saved pre-image, an atomic write, then a line in the activity log.
///
/// There is no network code in this folder. A document's text can't make a write do more than the
/// fixed `EditOperation`s.
@MainActor @Observable
public final class WriteGate {
    public struct Pending: Identifiable, Sendable, Equatable {
        public var id: UUID {
            change.id
        }

        public var change: ProposedChange
        public var reason: WriteDecision.AskReason
        public var diff: LineDiff
        public var tier: EditTier
    }

    public enum Outcome: Sendable, Equatable {
        case applied(ActivityEntry)
        case pending(Pending)
        case blocked
    }

    public struct RevertResult: Sendable, Equatable {
        public var undone: Int
        public var failures: [String]
    }

    public private(set) var pending: [Pending] = []
    public private(set) var activity: [UUID: [ActivityEntry]] = [:]
    public private(set) var isPaused: Bool

    @ObservationIgnored let home: FenHome
    @ObservationIgnored private let workspaces: @MainActor () -> [Workspace]
    @ObservationIgnored private let rootURL: @MainActor (UUID) throws -> URL
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored let agentBranches: AgentBranches
    @ObservationIgnored let locks = AsyncLocks()

    public convenience init(
        home: FenHome,
        workspaces: @escaping @MainActor () -> [Workspace],
        rootURL: @escaping @MainActor (UUID) throws -> URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(home: home, workspaces: workspaces, rootURL: rootURL, now: now, agentBranches: AgentBranches())
    }

    /// Tests pass their own `AgentBranches`.
    init(
        home: FenHome,
        workspaces: @escaping @MainActor () -> [Workspace],
        rootURL: @escaping @MainActor (UUID) throws -> URL,
        now: @escaping @Sendable () -> Date = { Date() },
        agentBranches: AgentBranches
    ) {
        self.agentBranches = agentBranches
        self.home = home
        self.workspaces = workspaces
        self.rootURL = rootURL
        self.now = now
        isPaused = Self.readPaused(home.writePolicyFile)
    }

    /// The gate for the app's own workspaces.
    public static let shared = WriteGate(library: .shared)

    public convenience init(library: WorkspaceLibrary) {
        self.init(
            home: library.registry.home,
            workspaces: { library.workspaces },
            rootURL: { try library.registry.rootURL(for: $0) }
        )
    }

    // MARK: - Pause

    /// While paused, nothing is auto-approved. Everything asks. Stored in `~/.fen/write-policy.json`.
    public func setPaused(_ paused: Bool) throws {
        try home.ensureExists()
        let data = try JSONEncoder().encode(["paused": paused])
        try data.write(to: home.writePolicyFile, options: .atomic)
        isPaused = paused
    }

    private static func readPaused(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let values = try? JSONDecoder().decode([String: Bool].self, from: data) else { return false }
        return values["paused"] ?? false
    }

    // MARK: - Submit

    /// Hash of a workspace file right now, or `nil` if it doesn't exist. Take it when you read the
    /// file for the model, and pass it as `baseHash`.
    public func contentHash(workspaceID: UUID, relativePath: String) throws -> String? {
        let context = try context(for: workspaceID)
        let url = try resolve(relativePath, context)
        return (try? Data(contentsOf: url)).map(ContentHash.of)
    }

    @discardableResult
    public func submit(_ change: ProposedChange, exemptFromReplacingOptIn: Bool = false) throws -> Outcome {
        let context = try context(for: change.workspaceID)
        let plan = try makePlan(for: change, context)
        let decision = decide(plan, change, context, exemptFromReplacingOptIn: exemptFromReplacingOptIn)
        switch decision {
        case .blocked:
            return .blocked
        case let .ask(reason):
            let item = Pending(change: change, reason: reason, diff: plan.diff, tier: plan.tier)
            try enqueue(item)
            return .pending(item)
        case .apply:
            let entry = try perform(plan, change, context, approvedBy: change.invokedByUser ? .invoked : .auto)
            if !change.invokedByUser {
                record(.auto, change)
            }
            return .applied(entry)
        }
    }

    func decide(
        _ plan: WritePlan,
        _ change: ProposedChange,
        _ context: GateContext,
        exemptFromReplacingOptIn: Bool,
        branched: Bool = false
    ) -> WriteDecision {
        let settings = context.workspace.settings
        let mode = settings.writePolicy.mode(
            workspaceDefault: settings.approvalMode,
            operation: change.operation,
            documentType: change.documentType,
            paths: change.edit.paths,
            client: change.client
        )
        let decision = settings.writePolicy.decide(WriteFacts(
            mode: mode,
            tier: plan.tier,
            operation: change.operation,
            invokedByUser: change.invokedByUser,
            paused: isPaused,
            overCap: isOverCap(plan, change, settings.writePolicy),
            confidence: change.basis?.confidence,
            exemptFromReplacingOptIn: exemptFromReplacingOptIn
        ))
        // A change meant for a branch never auto-applies into your files.
        if decision == .apply, change.branchAs != nil, !change.invokedByUser, !branched {
            return .ask(.noBranch)
        }
        return decision
    }

    /// Applies a waiting change. Fails with `targetChanged` if the file moved on, and drops it.
    @discardableResult
    public func approve(_ id: UUID) throws -> ActivityEntry {
        guard let item = pending.first(where: { $0.id == id }) else { throw WriteError.unknownChange }
        let context = try context(for: item.change.workspaceID)
        defer { pending.removeAll { $0.id == id } }
        let plan = try makePlan(for: item.change, context)
        let entry = try perform(plan, item.change, context, approvedBy: .user)
        record(.accepted, item.change)
        return entry
    }

    public func reject(_ id: UUID) {
        if let item = pending.first(where: { $0.id == id }) {
            record(.dismissed, item.change)
        }
        pending.removeAll { $0.id == id }
    }

    /// What you accepted and dismissed in a workspace, per operation.
    public func stats(for workspaceID: UUID) -> ProposalStats {
        ProposalStatsStore(file: home.proposalStatsFile(id: workspaceID)).load()
    }

    /// How many changes one MCP client may have waiting at once. A client gets a fresh run for
    /// each proposal, so `maxFilesPerRun` never bounds it.
    static let maxPendingPerClient = 50

    func enqueue(_ item: Pending) throws {
        if let client = item.change.client,
           pending.count(where: { $0.change.client == client && $0.id != item.id }) >= Self.maxPendingPerClient {
            throw WriteError.tooManyPending
        }
        pending.removeAll { $0.id == item.id }
        pending.append(item)
    }

    func dequeue(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    func count(_ outcome: ProposalStats.Outcome, _ change: ProposedChange) {
        record(outcome, change)
    }

    /// Counting never blocks a write, so a failure to save a count is dropped.
    private func record(_ outcome: ProposalStats.Outcome, _ change: ProposedChange) {
        try? ProposalStatsStore(file: home.proposalStatsFile(id: change.workspaceID))
            .record(outcome, operation: change.operation)
    }

    public func pending(for workspaceID: UUID) -> [Pending] {
        pending.filter { $0.change.workspaceID == workspaceID }
    }

    // MARK: - Activity and undo

    /// Oldest first. Loads from disk the first time, so it survives a restart.
    public func entries(for workspaceID: UUID) -> [ActivityEntry] {
        if let cached = activity[workspaceID] {
            return cached
        }
        let loaded = ActivityLog(file: home.activityLogFile(id: workspaceID)).load()
        activity[workspaceID] = loaded
        return loaded
    }

    /// Puts one change back. Refuses if you edited the file after Fen did.
    @discardableResult
    public func undo(_ entryID: UUID, workspaceID: UUID) throws -> ActivityEntry {
        let context = try context(for: workspaceID)
        guard let entry = entries(for: workspaceID).first(where: { $0.id == entryID }) else {
            throw WriteError.unknownChange
        }
        guard !entry.isUndone else { throw WriteError.alreadyUndone }
        try restore(entry, context)
        return try markUndone(entry)
    }

    func markUndone(_ entry: ActivityEntry) throws -> ActivityEntry {
        let date = now()
        try ActivityLog(file: home.activityLogFile(id: entry.workspaceID)).appendUndone(id: entry.id, date: date)
        var updated = entry
        updated.undoneAt = date
        replace(updated)
        return updated
    }

    /// Undoes every change of one run, newest first. Changes you edited since are left and listed.
    public func revertRun(_ runID: UUID, workspaceID: UUID) -> RevertResult {
        var result = RevertResult(undone: 0, failures: [])
        for entry in entries(for: workspaceID).reversed() where entry.runID == runID && !entry.isUndone {
            do {
                try undo(entry.id, workspaceID: workspaceID)
                result.undone += 1
            } catch {
                result.failures.append("\(entry.path): \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: - Context

    func context(for id: UUID) throws -> GateContext {
        guard let workspace = workspaces().first(where: { $0.id == id }) else { throw WriteError.unknownWorkspace }
        let root = try rootURL(id)
        return GateContext(workspace: workspace, root: PathGate.canonicalURL(of: root) ?? root)
    }

    /// A path Fen may write: relative, inside the root, no hidden part, not secret-looking, and no
    /// control character or `"`, which git would read as an entry break or a quoted path.
    func resolve(_ path: String, _ context: GateContext) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let unsafe = path.unicodeScalars.contains { $0 == "\"" || CharacterSet.controlCharacters.contains($0) }
        guard !path.isEmpty, !unsafe, !path.hasPrefix("/"), !parts.contains(""), !parts.contains(".."),
              !parts.contains("."),
              !parts.contains(where: { $0.hasPrefix(".") }),
              !FileEligibility.looksSecret(fileName: parts[parts.count - 1]),
              let url = PathGate.resolve(relativePath: path, in: context.root) else {
            throw WriteError.invalidPath(path)
        }
        return url
    }

    /// `resolve`, plus the workspace's own lists: a path `.gitignore` or an exclude glob leaves out
    /// is refused before Fen looks at the file. A change can't land where a read can't see, and
    /// the answer doesn't tell whether the file exists. With `checkingInclude`, a path the include
    /// globs don't match is refused too.
    func resolveListed(_ path: String, _ context: GateContext, checkingInclude: Bool = false) throws -> URL {
        let url = try resolve(path, context)
        let source = LocalFolderSource(root: context.root, settings: context.workspace.settings)
        guard source.ruleExclusion(forRelativePath: path, checkingInclude: checkingInclude) == nil else {
            throw WriteError.invalidPath(path)
        }
        return url
    }

    // MARK: - Plan

    func makePlan(
        for change: ProposedChange,
        _ context: GateContext,
        prefetched: Prefetched? = nil
    ) throws -> WritePlan {
        for path in change.edit.paths where !change.scope.contains(path) {
            throw WriteError.outsideScope(path)
        }
        let path = change.edit.primaryPath
        let url = try resolveListed(path, context)
        let limit = context.workspace.settings.maxFileBytes
        let before = try prefetched.map { try check($0.before, path: path, limit: limit) }
            ?? readCurrent(url, path: path, limit: limit)
        guard before.map(ContentHash.of) == change.baseHash else { throw WriteError.targetChanged(path) }
        let oldText = before.flatMap { String(data: $0, encoding: .utf8) }
        let planned = try EditPlanner.plan(change.edit, existing: oldText)
        var toPath: String?
        var toURL: URL?
        if case let .move(_, destination) = change.edit {
            let target = try resolveListed(destination, context)
            guard !(prefetched?.destinationTaken ?? FileManager.default.fileExists(atPath: target.path))
            else { throw WriteError.alreadyExists(destination) }
            toPath = destination
            toURL = target
        }
        let after = planned.newText.map { Data($0.utf8) }
        let isMove = toPath != nil
        if !isMove, after == before {
            throw WriteError.noChange
        }
        return WritePlan(
            tier: planned.tier,
            path: path,
            url: url,
            toPath: toPath,
            toURL: toURL,
            before: before,
            after: after,
            diff: isMove ? .make(old: "", new: "") : .make(old: oldText ?? "", new: planned.newText ?? "")
        )
    }

    private func readCurrent(_ url: URL, path: String, limit: Int) throws -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue else { throw WriteError.invalidPath(path) }
        return try check(Data(contentsOf: url), path: path, limit: limit)
    }

    func check(_ data: Data?, path: String, limit: Int) throws -> Data? {
        guard let data else { return nil }
        guard data.count <= limit else { throw WriteError.tooLarge(path) }
        guard String(data: data, encoding: .utf8) != nil else { throw WriteError.notText(path) }
        return data
    }

    func isOverCap(_ plan: WritePlan, _ change: ProposedChange, _ policy: WritePolicy) -> Bool {
        let paths = Set(entries(for: change.workspaceID).filter { $0.runID == change.runID }.map(\.path))
        if !paths.contains(plan.path), paths.count + 1 > policy.maxFilesPerRun {
            return true
        }
        return plan.tier == .replacing && plan.diff.changedFraction > policy.maxChangedFraction
    }

    // MARK: - Write

    private func perform(
        _ plan: WritePlan,
        _ change: ProposedChange,
        _ context: GateContext,
        approvedBy: ApprovedBy
    ) throws -> ActivityEntry {
        try savePreImage(plan, context)
        try writeToDisk(plan, change.edit)
        return try log(plan, change, context, approvedBy: approvedBy)
    }

    func savePreImage(_ plan: WritePlan, _ context: GateContext) throws {
        if let before = plan.before {
            try PreImageStore(directory: home.preImagesDirectory(id: context.workspace.id)).save(
                before,
                path: plan.path
            )
        }
    }

    struct Landed {
        var branch: String
        var commit: String
        var agent: String
    }

    /// Adds the line to the activity log once the change is on disk (or committed).
    func log(
        _ plan: WritePlan,
        _ change: ProposedChange,
        _ context: GateContext,
        approvedBy: ApprovedBy,
        id: UUID = UUID(),
        landed: Landed? = nil
    ) throws -> ActivityEntry {
        let workspaceID = context.workspace.id
        let entry = ActivityEntry(
            id: id,
            runID: change.runID,
            workspaceID: workspaceID,
            date: now(),
            operation: change.operation,
            edit: change.edit.name,
            tier: plan.tier,
            path: plan.path,
            toPath: plan.toPath,
            preHash: plan.before.map(ContentHash.of),
            postHash: (plan.after ?? (plan.toPath == nil ? nil : plan.before)).map(ContentHash.of),
            provenance: change.provenance,
            approvedBy: approvedBy,
            diff: plan.diff,
            branch: landed?.branch,
            commit: landed?.commit,
            agent: landed?.agent
        )
        try ActivityLog(file: home.activityLogFile(id: workspaceID)).appendApplied(entry)
        activity[workspaceID] = entries(for: workspaceID) + [entry]
        return entry
    }

    private func writeToDisk(_ plan: WritePlan, _ edit: EditOperation) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: plan.url.path))?[.posixPermissions]
        switch edit {
        case .delete:
            try FileManager.default.removeItem(at: plan.url)
        case .move:
            if let toURL = plan.toURL {
                try FileManager.default.createDirectory(
                    at: toURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: plan.url, to: toURL)
            }
        default:
            try write(plan.after ?? Data(), to: plan.url, permissions: permissions)
        }
    }

    private func write(_ data: Data, to url: URL, permissions: Any?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    // MARK: - Undo

    private func restore(_ entry: ActivityEntry, _ context: GateContext) throws {
        let url = try resolve(entry.path, context)
        let current = try? Data(contentsOf: url)
        if let toPath = entry.toPath {
            let toURL = try resolve(toPath, context)
            guard (try? Data(contentsOf: toURL)).map(ContentHash.of) == entry.postHash,
                  !FileManager.default.fileExists(atPath: url.path) else {
                throw WriteError.changedSinceApply(toPath)
            }
            try FileManager.default.moveItem(at: toURL, to: url)
            return
        }
        guard current.map(ContentHash.of) == entry.postHash else { throw WriteError.changedSinceApply(entry.path) }
        guard let preHash = entry.preHash else {
            try FileManager.default.removeItem(at: url)
            return
        }
        let store = PreImageStore(directory: home.preImagesDirectory(id: context.workspace.id))
        guard let data = store.load(path: entry.path, hash: preHash)
        else { throw WriteError.preImageMissing(entry.path) }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try write(data, to: url, permissions: permissions)
    }

    func replace(_ entry: ActivityEntry) {
        guard var list = activity[entry.workspaceID], let index = list.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        list[index] = entry
        activity[entry.workspaceID] = list
    }
}

struct GateContext {
    var workspace: Workspace
    var root: URL
}

struct WritePlan {
    var tier: EditTier
    var path: String
    var url: URL
    var toPath: String?
    var toURL: URL?
    var before: Data?
    var after: Data?
    var diff: LineDiff
}

/// What a read from an agent branch found, handed to `makePlan` in place of a read from disk.
struct Prefetched {
    var before: Data?
    var destinationTaken = false
}
