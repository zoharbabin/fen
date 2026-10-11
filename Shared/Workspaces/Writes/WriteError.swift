import Foundation

public enum WriteError: Error, Equatable, LocalizedError {
    case unknownWorkspace
    case outsideScope(String)
    case invalidPath(String)
    case notText(String)
    case tooLarge(String)
    case missing(String)
    case alreadyExists(String)
    /// The file changed after the result was computed. Run the feature again.
    case targetChanged(String)
    case findNotUnique(count: Int)
    case frontMatter(FrontMatterError)
    case noChange
    case unknownChange
    case alreadyUndone
    /// The file is no longer as Fen left it, so undo would overwrite your newer edits.
    case changedSinceApply(String)
    case preImageMissing(String)

    public var errorDescription: String? {
        switch self {
        case .unknownWorkspace: "That workspace isn't available."
        case let .outsideScope(path): "“\(path)” is outside what this run may change."
        case let .invalidPath(path): "Fen won't write to “\(path)”."
        case let .notText(path): "“\(path)” isn't a UTF-8 text file."
        case let .tooLarge(path): "“\(path)” is larger than this workspace's size limit."
        case let .missing(path): "“\(path)” doesn't exist."
        case let .alreadyExists(path): "“\(path)” already exists."
        case let .targetChanged(path): "“\(path)” changed after the AI read it. Run it again."
        case let .findNotUnique(count):
            count == 0 ? "The text to replace wasn't found." : "The text to replace appears \(count) times."
        case .frontMatter(.multilineValue): "A front matter value can't have a line break."
        case .frontMatter(.invalidKey): "That front matter key isn't a plain name."
        case .frontMatter(.complexExistingValue): "That front matter key holds a list or block. Fen won't edit it."
        case .noChange: "The edit changes nothing."
        case .unknownChange: "That change is no longer waiting."
        case .alreadyUndone: "That change was already undone."
        case let .changedSinceApply(path): "“\(path)” changed since Fen wrote it, so Fen won't undo over your edits."
        case let .preImageMissing(path): "Fen has no saved copy of “\(path)” to restore."
        }
    }
}

public enum EditParseError: Error, Equatable, LocalizedError {
    case notJSON
    case unexpectedField(String)
    case unknownOperation(String)
    case missingField(op: String, field: String)
    case tooManyEdits
    case outsideScope(String)

    public var errorDescription: String? {
        switch self {
        case .notJSON: "The result isn't a list of edits."
        case let .unexpectedField(field): "The result has an unexpected field “\(field)”."
        case let .unknownOperation(op): "The result asks for an unknown operation “\(op)”."
        case let .missingField(op, field): "The “\(op)” edit is missing “\(field)”."
        case .tooManyEdits: "The result has too many edits."
        case let .outsideScope(path): "The result edits “\(path)”, which is outside this run."
        }
    }
}
