import Foundation

/// A warning about a likely typo in front matter (issue #7). It is advice only: Fen never blocks
/// a save, never rejects a value, and never changes the file unless you apply the fix.
public struct SchemaHint: Sendable, Equatable, Identifiable {
    public enum Fix: Sendable, Equatable {
        /// Replace the `type:` value.
        case setType(to: String)
        /// Rename a key.
        case renameKey(from: String, to: String)
    }

    public let message: String
    public let fix: Fix

    public var id: String {
        message
    }
}

public enum SchemaHints {
    /// Likely typos in `frontMatter` against `schema`. A document with no type, or a type the
    /// schema doesn't know and that isn't close to one, gets no hint: it is fine as it is.
    public static func hints(for frontMatter: [String: Any]?, in schema: DocumentSchema) -> [SchemaHint] {
        guard let frontMatter else { return [] }
        var hints = typeKeyHints(frontMatter)
        guard let typeValue = DocumentProperties.typeName(in: frontMatter) else { return hints }
        guard let type = schema.type(named: typeValue) else {
            if let near = nearest(to: typeValue, among: schema.types.map(\.name)) {
                hints.append(SchemaHint(
                    message: "type \"\(typeValue)\" isn't a known type. Did you mean \"\(near)\"?",
                    fix: .setType(to: near)
                ))
            }
            return hints
        }
        let known = Set(type.fields.map(\.name))
        for key in frontMatter.keys.sorted() where key != "type" && !known.contains(key) {
            let free = type.fields.map(\.name).filter { frontMatter[$0] == nil }
            if let near = nearest(to: key, among: free) {
                hints.append(SchemaHint(
                    message: "\"\(key)\" isn't a field of \(type.name). Did you mean \"\(near)\"?",
                    fix: .renameKey(from: key, to: near)
                ))
            }
        }
        return hints
    }

    /// `tpye:` or `Type:` where `type:` was meant.
    private static func typeKeyHints(_ frontMatter: [String: Any]) -> [SchemaHint] {
        guard frontMatter["type"] == nil else { return [] }
        return frontMatter.keys.sorted().compactMap { key in
            guard nearest(to: key, among: ["type"]) != nil else { return nil }
            return SchemaHint(
                message: "\"\(key)\" looks like type. Did you mean \"type\"?",
                fix: .renameKey(from: key, to: "type")
            )
        }
    }

    /// The closest name that is not `word` itself: a different case, or a small number of
    /// typing mistakes. Short names need to be closer.
    static func nearest(to word: String, among names: [String]) -> String? {
        let allowed = { (name: String) in name.count <= 4 ? 1 : 2 }
        let close = names.filter { $0 != word }.compactMap { name -> (name: String, distance: Int)? in
            let distance = editDistance(word.lowercased(), name.lowercased())
            guard distance <= allowed(name), word.count >= 3 || distance == 0 else { return nil }
            return (name, distance)
        }
        return close.min { $0.distance < $1.distance }?.name
    }

    /// Optimal string alignment distance: insert, delete, replace, or swap two neighbours.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty {
            return right.count
        }
        if right.isEmpty {
            return left.count
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: right.count + 1), count: left.count + 1)
        for i in 0 ... left.count {
            table[i][0] = i
        }
        for j in 0 ... right.count {
            table[0][j] = j
        }
        for i in 1 ... left.count {
            for j in 1 ... right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, left[i - 1] == right[j - 2], left[i - 2] == right[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[left.count][right.count]
    }
}
