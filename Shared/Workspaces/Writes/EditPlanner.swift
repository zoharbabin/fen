import Foundation

/// Works out what an edit does to a file's text, without touching the disk (issue #140).
enum EditPlanner {
    struct Result {
        var tier: EditTier
        /// The new text. `nil` for a delete.
        var newText: String?
    }

    /// `existing` is the file's current text, or `nil` if it doesn't exist.
    static func plan(_ edit: EditOperation, existing: String?) throws -> Result {
        switch edit {
        case .createFile, .append: try additive(edit, existing: existing)
        case .setFrontMatter, .replaceText: try replacing(edit, existing: existing)
        case .overwrite, .delete, .move: try wholeFile(edit, existing: existing)
        }
    }

    private static func additive(_ edit: EditOperation, existing: String?) throws -> Result {
        let path = edit.primaryPath
        if case let .createFile(_, content) = edit {
            guard existing == nil else { throw WriteError.alreadyExists(path) }
            return Result(tier: .additive, newText: content)
        }
        guard case let .append(_, text) = edit, let existing else { throw WriteError.missing(path) }
        guard !text.isEmpty else { throw WriteError.noChange }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        return Result(tier: .additive, newText: existing + separator + text + (text.hasSuffix("\n") ? "" : "\n"))
    }

    private static func replacing(_ edit: EditOperation, existing: String?) throws -> Result {
        let path = edit.primaryPath
        guard let existing else { throw WriteError.missing(path) }
        if case let .setFrontMatter(_, key, value) = edit {
            let tier = FrontMatterEditor.hasKey(key, in: existing) ? EditTier.replacing : .additive
            do {
                return try Result(tier: tier, newText: FrontMatterEditor.set(key: key, value: value, in: existing))
            } catch let error as FrontMatterError {
                throw WriteError.frontMatter(error)
            }
        }
        guard case let .replaceText(_, find, replacement) = edit else { throw WriteError.noChange }
        let count = find.isEmpty ? 0 : existing.components(separatedBy: find).count - 1
        guard count == 1 else { throw WriteError.findNotUnique(count: count) }
        return Result(tier: .replacing, newText: existing.replacingOccurrences(of: find, with: replacement))
    }

    private static func wholeFile(_ edit: EditOperation, existing: String?) throws -> Result {
        guard let existing else { throw WriteError.missing(edit.primaryPath) }
        switch edit {
        case let .overwrite(_, content): return Result(tier: .destructive, newText: content)
        case .delete: return Result(tier: .destructive, newText: nil)
        default: return Result(tier: .destructive, newText: existing)
        }
    }
}
