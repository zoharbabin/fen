import AppKit
@testable import FenCore
import Foundation
import Testing

/// Issue #102: the Vim Normal/Insert subset. Motions are pure caret math. The key tests send real key events.
struct VimMotionTests {
    private func caret(_ command: VimCommand, _ text: String, from start: Int) -> Int? {
        VimMotion.location(for: command, in: text as NSString, from: start)
    }

    @Test("Keys map to commands, and an unknown key does nothing")
    func keyMap() {
        #expect(VimCommand.command(for: "h", afterG: false) == .left)
        #expect(VimCommand.command(for: "w", afterG: false) == .wordForward)
        #expect(VimCommand.command(for: "A", afterG: false) == .insert(.lineEnd))
        #expect(VimCommand.command(for: "x", afterG: false) == .ignore)
        #expect(VimCommand.command(for: "g", afterG: false) == .pendingG)
        #expect(VimCommand.command(for: "g", afterG: true) == .documentStart)
        #expect(VimCommand.command(for: "j", afterG: true) == .ignore)
    }

    @Test("h and l stay on their line, and l stops on the last character")
    func leftRight() {
        let text = "ab\ncd"
        #expect(caret(.left, text, from: 3) == 3)
        #expect(caret(.left, text, from: 1) == 0)
        #expect(caret(.right, text, from: 0) == 1)
        #expect(caret(.right, text, from: 1) == 1)
        #expect(caret(.right, text, from: 4) == 4)
    }

    @Test("w and b follow words, punctuation and line breaks")
    func words() {
        let text = "foo bar.baz\nqux"
        #expect(caret(.wordForward, text, from: 0) == 4)
        #expect(caret(.wordForward, text, from: 4) == 7)
        #expect(caret(.wordForward, text, from: 7) == 8)
        #expect(caret(.wordForward, text, from: 8) == 12)
        #expect(caret(.wordForward, text, from: 14) == 14)
        #expect(caret(.wordBack, text, from: 8) == 7)
        #expect(caret(.wordBack, text, from: 7) == 4)
        #expect(caret(.wordBack, text, from: 12) == 8)
        #expect(caret(.wordBack, text, from: 0) == 0)
    }

    @Test("0, $, gg and G")
    func lineAndDocument() {
        let text = "one\ntwo\n"
        #expect(caret(.lineStart, text, from: 6) == 4)
        #expect(caret(.lineEnd, text, from: 4) == 6)
        #expect(caret(.documentStart, text, from: 6) == 0)
        #expect(caret(.documentEnd, text, from: 0) == 4)
        #expect(caret(.lineEnd, "", from: 0) == 0)
        #expect(caret(.documentEnd, "", from: 0) == 0)
    }

    @Test("Insert places: i, a, I and A")
    func insertPlaces() {
        let text = "  ab\ncd"
        #expect(caret(.insert(.here), text, from: 3) == 3)
        #expect(caret(.insert(.afterCaret), text, from: 3) == 4)
        #expect(caret(.insert(.afterCaret), text, from: 4) == 4)
        #expect(caret(.insert(.lineStart), text, from: 3) == 0)
        #expect(caret(.insert(.lineEnd), text, from: 3) == 4)
    }

    @Test("Leaving Insert mode steps back one character, but not off the line start")
    func leaving() {
        #expect(VimMotion.locationAfterLeavingInsert(in: "ab\ncd" as NSString, from: 2) == 1)
        #expect(VimMotion.locationAfterLeavingInsert(in: "ab\ncd" as NSString, from: 3) == 3)
    }

    @Test("A caret after the last character moves back onto it")
    func resting() {
        #expect(VimMotion.resting(in: "ab\ncd" as NSString, at: 2) == 1)
        #expect(VimMotion.resting(in: "ab\n\ncd" as NSString, at: 3) == 3)
    }
}

struct VimKeyTests {
    @MainActor
    private func editor(_ text: String, enabled: Bool = true) -> MarkdownNSTextView {
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        let layoutManager = NSLayoutManager()
        let storage = NSTextStorage(string: text)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let view = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.isVimEnabled = { enabled }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        return view
    }

    private func key(
        _ characters: String,
        _ modifiers: NSEvent.ModifierFlags = [],
        keyCode: UInt16 = 0
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @Test @MainActor
    func normalModeMovesAndNeverTypes() throws {
        let view = editor("hello world\nsecond")
        for typed in ["l", "l", "w", "x", "q"] {
            #expect(try view.handleVimKey(key(typed)))
        }
        #expect(view.string == "hello world\nsecond")
        #expect(view.selectedRange().location == 6)
        #expect(try view.handleVimKey(key("$")))
        #expect(view.selectedRange().location == 10)
        #expect(try view.handleVimKey(key("g")))
        #expect(try view.handleVimKey(key("g")))
        #expect(view.selectedRange().location == 0)
        #expect(try view.handleVimKey(key("G")))
        #expect(view.selectedRange().location == 12)
    }

    @Test @MainActor
    func downAndUpLandOnACharacter() throws {
        let view = editor("long line\nab\nlong line")
        view.setSelectedRange(NSRange(location: 8, length: 0))
        #expect(try view.handleVimKey(key("j")))
        #expect(view.selectedRange().location == 11)
        #expect(try view.handleVimKey(key("k")))
        #expect(view.string == "long line\nab\nlong line")
    }

    @Test @MainActor
    func iStartsInsertModeAndAKeyIsThenLeftToAppKit() throws {
        let view = editor("abc")
        #expect(try view.handleVimKey(key("a")))
        #expect(view.vimMode == .insert)
        #expect(view.selectedRange().location == 1)
        #expect(try !view.handleVimKey(key("x")))
        #expect(view.string == "abc")
    }

    @Test @MainActor
    func escapeLeavesInsertModeThroughTheCoordinator() {
        let view = editor("abc")
        view.vimMode = .insert
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let parent = MarkdownTextView(
            text: .constant("abc"),
            font: .monospacedSystemFont(ofSize: 14, weight: .regular),
            highlightThemeName: "xcode",
            lineSpacing: 0,
            horizontalInset: 0,
            verticalInset: 0,
            isEditable: true,
            scrollsPastEnd: false
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = view
        #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(view.vimMode == .normal)
        #expect(view.selectedRange().location == 1)
        #expect(!coordinator.textView(view, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    }

    @Test @MainActor
    func commandShortcutsArrowsAndOptionKeysAreNotSwallowedOrTyped() throws {
        let view = editor("abc")
        #expect(try !view.handleVimKey(key("c", .command)))
        #expect(try !view.handleVimKey(key("\u{F702}")))
        #expect(try view.handleVimKey(key("å", .option)))
        #expect(view.string == "abc")
    }

    @Test @MainActor
    func aNonLatinLayoutUsesThePhysicalKey() throws {
        let view = editor("ab\ncd\nef")
        // Hebrew layout: physical j, k and Shift+G type no ASCII.
        #expect(try view.handleVimKey(key("\u{05D7}", keyCode: 38)))
        #expect(view.selectedRange().location == 3)
        #expect(try view.handleVimKey(key("\u{05DC}", keyCode: 40)))
        #expect(view.selectedRange().location == 0)
        #expect(try view.handleVimKey(key("\u{05E2}", .shift, keyCode: 5)))
        #expect(view.selectedRange().location == 6)
        #expect(view.string == "ab\ncd\nef")
    }

    @Test
    func physicalKeysMatchTheUSLayout() {
        #expect(VimCommand.asciiCharacters(forKeyCode: 4, shift: false) == "h")
        #expect(VimCommand.asciiCharacters(forKeyCode: 5, shift: true) == "G")
        #expect(VimCommand.asciiCharacters(forKeyCode: 21, shift: true) == "$")
        #expect(VimCommand.asciiCharacters(forKeyCode: 6, shift: false) == "")
    }

    @Test @MainActor
    func controlKeysAndForwardDeleteDoNotEditInNormalMode() throws {
        let view = editor("abc")
        // Ctrl-K and Ctrl-D are Emacs bindings in AppKit that would delete text. Forward Delete too.
        #expect(try view.handleVimKey(key("\u{0B}", .control)))
        #expect(try view.handleVimKey(key("\u{04}", .control)))
        #expect(try view.handleVimKey(key("\u{F728}")))
        #expect(view.string == "abc")
    }

    @Test @MainActor
    func offByDefaultEveryKeyIsLeftToAppKit() throws {
        let view = editor("abc", enabled: false)
        view.vimMode = .insert
        #expect(try !view.handleVimKey(key("l")))
        #expect(view.vimMode == .normal)
        #expect(view.selectedRange().location == 0)
    }

    @Test @MainActor
    func theCaretIsABlockOverTheCharacterInNormalMode() {
        let view = editor("abc")
        #expect(view.vimCaretWidth > 1)
    }

    @Test
    func preferenceIsOffByDefaultAndPersists() throws {
        let suite = "test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Preferences(defaults: defaults)
        #expect(!first.editorVimMode)
        first.editorVimMode = true
        #expect(Preferences(defaults: defaults).editorVimMode)
    }
}
