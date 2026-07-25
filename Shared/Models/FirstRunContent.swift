import Foundation

/// Decides whether a newly created document should be Fen's bundled welcome document instead
/// of blank (issue #37). Stateless itself -- all state lives on the `Preferences` instance
/// passed in, so two calls with two different `Preferences` instances never interfere with
/// each other (rule 1.1).
public enum FirstRunContent {
    /// Returns the bundled welcome document's text exactly once per `Preferences` instance --
    /// the first call after `preferences.hasCompletedFirstRun` is `false` flips it to `true` and
    /// returns the welcome text; every call after that (and every call on an instance that
    /// already completed first run) returns `nil`, meaning "create a blank document instead."
    public static func welcomeDocumentText(preferences: Preferences) -> String? {
        guard !preferences.hasCompletedFirstRun else { return nil }
        preferences.hasCompletedFirstRun = true
        guard let url = coreBundle.url(forResource: "Welcome", withExtension: "md", subdirectory: "Templates"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
