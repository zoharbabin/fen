@testable import FenCore
import Foundation
import Testing

/// Issue #43: the folder the share extension writes to and Fen reads from.
struct SharedTextInboxTests {
    private func inbox() throws -> (SharedTextInbox, TempFolder) {
        let folder = try TempFolder("inbox")
        return (SharedTextInbox(directory: folder.root.appendingPathComponent("Inbox")), folder)
    }

    @Test("the name comes from the first heading, or else the first line")
    func names() {
        #expect(SharedTextInbox.fileName(for: "intro\n\n## The Plan\nbody") == "The Plan")
        #expect(SharedTextInbox.fileName(for: "Just a line\nmore") == "Just a line")
        #expect(SharedTextInbox.fileName(for: "\n\n  \n") == "Shared text")
    }

    @Test("a shared page, written as a Markdown link, is named after its title")
    func linkNames() {
        #expect(SharedTextInbox.fileName(for: "[Example Domain](https://example.com/)\n") == "Example Domain")
        // Only a line that is nothing but a link is renamed.
        #expect(SharedTextInbox.fileName(for: "See [a](b) here") == "See [a](b) here")
    }

    @Test("a name has no slash, colon, backslash, control character, or leading dot, and is cut to 80")
    func cleanNames() {
        #expect(SharedTextInbox.fileName(for: "# a/b:c\\d\u{7}e") == "abcde")
        #expect(SharedTextInbox.fileName(for: "# ../../etc") == "etc")
        #expect(SharedTextInbox.fileName(for: "# ...") == "Shared text")
        #expect(SharedTextInbox.fileName(for: "# " + String(repeating: "x", count: 200)).count == 80)
        #expect(SharedTextInbox.fileName(for: "#   many    spaces   here") == "many spaces here")
    }

    @Test("sharing twice with the same title gives two files")
    func collisions() throws {
        let (inbox, folder) = try inbox()
        defer { folder.cleanUp() }
        let first = try #require(try inbox.add("# Note\none"))
        let second = try #require(try inbox.add("# Note\ntwo"))
        let third = try #require(try inbox.add("# Note\nthree"))
        #expect([first, second, third].map(\.lastPathComponent) == ["Note.md", "Note 2.md", "Note 3.md"])
        #expect(try String(contentsOf: first, encoding: .utf8) == "# Note\none\n")
        #expect(try String(contentsOf: second, encoding: .utf8) == "# Note\ntwo\n")
    }

    @Test("text with nothing in it, or over the cap, writes no file and does not crash")
    func dropped() throws {
        let (inbox, folder) = try inbox()
        defer { folder.cleanUp() }
        #expect(try inbox.add(nil) == nil)
        #expect(try inbox.add(" \n\t ") == nil)
        #expect(throws: SharedTextImport.Failure.tooLarge) {
            try inbox.add(String(repeating: "a", count: SharedTextImport.maxBytes + 10))
        }
        #expect(inbox.pending().isEmpty)
    }

    @Test("text is cleaned the way a clipboard import is")
    func cleaned() throws {
        let (inbox, folder) = try inbox()
        defer { folder.cleanUp() }
        let url = try #require(try inbox.add("\r\nHello\r\nWorld\u{0}\r\n\r\n"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "Hello\nWorld\n")
    }

    @Test("pending lists unread files oldest first, and consuming one hides it but keeps the text")
    func consuming() throws {
        let (inbox, folder) = try inbox()
        defer { folder.cleanUp() }
        let older = try #require(try inbox.add("# Older\na"))
        let newer = try #require(try inbox.add("# Newer\nb"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: older.path
        )
        #expect(inbox.pending().map(\.lastPathComponent) == ["Older.md", "Newer.md"])
        #expect(inbox.consume(older) == "# Older\na\n")
        #expect(inbox.pending().map(\.lastPathComponent) == ["Newer.md"])
        #expect(FileManager.default.fileExists(atPath: older.appendingPathExtension("consumed").path))
        #expect(inbox.consume(older) == nil)
        _ = newer
    }

    @Test("purge removes used files after a day and unread files after thirty days, and nothing sooner")
    func purging() throws {
        let (inbox, folder) = try inbox()
        defer { folder.cleanUp() }
        let used = try #require(try inbox.add("# Used\na"))
        let oldUnread = try #require(try inbox.add("# Old\nb"))
        let freshUnread = try #require(try inbox.add("# Fresh\nc"))
        _ = inbox.consume(used)
        let usedURL = used.appendingPathExtension("consumed")
        let now = Date()
        func age(_ url: URL, days: Double) throws {
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-days * 86400)],
                ofItemAtPath: url.path
            )
        }
        try age(usedURL, days: 0.5)
        try age(oldUnread, days: 31)
        try age(freshUnread, days: 29)
        inbox.purge(now: now)
        #expect(FileManager.default.fileExists(atPath: usedURL.path))
        #expect(!FileManager.default.fileExists(atPath: oldUnread.path))
        #expect(FileManager.default.fileExists(atPath: freshUnread.path))
        try age(usedURL, days: 1.5)
        inbox.purge(now: now)
        #expect(!FileManager.default.fileExists(atPath: usedURL.path))
    }

    @Test("importing moves every waiting item into the folder as a note, and marks each one used")
    func importsIntoAFolder() throws {
        let (inbox, folder) = try inbox()
        defer { folder.cleanUp() }
        try inbox.add("# One\nfirst")
        try inbox.add("# Two\nsecond")
        let notes = folder.root.appendingPathComponent("Notes")
        let made = inbox.importAll(into: notes)
        #expect(Set(made.map(\.lastPathComponent)) == ["One.md", "Two.md"])
        #expect(try String(contentsOf: notes.appendingPathComponent("One.md"), encoding: .utf8) == "# One\nfirst\n")
        #expect(inbox.pending().isEmpty)
        #expect(inbox.importAll(into: notes).isEmpty)
    }

    @Test("importing never overwrites a note that is already in the folder")
    func importKeepsExistingNotes() throws {
        let (inbox, folder) = try inbox()
        defer { folder.cleanUp() }
        let notes = folder.root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "mine".write(to: notes.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        try inbox.add("# Note\nshared")
        let made = inbox.importAll(into: notes)
        #expect(made.map(\.lastPathComponent) == ["Note 2.md"])
        #expect(try String(contentsOf: notes.appendingPathComponent("Note.md"), encoding: .utf8) == "mine")
    }
}
