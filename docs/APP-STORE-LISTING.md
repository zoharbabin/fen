# App Store listing

Part of [#40](https://github.com/zoharbabin/fen/issues/40). Paste these into App Store Connect. The build side is in [APP-STORE.md](APP-STORE.md).

The Mac and iOS records use the same text. Only the description differs, as noted under it.

## Text

| Field | Limit | Value |
|---|---|---|
| Name | 30 | Fen.md ("Fen" is taken in the store) |
| Subtitle | 30 | Markdown notes that connect |
| Promotional text | 170 | Write in Markdown. Link notes, search by meaning, ask questions and get answers with sources. Plain .md files, AI on your terms, no account. Free, open source. |
| Keywords | 100 | markdown,notes,editor,writing,preview,mermaid,latex,obsidian,knowledge,wiki,local,private,search |
| Category | | Productivity |
| Secondary category | | Developer Tools |
| Copyright | | 2026 Zohar Babin |
| Version "What's New" | 4000 | First release in the App Store. |

### Description

The iOS record uses this text.

```text
Fen is a native Markdown editor that turns a folder of plain files into a knowledge base you can search, question and trust. Your notes stay .md files you own. No import, no vault, no lock-in.

WRITE
• Edit on one side, see the result on the other. Both sides scroll together.
• Live Preview (experimental) hides the Markdown marks as you type and draws tables, formulas and diagrams in place.
• GitHub-style Markdown: tables, task lists, footnotes, callouts, highlights and emoji.
• Math with MathJax, diagrams with Mermaid, maps from GeoJSON, 3D models from STL, and syntax highlighting.
• Slash commands, an outline sidebar, focus mode and a formatting toolbar.
• Paste or drop an image and Fen saves it next to your note.
• Export to HTML or PDF, and print.

CONNECT
• Link notes with [[wiki links]] and see every note that links back.
• Add any folder as a workspace. Fen lists and indexes its notes without opening each one.
• Give notes a type, such as Person, Project or Meeting, with properties you define in a plain file.
• Related notes appear while you write.

FIND AND ASK
• Search every workspace at once, by words or by meaning.
• Ask a question and get an answer with links to the notes it came from.
• Conflicts finds notes that now disagree, such as two different deadlines.
• Rewrite a selection or enrich bullets with AI. One Undo brings the old text back.

AI ON YOUR TERMS
• AI is off until you add a provider. Run a local model with Ollama and nothing leaves your device.
• AI never writes to your files by itself. You decide whether each change waits for your approval, and every change can be undone.
• No account, no analytics, no ads, no tracking.

ON EVERY DEVICE
• Mac, iPad and iPhone share one engine, so a note looks the same everywhere.
• Carry notes with iCloud Drive or Files, or copy a GitHub repository and sync it from the app.
• Version history shows earlier versions of a note and restores one.
• iPad supports hardware keyboards and the Mac shortcuts.
• On iPhone, share text from Safari or any app straight into a new note.

Free and open source under the MIT license. Source code and issues: github.com/zoharbabin/fen
```

The Mac record changes four things. It adds the block below before "ON EVERY DEVICE". It adds "and Vim keys" to the slash-commands bullet. It drops the iPad and iPhone bullets. It cuts "or copy a GitHub repository and sync it from the app", because the store build has no git.

```text
FOR THE MAC
• Quick Look shows .md files in Finder.
```

Don't mention MCP or agent branches in the Mac listing. The store build leaves them out ([APP-STORE.md](APP-STORE.md#what-differs)). They ship in the direct download only.

Check the claims before you paste: each line is a feature in the [README](../README.md) or [ARCHITECTURE.md](ARCHITECTURE.md). Change the text when the app changes.

## Review notes

Paste into "Notes" under App Review Information. No sign-in is needed, so leave the demo account empty.

> Fen is a local-first Markdown editor. It reads and writes only the files and folders you grant through the system file picker. No account is needed.
>
> The only network use is what you start yourself: an AI provider address you enter in Settings (for example a local Ollama server), a model file you choose to download in Settings, a GitHub repository you choose to copy, and map tiles if you turn on the map setting. Nothing is sent without that setup.
>
> To try the workspace features, tap Workspaces on the launch screen (iPhone, iPad) or choose File > Workspaces (Mac), then add any folder with `.md` files. Search works at once. Ask needs an AI provider, so it shows setup help until you add one.

## Answers to the questionnaires

| Question | Answer |
|---|---|
| Age rating | 4+. Pick "None" for every content question. Fen has no built-in content, no web browsing, no user-generated content shared between people and no purchases. |
| App privacy | Data Not Collected. See [the policy](../site/privacy.html). |
| Tracking | No |
| Export compliance | Uses only encryption built into the system (HTTPS and Keychain). `ITSAppUsesNonExemptEncryption` is `false` in the plists. |
| Content rights | You own the rights. Fen bundles open-source libraries under their licenses. |
| Advertising identifier | Not used |
| Price | Free, no in-app purchases |
| Availability | All regions |

## URLs

| | URL |
|---|---|
| Support | https://github.com/zoharbabin/fen/issues |
| Marketing | https://fen.md |
| Privacy policy | https://fen.md/privacy.html |

## Screenshots

Generated by `scripts/make-store-screenshots.sh` from `assets/store/sample-workspace`. The finished pictures are in `assets/store/screenshots`.

| Set | Size | Files | Upload to |
|---|---|---|---|
| Mac | 2880 x 1800 | `mac-1` to `mac-5` | Mac App Store, Mac |
| iPhone | 1320 x 2868 | `phone-1` to `phone-5` | iOS App Store, iPhone. The upload page takes 1206 x 2622 here, so resize first: `sips -z 2622 1206 phone-1-preview.png --out <dir>/phone-1-preview.png` |
| iPad 13" | 2064 x 2752 | `pad-1` to `pad-5` | iOS App Store, iPad 13" Display |

App Store Connect scales these down for the smaller device sizes, so these three sets are enough. Run the script again after a visible change. It needs Xcode, xcodegen and a local Ollama with `gemma4` and `embeddinggemma`.

## App icon

| Where | File |
|---|---|
| App Store Connect, 1024 x 1024, no alpha | `assets/store/icon-1024.png` |
| iOS app | `iOS/Assets.xcassets/AppIcon.appiconset` (a copy of the file above) |
| Mac app | `macOS/Assets.xcassets/AppIcon.appiconset` (a copy of `macOS/AppIcon.iconset`) |

Apple rejects an icon with transparency, so the store icon is a full-bleed square and the system rounds the corners. Rebuild it with `swift scripts/make-icon.swift assets/store/icon-1024.png --store`. Without `--store` the script writes the rounded Mac version.
