# iOS Share Extension: scope and plan

Follow-up to [#43](https://github.com/zoharbabin/fen/issues/43). Today you copy text in another app and tap **New from Clipboard** in Fen ([how it works](ARCHITECTURE.md#share-sheet-files-in-place-a-md-file-out)). A Share Extension would add Fen to the share sheet, so the text arrives without a copy step. Nothing here is built yet.

## Why it isn't built

An extension is a second process. It can't write into Fen's documents or container, so it needs an App Group shared with the app. `project.yml` has no team, no iOS entitlements file, and no iOS distribution workflow, so a signed build with an App Group can't exist until the owner sets that up.

## What the owner must provision

| Step | Where |
|---|---|
| Pick the Apple Developer team and set `DEVELOPMENT_TEAM` on the iOS targets. | `project.yml` |
| Register the App Group, for example `group.com.zoharbabin.fen`. | Apple Developer portal, Identifiers |
| Register the extension's App ID, `com.zoharbabin.fen-ios.share`, and turn on App Groups for it and for `com.zoharbabin.fen-ios`. | Apple Developer portal, Identifiers |
| Create provisioning profiles for both IDs. Automatic signing does this once the team is set. | Xcode or the portal |
| Decide how the iOS app is distributed (TestFlight, App Store). Without that, no user gets the extension. | `docs/RELEASING.md`, a new workflow |

## What we add after that

1. `iOS/Fen.entitlements` and `FenShare/FenShare.entitlements`, each with `com.apple.security.application-groups` set to the group. Nothing else.
2. A `FenShare` target of type `app-extension` in `project.yml`, embedded in `FeniOSApp`. Its `Info.plist` activates for text and web URLs only: `NSExtensionActivationSupportsText` and `NSExtensionActivationSupportsWebURLWithMaxCount` set to 1. No file or image rule.
3. The extension reads the shared text, runs it through `SharedTextImport.text(from:)` (already shipped, with a size cap), and writes a `.md` file into `<group container>/Inbox/`. It makes no network call and doesn't open the app's documents.
4. A pure `SharedTextInbox` type in `Shared/` with tests. It owns the file name (from the first heading or first line, with control characters and `/ : \` removed, cut to 80 characters), a collision-safe name (`Title.md`, `Title 2.md`, ...), and an age limit on unread files.
5. On launch and when the app becomes active, Fen lists the inbox, makes one new document per file, and deletes each file only after the document is saved. Do this one file at a time, so a crash leaves the rest in place.

## Checks before it ships

- Run on a device with a signed build, not only in the simulator.
- A shared selection from Safari, Notes and Mail each becomes one document.
- Sharing twice with the same title gives two files.
- An inbox file over the cap, or with no text, is dropped without a crash.
- `grep -r "URLSession" Shared macOS iOS FenShare` shows no new match.
