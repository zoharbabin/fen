import Foundation

/// A typed document that a name can point to.
struct LinkTarget: Equatable {
    let path: String
    let title: String
    let type: String

    var stem: String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// How a name was matched, and how sure Fen is. A title or file name that equals the name is
/// near-certain. A name that is part of a longer one ("Jane" in "Jane Doe") is a guess.
enum LinkMatchMethod: String {
    case title
    case filename
    case namePart = "name-part"

    var confidence: Double {
        switch self {
        case .title: 0.95
        case .filename: 0.9
        case .namePart: 0.7
        }
    }
}

enum LinkResolution: Equatable {
    case match(LinkTarget, LinkMatchMethod)
    /// Several documents fit equally. Fen proposes none of them.
    case ambiguous([LinkTarget])
    case none
}

/// Resolves a name in a front matter field to an existing typed document (issue #11). It matches
/// on titles and file names only, so it never invents a link.
struct LinkResolver {
    private struct Entry {
        let target: LinkTarget
        let titleTokens: Set<String>
    }

    /// Names shorter than this never match part of a longer name.
    static let minPartLength = 3

    private let entries: [Entry]
    private let byTitle: [String: [Int]]
    private let byStem: [String: [Int]]
    private let byToken: [String: [Int]]
    private let stemCounts: [String: Int]

    /// `allPaths` is every document in the workspace. It decides whether a bare file name is enough
    /// for a link or the path is needed.
    init(targets: [LinkTarget], allPaths: [String]) {
        let entries = targets.map { target in
            Entry(
                target: target,
                titleTokens: Set(Self.tokens(target.title.isEmpty ? target.stem : target.title))
            )
        }
        var title: [String: [Int]] = [:]
        var stem: [String: [Int]] = [:]
        var token: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            title[Self.fold(entry.target.title), default: []].append(index)
            stem[Self.fold(entry.target.stem), default: []].append(index)
            for word in entry.titleTokens {
                token[word, default: []].append(index)
            }
        }
        var counts: [String: Int] = [:]
        for path in allPaths {
            counts[MarkdownChunker.wikiKey((path as NSString).lastPathComponent), default: 0] += 1
        }
        self.entries = entries
        byTitle = title
        byStem = stem
        byToken = token
        stemCounts = counts
    }

    func resolve(_ mention: String, excluding path: String) -> LinkResolution {
        let name = Self.fold(mention)
        guard !name.isEmpty else { return .none }
        let others = { (indexes: [Int]?) in (indexes ?? []).map { entries[$0].target }.filter { $0.path != path } }
        let exactTitle = others(byTitle[name])
        if !exactTitle.isEmpty {
            return Self.decide(exactTitle, .title)
        }
        let exactStem = others(byStem[name])
        if !exactStem.isEmpty {
            return Self.decide(exactStem, .filename)
        }
        let words = Set(Self.tokens(mention))
        guard !words.isEmpty, words.allSatisfy({ $0.count >= Self.minPartLength }),
              let rarest = words.compactMap({ byToken[$0] }).min(by: { $0.count < $1.count }),
              words.allSatisfy({ byToken[$0] != nil }) else { return .none }
        let parts = rarest.filter { words.isSubset(of: entries[$0].titleTokens) }
        let found = others(parts)
        return found.isEmpty ? .none : Self.decide(found, .namePart)
    }

    /// What goes inside `[[ ]]`: the file name, or the path when another file shares that name.
    func linkText(for target: LinkTarget) -> String {
        let key = MarkdownChunker.wikiKey((target.path as NSString).lastPathComponent)
        if (stemCounts[key] ?? 0) <= 1 {
            return target.stem
        }
        return (target.path as NSString).deletingPathExtension
    }

    private static func decide(_ targets: [LinkTarget], _ method: LinkMatchMethod) -> LinkResolution {
        targets.count == 1 ? .match(targets[0], method) : .ambiguous(targets)
    }

    /// Case, accents, dashes and spacing don't matter: `jane-doe`, `Jane  Doe` and `Jané Doe` agree.
    static func fold(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
