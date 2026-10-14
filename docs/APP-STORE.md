# Mac App Store build

Part of [#40](https://github.com/zoharbabin/fen/issues/40). The store build is a second Xcode target, `FenMacOSAppStore` in `project.yml`. It shares all sources with the direct-download app. The notarized build and `release.yml` don't change.

## What differs

| | Direct download (`FenMacOSApp`) | Store build (`FenMacOSAppStore`) |
|---|---|---|
| Sandbox | Off | On |
| Entitlements | `macOS/Fen.entitlements`: `allow-jit` | `macOS/FenAppStore.entitlements`: sandbox, user-selected read-write files, app-scope bookmarks, network client |
| `Info.plist` | `macOS/Info.plist` | `macOS/Info-AppStore.plist`: no Sparkle keys, adds the category and the encryption answer |
| Updates | Sparkle, and the release-page fallback | None. The `APPSTORE` flag removes `AppUpdater` and the **Check for Updates…** command. The target doesn't link Sparkle. |
| Git (GitHub sync, agent branches, conflict checks) | Uses the system `git` | Off. `GitTool.locate()` returns `nil` when `APP_SANDBOX_CONTAINER_ID` is set, so the UI hides clone and sync. iOS has its own GitHub copy that uses the API ([ARCHITECTURE.md](ARCHITECTURE.md#github-sync-clone-pull-and-push-with-the-git-you-have-a-scoped-token-in-the-keychain)). |
| Fen home | `~/.fen` | `~/Library/Containers/com.zoharbabin.fen/Data/.fen` |
| MCP server | Works | Off. The sandbox has no `network.server` entitlement and we don't add it, so Settings has no Agents tab (`AppSandbox.isActive()`). |

## What we ran

All on one Mac, with an ad hoc signed build (no Apple account needed).

| Question | Answer | How we know |
|---|---|---|
| Does `git` run in the sandbox? | `/usr/bin/git` fails (`xcrun: error: cannot be used within an App Sandbox`). The Xcode copy runs, but only on a Mac with Xcode. We turn git off. | A small sandboxed probe that starts each `git` |
| Is `allow-jit` needed? | No. The store target has no JIT entitlement and no hardened runtime. | `scripts/test-appstore-sandbox.sh`: the editor, the preview and the workspace flows all work. We didn't test every Mermaid and MathJax diagram. |
| Do folder grants, indexing, search and backlinks work? | Yes. | The `WorkspaceControlsUITests` pass against the sandboxed build |
| Does a workspace survive a relaunch? | Yes. The saved bookmark resumes. | `testWorkspaceKeepsWorkingAfterRelaunch` |
| Is the sandbox set up for the data folder? | Yes. `.fen` is inside the container. | Listed the container after a run |

Run it yourself: `scripts/test-appstore-sandbox.sh`. It sets your container's `.fen` aside and puts it back.

## Before you submit

These need the owner's Apple Developer account. Everything else is in the repo.

| Step | Where |
|---|---|
| Register the App ID `com.zoharbabin.fen` with App Sandbox, and `com.zoharbabin.fen.quicklook`. The team is `CG9APRC4WT` in `project.yml`. | Apple Developer portal, Identifiers |
| Create an "Apple Distribution" certificate and a Mac App Store provisioning profile for each ID. | Portal, or Xcode > Settings > Accounts |
| Create the app record in App Store Connect with that bundle ID. | App Store Connect |
| Archive: `xcodebuild archive -scheme FenMacOSAppStore -project FenUITesting.xcodeproj -destination 'platform=macOS' -archivePath build/Fen.xcarchive`. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` first. Each upload needs a higher build number. | Your Mac |
| Upload with Xcode Organizer or Transporter. | Your Mac |
| Never reuse the notarization secrets. Keep store credentials out of the repo. | |

## Store listing

| Field | Value |
|---|---|
| Name | Fen |
| Category | Productivity (set in `Info-AppStore.plist`) |
| Privacy policy URL | `https://fen.md/privacy.html` (`site/privacy.html`) |
| Support URL | `https://github.com/zoharbabin/fen/issues` |
| Marketing URL | `https://fen.md` |
| Price | Free |
| Age rating | Answer the questionnaire in App Store Connect. Fen has no built-in content and no web browsing. |
| App privacy ("nutrition label") | Data not collected. The app has no analytics and no server. See the policy page for the connections you start yourself. |
| Export compliance | `ITSAppUsesNonExemptEncryption` is `false`. Fen only uses the encryption built into the system (HTTPS, Keychain). |
| Privacy manifest | `macOS/PrivacyInfo.xcprivacy`: no tracking, no collected data, the `UserDefaults` and file timestamp reasons |
| Screenshots and icon | Made by `scripts/make-store-screenshots.sh` and listed in [APP-STORE-LISTING.md](APP-STORE-LISTING.md), together with the description, keywords and review notes |

Suggested review note: "Fen is a local-first Markdown editor. It reads and writes only files and folders you grant. The only network use is an AI provider address you enter yourself and, if you enable it, map tiles. No account is needed."

## Open questions only App Review can answer

- Whether the user-added AI provider setting, including a local Ollama address, passes review as is.

## Not done

- No archive or upload has been made. That needs the account steps above.
- We didn't test the store build on an iPhone or iPad. The iOS app is a separate target. Its App Store path needs the same account steps, plus the App Group for the share extension ([IOS-SHARE-EXTENSION.md](IOS-SHARE-EXTENSION.md)).
- Xcode builds of the Mac app don't bundle `DocumentIcon.icns`. Only `scripts/build-app.sh` makes it, so `.md` files show a generic icon in the store build.
- Sandbox denials in the system log weren't reviewed beyond the passing tests.
