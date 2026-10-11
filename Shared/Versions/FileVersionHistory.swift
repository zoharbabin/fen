import Foundation

/// One earlier version of a file that the system keeps (issue #59).
///
/// On macOS the system makes these for you each time a document saves. There is no way to add one
/// from code on iOS: only iCloud puts versions there.
public struct FileVersion: Identifiable, @unchecked Sendable {
    public let id: String
    public let date: Date?
    /// The name of the device that saved it, when the system knows it.
    public let device: String?
    /// `false` for a version that lives in iCloud and is not on this device yet. Reading it downloads it.
    public let isLocal: Bool
    fileprivate let version: NSFileVersion

    init(_ version: NSFileVersion) {
        self.version = version
        date = version.modificationDate
        device = version.localizedNameOfSavingComputer
        isLocal = version.hasLocalContents
        id = "\(version.persistentIdentifier)-\(date?.timeIntervalSince1970 ?? 0)"
    }
}

/// Reads the versions the system keeps of a file, newest first. It never writes a version, and it
/// never changes the file.
public enum FileVersionHistory {
    /// The earlier versions of the file at `url`, not the one it has now.
    public static func versions(of url: URL) async -> [FileVersion] {
        let local = NSFileVersion.otherVersionsOfItem(at: url) ?? []
        let remote: [FileVersion] = await withCheckedContinuation { continuation in
            NSFileVersion.getNonlocalVersionsOfItem(at: url) { versions, _ in
                continuation.resume(returning: (versions ?? []).map(FileVersion.init))
            }
        }
        var seen = Set<String>()
        return (local.map(FileVersion.init) + remote)
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// The text of a version. A version in iCloud is downloaded first, so this can take a while.
    public static func text(of version: FileVersion) async throws -> String {
        let url = version.version.url
        return try await Task.detached {
            var coordinationError: NSError?
            var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                result = Result {
                    let data = try Data(contentsOf: readable)
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw CocoaError(.fileReadInapplicableStringEncoding)
                    }
                    return text
                }
            }
            if let coordinationError {
                throw coordinationError
            }
            return try result.get()
        }.value
    }
}
