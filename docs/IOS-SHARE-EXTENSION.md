# iOS Share Extension

Fen is in the iOS share sheet for text and web addresses (issue [#43](https://github.com/zoharbabin/fen/issues/43)). The extension leaves a `.md` file in an App Group folder. Fen moves each file into its Documents folder as a note the next time it opens or comes to the front. Find notes in the document list under **Browse > On My iPhone > Fen**. The older route still works: copy text, tap **New from Clipboard** ([how it works](ARCHITECTURE.md#share-sheet-files-in-place-a-md-file-out)).

## How it works

| Piece | Path | Job |
|---|---|---|
| Extension | `FenShare/ShareViewController.swift` | Reads shared text, or a web address as a Markdown link. Writes one file into the inbox. Makes no network call and never opens Fen's documents. |
| Inbox | `Shared/Models/SharedTextInbox.swift` | Names files from the first heading or line, never overwrites, renames used files to `.consumed`, and purges old ones. The extension compiles this file alone, so it uses no other Fen type. |
| Text cleanup | `Shared/Models/SharedTextImport.swift` | Line endings, control characters, 2 MB cap. Shared with **New from Clipboard**. |
| Import | `SharedNotes` in `iOS/FenApp_iOS.swift`, `SharedTextInbox.importAll(into:)` | Runs at launch and each time the app becomes active. Writes each waiting file to Documents (never overwrites: `Title.md`, `Title 2.md`), then marks it used. A file that fails stays for the next try. |

The group is `group.com.zoharbabin.fen`. Both entitlements files (`iOS/Fen.entitlements`, `FenShare/FenShare.entitlements`) grant that and nothing else.

Fen saves notes itself because on iOS 27 the launch screen's **New Document** button ignores the closure that fills in the new document, so a button that built a document from shared text opened an empty one. A crash between "write the note" and "mark the file used" loses nothing. Used files go after a day, unread files after thirty.

## Checks

| Check | Where it runs |
|---|---|
| `SharedTextInboxTests`, `SharedTextImportTests` (names, collisions, import, consume, purge, size cap) | CI |
| The iOS simulator build in `ci.yml` builds the extension and embeds it | CI |
| `scripts/test-share-inbox.sh [udid]` signs ad hoc, installs, writes a file into the simulator's group folder, opens the note from the document list and checks the text and the `.consumed` rename (`ShareInboxUITests`) | Local |
| `SavedNoteUITests`: on an iPhone, open a saved note from **Browse > On My iPhone > Fen** and check its text (set `TEST_RUNNER_FEN_SAVED_NOTE=1`) | Local, on a device |
| A real share from Safari, Notes and Mail | By hand on a device. Safari is too slow to drive from a UI test. |

The extension must make no network call. `grep -r "URLSession" FenShare Shared/Models` must show nothing.

## Signing

`project.yml` sets `DEVELOPMENT_TEAM` for `FeniOSApp` and `FenShare`. Before the first device or App Store build, register in the Apple Developer portal:

- The App Group `group.com.zoharbabin.fen`.
- App IDs `com.zoharbabin.fen` (shared with the Mac app) and `com.zoharbabin.fen.share`, both with App Groups on.

Automatic signing then makes the profiles. The CI build uses `CODE_SIGNING_ALLOWED=NO`, so it needs none of this. Without the entitlement, `SharedTextInbox.standard` is `nil` and the share-sheet import is off. Nothing else changes.
