# Mac App Store build

Part of [#40](https://github.com/zoharbabin/fen/issues/40). The store build is a second Xcode target, `FenMacOSAppStore` in `project.yml`. It shares all sources with the direct-download app. The notarized build and `release.yml` don't change.

## What differs

| | Direct download (`FenMacOSApp`) | Store build (`FenMacOSAppStore`) |
|---|---|---|
| Sandbox | Off | On |
| Entitlements | `macOS/Fen.entitlements`: `allow-jit` | `macOS/FenAppStore.entitlements`: sandbox, user-selected read-write files, app-scope bookmarks, network client |
| `Info.plist` | `macOS/Info.plist` | `macOS/Info-AppStore.plist`: no Sparkle keys, adds the category and the encryption answer |
| Updates | Sparkle, and the release-page fallback | None. The `APPSTORE` flag removes `AppUpdater` and the **Check for Updates…** command. The target doesn't link Sparkle. |
| Git (GitHub sync, agent branches, the git diff in conflict checks) | Uses the system `git` | Off. `GitTool.locate()` returns `nil` when `APP_SANDBOX_CONTAINER_ID` is set, so the UI hides clone and sync. Conflict checks fall back to content hashes. iOS has its own GitHub copy that uses the API ([ARCHITECTURE.md](ARCHITECTURE.md#github-sync-clone-pull-and-push-with-the-git-you-have-a-scoped-token-in-the-keychain)). |
| Fen home | `~/.fen` | `~/Library/Containers/com.zoharbabin.fen/Data/.fen` |
| MCP server | Works | Off. The sandbox has no `network.server` entitlement and we don't add it, so Settings has no Agents tab (`AppSandbox.isActive()`). |

## What we ran

All on one Mac, with an ad hoc signed build (no Apple account needed).

| Question | Answer | How we know |
|---|---|---|
| Does `git` run in the sandbox? | `/usr/bin/git` fails (`xcrun: error: cannot be used within an App Sandbox`). The Xcode copy runs, but only on a Mac with Xcode. We turn git off. | A small sandboxed probe that starts each `git` |
| Is `allow-jit` needed? | No. The store target has no JIT entitlement and no hardened runtime. | `scripts/test-appstore-sandbox.sh`: the editor, the preview and the workspace flows all work. We didn't try every Mermaid and MathJax diagram. |
| Do folder grants, indexing, search and backlinks work? | Yes. | The `WorkspaceControlsUITests` pass against the sandboxed build |
| Does a workspace survive a relaunch? | Yes. The saved bookmark resumes. | `testWorkspaceKeepsWorkingAfterRelaunch` |
| Is the sandbox set up for the data folder? | Yes. `.fen` is inside the container. | Listed the container after a run |

Run it yourself: `scripts/test-appstore-sandbox.sh`. It sets your container's `.fen` aside and puts it back.

## Before you submit

These steps need the owner's Apple Developer account. Never reuse the notarization secrets, and keep store credentials out of the repo.

| Step | How |
|---|---|
| Register the App IDs `com.zoharbabin.fen` (App Sandbox) and `com.zoharbabin.fen.quicklook` | Xcode does it when you archive with `-allowProvisioningUpdates`. The team is in `project.yml`. |
| Create the store certificates and a Mac App Store provisioning profile for each ID | Xcode does it on export. |
| Create the app record in App Store Connect | Use the bundle ID `com.zoharbabin.fen`. The iOS app shares it, so Mac, iPhone and iPad sit in one record. Fill in the listing from [APP-STORE-LISTING.md](APP-STORE-LISTING.md). |
| Archive | `xcodebuild archive -scheme FenMacOSAppStore -project FenUITesting.xcodeproj -destination 'platform=macOS' -archivePath build/Fen.xcarchive -allowProvisioningUpdates`. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` first. Each upload needs a higher build number. |
| Export and upload | `xcodebuild -exportArchive -exportOptionsPlist <plist> -allowProvisioningUpdates` with `method` `app-store-connect`, `signingStyle` `automatic` and `destination` `upload` (or `export` for a `.pkg` you send with Transporter). It uses the Apple account signed in to Xcode. |
| iOS build | Same steps with the `FeniOSApp` scheme and `-destination 'generic/platform=iOS'`. It also needs the App Group for the share extension ([IOS-SHARE-EXTENSION.md](IOS-SHARE-EXTENSION.md#signing)). |

## Listing and questionnaires

The name, text, URLs, review note, questionnaire answers, screenshots and icon are in [APP-STORE-LISTING.md](APP-STORE-LISTING.md). The build carries three things the store checks:

| File | Content |
|---|---|
| `macOS/Info-AppStore.plist` | The Productivity category and `ITSAppUsesNonExemptEncryption` set to `false` |
| `macOS/PrivacyInfo.xcprivacy` | No tracking, no collected data, and the `UserDefaults` and file timestamp reasons |
| `site/privacy.html` | The privacy policy at `https://fen.md/privacy.html` |

## Known gaps

- Xcode builds of the Mac app don't bundle `DocumentIcon.icns`. Only `scripts/build-app.sh` makes it, so `.md` files show a generic icon in the store build.
- Nobody has run the store build on an iPhone or iPad. The iOS app is a separate target.
- We checked the sandbox with the passing tests only. We didn't review sandbox denials in the system log.
