import Foundation

public extension SharedTextImport {
    /// Saves `raw` as a new note in `directory` and returns the file, or `nil` when there is nothing to
    /// import. The name comes from the text's first heading or line, and a taken name gets a number.
    static func saveNote(from raw: String?, into directory: URL) throws -> URL? {
        guard let text = try text(from: raw) else { return nil }
        return try SharedTextInbox.write(text, as: SharedTextInbox.fileName(for: text), in: directory)
    }
}
