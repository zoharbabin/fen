import Foundation

struct LinkDocument: Sendable, Equatable {
    let path: String
    let title: String
    let text: String
    /// The `type:` in the front matter, if any.
    let type: String?
}

/// One name in one field that points to one document.
struct LinkEvidence: Equatable {
    let field: String
    let mention: String
    let targetPath: String
    let linkText: String
    let method: LinkMatchMethod
}

/// New front matter for one document, with every name in it that resolved.
struct LinkRewrite: Equatable {
    let path: String
    let type: String
    /// The front matter as it is, and as it would be.
    let before: String
    let after: String
    let links: [LinkEvidence]

    /// The weakest link decides, so one guess keeps the whole change in the queue.
    var confidence: Double {
        links.map(\.method.confidence).min() ?? 0
    }
}

/// A new document for a name that matches nothing, in a field that holds names.
struct LinkStub: Equatable {
    let path: String
    let content: String
    let type: String
    let mention: String
    let field: String
    /// The documents that mention it.
    let mentionedIn: [String]
}

struct LinkPlan: Equatable {
    var rewrites: [LinkRewrite] = []
    var stubs: [LinkStub] = []
    /// Names that fit several documents equally, as readable lines. Fen proposes nothing for them.
    var ambiguous: [String] = []
}

/// Link and entity resolution over a whole workspace (issue #11). Pure: text in, proposals out.
///
/// It reads the text and list fields of typed documents and nothing else. It never looks for names
/// in the body, and never invents a type. A stub is offered only for a field that already holds
/// links elsewhere in the workspace, and it takes the type those links point to.
enum LinkPlanner {
    /// Matches a field needs before a missing name in it gets a stub. One match could be luck.
    static let minMatchesForStubs = 2

    static func plan(documents: [LinkDocument], schema: DocumentSchema) -> LinkPlan {
        let targets = documents.compactMap { document in
            document.type.map { LinkTarget(path: document.path, title: document.title, type: $0) }
        }
        let resolver = LinkResolver(targets: targets, allPaths: documents.map(\.path))
        let sources = documents.compactMap { source(for: $0, schema: schema) }
        let fields = learnFields(sources, resolver)
        var plan = LinkPlan()
        var missing: [String: LinkStubDraft] = [:]
        for source in sources {
            if let rewrite = rewrite(source, resolver, &plan.ambiguous, &missing) {
                plan.rewrites.append(rewrite)
            }
        }
        plan.stubs = stubs(
            from: missing,
            fields: fields,
            targets: targets,
            paths: Set(documents.map { $0.path.lowercased() })
        )
        return plan
    }

    // MARK: - Sources

    private struct Source {
        let document: LinkDocument
        let type: String
        let fieldNames: Set<String>
        let lines: [String]
    }

    private static func source(for document: LinkDocument, schema: DocumentSchema) -> Source? {
        guard let name = document.type, let type = schema.type(named: name),
              let lines = FrontMatterEditor.lines(of: document.text) else { return nil }
        let names = Set(type.fields.filter { !$0.hidden && ($0.kind == .text || $0.kind == .list) }.map(\.name))
        // A title is the document's own name, not a mention of another.
        return names.isEmpty ? nil : Source(
            document: document,
            type: name,
            fieldNames: names.subtracting(["title"]),
            lines: lines
        )
    }

    // MARK: - Fields that hold names

    private struct FieldKey: Hashable {
        let type: String
        let field: String
    }

    private struct FieldProfile {
        var values = Set<String>()
        var targetTypes: [String: Int] = [:]
    }

    /// Per field: the names that resolved, and the types they resolved to.
    private static func learnFields(_ sources: [Source], _ resolver: LinkResolver) -> [FieldKey: FieldProfile] {
        var profiles: [FieldKey: FieldProfile] = [:]
        for source in sources {
            for mention in FrontMatterLinks.mentions(in: source.lines, fields: source.fieldNames) {
                guard case let .match(target, _) = resolver.resolve(mention.value, excluding: source.document.path)
                else {
                    continue
                }
                let key = FieldKey(type: source.type, field: mention.field)
                profiles[key, default: FieldProfile()].values.insert(LinkResolver.fold(mention.value))
                profiles[key, default: FieldProfile()].targetTypes[target.type, default: 0] += 1
            }
        }
        return profiles
    }

    // MARK: - Rewrites

    private struct LinkStubDraft {
        let key: FieldKey
        let mention: String
        var mentionedIn: [String]
    }

    private static func rewrite(
        _ source: Source,
        _ resolver: LinkResolver,
        _ ambiguous: inout [String],
        _ missing: inout [String: LinkStubDraft]
    ) -> LinkRewrite? {
        var links: [LinkEvidence] = []
        var seen = Set<String>()
        let lines = FrontMatterLinks.rewrite(source.lines, fields: source.fieldNames) { mention in
            switch resolver.resolve(mention.value, excluding: source.document.path) {
            case let .match(target, method):
                let text = resolver.linkText(for: target)
                links.append(LinkEvidence(
                    field: mention.field,
                    mention: mention.value,
                    targetPath: target.path,
                    linkText: text,
                    method: method
                ))
                return text
            case let .ambiguous(candidates):
                if seen.insert(mention.field + "\u{0}" + mention.value).inserted {
                    let names = candidates.map(\.path).joined(separator: ", ")
                    ambiguous.append("\(source.document.path): \(mention.field) \"\(mention.value)\" fits \(names)")
                }
            case .none:
                let name = LinkResolver.fold(mention.value)
                let key = FieldKey(type: source.type, field: mention.field)
                missing[name, default: LinkStubDraft(key: key, mention: mention.value, mentionedIn: [])]
                    .mentionedIn.append(source.document.path)
            }
            return nil
        }
        guard !links.isEmpty, let rewritten = FrontMatterEditor.replacingLines(in: source.document.text, with: lines),
              let before = FrontMatterEditor.head(of: source.document.text),
              let after = FrontMatterEditor.head(of: rewritten), before != after else { return nil }
        return LinkRewrite(path: source.document.path, type: source.type, before: before, after: after, links: links)
    }

    // MARK: - Stubs

    private static func stubs(
        from missing: [String: LinkStubDraft],
        fields: [FieldKey: FieldProfile],
        targets: [LinkTarget],
        paths: Set<String>
    ) -> [LinkStub] {
        var stubs: [LinkStub] = []
        for name in missing.keys.sorted() {
            guard let draft = missing[name], let profile = fields[draft.key],
                  profile.values.count >= minMatchesForStubs,
                  let type = profile.targetTypes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key,
                  let file = fileName(for: draft.mention) else { continue }
            let folder = commonFolder(of: type, in: targets)
            let path = folder.isEmpty ? file : folder + "/" + file
            guard !paths.contains(path.lowercased()) else { continue }
            let title = (file as NSString).deletingPathExtension
            stubs.append(LinkStub(
                path: path,
                content: "---\ntype: \(FrontMatterEditor.scalar(type))\n---\n\n# \(title)\n",
                type: type,
                mention: draft.mention,
                field: draft.key.field,
                mentionedIn: Array(Set(draft.mentionedIn)).sorted()
            ))
        }
        return stubs
    }

    /// A safe `.md` file name for a name, or `nil` when nothing is left of it.
    static func fileName(for mention: String) -> String? {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|[]#^%").union(.controlCharacters)
        let stripped = mention.components(separatedBy: unsafe).joined()
        let cleaned = stripped.split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? nil : cleaned + ".md"
    }

    /// The folder most documents of `type` are in. On a tie, the first by name.
    private static func commonFolder(of type: String, in targets: [LinkTarget]) -> String {
        var counts: [String: Int] = [:]
        for target in targets where target.type == type {
            counts[(target.path as NSString).deletingLastPathComponent, default: 0] += 1
        }
        let ranked = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        guard let best = ranked.first else { return "" }
        return best.key
    }
}
