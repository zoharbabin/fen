import Foundation

/// A folder where the share extension leaves text for Fen to turn into documents (issue #43).
///
/// The extension and the app are two processes, so they meet in the App Group container. The
/// extension only writes `.md` files here. Fen reads them when it becomes active, makes a document
/// from each, and renames the file to `.consumed` instead of deleting it. A crash between the two
/// steps then loses nothing. Consumed files go after a day, unread files after thirty.
///
/// The share extension compiles this file by itself, so it must not use other Fen types.
public struct SharedTextInbox: Sendable {
    public static let groupIdentifier = "group.com.zoharbabin.fen"
    public static let consumedSuffix = ".consumed"
    public static let maxNameLength = 80
    public static let consumedLifetime: TimeInterval = 24 * 3600
    public static let unreadLifetime: TimeInterval = 30 * 24 * 3600

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The inbox in the App Group container, or `nil` when this build has no App Group (an
    /// unsigned build, for one). Then there is no share-sheet import, and nothing else changes.
    public static var standard: SharedTextInbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
            .map { SharedTextInbox(directory: $0.appendingPathComponent("Inbox", isDirectory: true)) }
    }

    // MARK: - Writing (the extension)

    /// Saves `raw` as a new `.md` file and returns its URL. Returns `nil` when there is nothing
    /// worth keeping. Throws `SharedTextImport.Failure.tooLarge` for text over the cap.
    @discardableResult
    public func add(_ raw: String?) throws -> URL? {
        guard let text = try SharedTextImport.text(from: raw) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = Self.fileName(for: text)
        var number = 1
        while true {
            let name = number == 1 ? "\(base).md" : "\(base) \(number).md"
            let url = directory.appendingPathComponent(name)
            do {
                // Creating the file fails when the name is taken, so two shares never overwrite.
                try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                number += 1
            }
        }
    }

    /// A file name from the first heading, or else the first line. It has no control characters,
    /// no `/` `:` or `\`, and is at most `maxNameLength` characters.
    public static func fileName(for text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let heading = lines.first { $0.hasPrefix("#") }.map { $0.drop { $0 == "#" } }
        var title = String(heading ?? Substring(lines.first ?? ""))
        title = title.unicodeScalars
            .filter { $0.properties.generalCategory != .control && !"/:\\".unicodeScalars.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        title = String(title.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        // A leading dot would hide the file, and a name of dots is not a name.
        title = String(title.drop { $0 == "." })
        return title.isEmpty ? "Shared text" : title
    }

    // MARK: - Reading (the app)

    /// Files that wait to become documents, oldest first.
    public func pending() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "md" }
            .sorted { Self.modified($0) < Self.modified($1) }
    }

    /// The text of `url`, now marked as used. Returns `nil` when the file can't be read.
    public func consume(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let consumed = url.appendingPathExtension(String(Self.consumedSuffix.dropFirst()))
        try? FileManager.default.removeItem(at: consumed)
        do {
            try FileManager.default.moveItem(at: url, to: consumed)
        } catch {
            // Without the rename the same text would come back on every launch.
            return nil
        }
        return text
    }

    /// Removes used files older than a day and unread files older than thirty.
    public func purge(now: Date = Date()) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls {
            let age = now.timeIntervalSince(Self.modified(url))
            let limit = url.lastPathComponent.hasSuffix(Self.consumedSuffix) ? Self.consumedLifetime : Self
                .unreadLifetime
            if age > limit {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
