# Mac App Store: scope and plan

Scoping for [#40](https://github.com/zoharbabin/fen/issues/40). This page says what a sandboxed Mac App Store build needs and what we'd cut. No store build exists yet. Nothing here changes the current build.

## Where we start

| Part | Today (notarized, direct download) |
|---|---|
| App sandbox | Off for `Fen.app`. On for the QuickLook extension (`FenQuickLook/FenQuickLook.entitlements`: sandbox, read-only user-selected files, network client). |
| Entitlements | `macOS/Fen.entitlements` grants only `com.apple.security.cs.allow-jit`. |
| Folder grants | Workspaces keep a security-scoped bookmark next to the path (`Workspace.bookmark`, `FolderBookmark`). The code already starts and stops scoped access. |
| Fen home | `FenHome` is `NSHomeDirectory()/.fen`. In a sandbox that is the app container, so the layout is the same. |
| Network | `URLSession` only in `Shared/AI/`, GeoJSON maps, `GitHubAPI`, and the update check. |
| Git | `GitTool` starts the `git` program with `Process()`. It returns `nil` on iOS. |
| MCP | `MCPServer` listens on `127.0.0.1` with `NWListener`. |
| Updates | The **Check for Updates…** command ([#39](https://github.com/zoharbabin/fen/issues/39)). |

## What a sandboxed build changes

| Area | Impact | Plan |
|---|---|---|
| Folder access | The sandbox only allows folders you pick. Workspaces already work this way on iOS. | Add `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`. Check that `WorkspaceRegistry` resumes scoped access at launch and that indexing and the FSEvents watcher still see changes. |
| Fen home | `~/.fen` moves to `~/Library/Containers/<bundle id>/Data/.fen`. | No code change expected. Add a test that runs the library against a home in a temp container. Decide how a user finds the folder, since Finder hides it. |
| Git and GitHub sync | The sandbox is expected to block the `git` program. Test it before trusting this. | Ship the store flavor without git: `GitTool.locate()` returns `nil`, as on iOS. Hide the sync, version and agent-branch features. Doing git without a program (libgit2) is a separate, large project. |
| MCP server | A listener needs `com.apple.security.network.server`. | Add the entitlement only if we keep MCP in the store flavor. It is off by default. Review it with the same care as the other entitlements. |
| Network client | Needed for AI providers, model download and maps. | Add `com.apple.security.network.client`. |
| Local models | A model download is large and starts only when you ask. Models live in `~/.fen/models`, inside the container. | Check App Review rules on downloaded executable content. Weights are data, not code, but confirm before submission. Keep the download user-started and show its size. |
| JIT | `allow-jit` is in the current build. | Find out why it is there. Build the store flavor without it and test the preview, Mermaid and MathJax. Drop it if nothing breaks. |
| Update check | The store updates the app. | Compile **Check for Updates…** out of the store flavor. |
| Keychain | Provider keys use the Keychain. | Works in a sandbox. Check the access group. |

## Build flow

1. Add a second app target (or build setting) with its own entitlements file, bundle identifier and a compile flag, for example `APPSTORE`.
2. Under that flag: no `GitTool`, no update command, no sync UI.
3. Sign with an App Store distribution certificate and a provisioning profile. Upload with `xcrun altool` or Transporter from a separate workflow. Never reuse the notarization secrets.
4. Keep the direct-download build as it is. `release.yml` doesn't change.

## What we can't confirm from here

- App Review's view on a user-started model download and on the local MCP server.
- Whether the sandbox lets `git` run for a granted folder.
- Whether `allow-jit` is needed.
- The App Store Connect account, certificates and review. Those need the owner.

## Next step

Do the first row of the table in a branch: turn the sandbox on for a debug build, grant a folder, and see what breaks. That answers most of the open questions with a real run.
