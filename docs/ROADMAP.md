# Fen — Roadmap

**North star:** be the app people reach for to write and *think* in Markdown on macOS — clean, fast, and native, that grows into a connected knowledge base instead of a pile of loose files. We take inspiration from Typora, iA Writer, Bear, Obsidian, and the original MacDown, but we stay minimal: speed and clarity over feature sprawl. Fen reads and writes plain `.md` files straight through the filesystem — no proprietary library or vault format — which keeps it iCloud- and Finder-friendly by construction; protect that property as the knowledge suite (section 5) grows.

Status legend: `[ ]` planned · `[~]` partial/started · `[x]` done

This ordering reflects a priority pass grounded in what Markdown-editor users actually ask for and complain about across Reddit (r/macapps, r/iawriter, r/ObsidianMD, r/bearapp, r/Markdown), Hacker News, editor-comparison write-ups, and the GitHub issue trackers of MacDown and comparable open-source editors (Zettlr, MarkText, Joplin) — not just intuition. See the reasoning notes under each moved or added item.

---

## 1. Next up (high value, aligned with the north star)

### Navigation & structure
- [ ] **Document outline / TOC navigator** — jump to headings, fold sections
- [ ] Keyboard shortcut + sidebar/popover UI, driven off the existing Markdown heading parse

  *Promoted from section 2.* A navigable outline or heading-fold view is the single most repeated, longest-standing complaint about iA Writer specifically — multiple independent threads over several years cite its absence, and iA Writer's own founder confirmed it sat off the roadmap for years before finally shipping in iA Writer 8. Fen can close this gap now rather than years late.

### Formatting toolbar
- [ ] Toolbar + menu actions for: bold, italic, strikethrough, inline code, code block, H1–H3, bullet/numbered list, task item, blockquote, link, image, horizontal rule, table
- [ ] Smart toggling (apply/remove around selection; wrap empty selection with placeholder)
- [ ] Reuse/extend the existing `insertMarkdownFormatting` notification path; add the missing actions

### "Default `.md` editor" system integration
- [ ] Verify/strengthen UTI + document-type registration so macOS offers Fen as a handler and it can be **Set as Default** for `.md`/`.markdown`/`.mdown`/`.mkd`
- [ ] A **document icon** for `.md` files in Finder
- [ ] Restore last session / recent documents; sensible new-doc behavior — MacDown's Open Recent list going blank ([#845](https://github.com/MacDownApp/macdown/issues/845), [#1334](https://github.com/MacDownApp/macdown/issues/1334)) shows this is easy to get wrong and annoying when it breaks
- [ ] "Always Open With" / default-handler registration from Finder should stick — MacDown never fixed this ([#175](https://github.com/MacDownApp/macdown/issues/175)); test it explicitly as part of any UTI work
- [ ] (Stretch) Quick Look preview extension for Markdown files

---

## 2. Editing quality (fast, frictionless)
- [ ] Find & Replace — confirm the native find bar works; add replace UX
- [ ] Auto-continue lists + smart renumbering (prefs exist; wire them up)
- [ ] Auto-pair brackets/quotes; wrap selection with pairs (pref exists)
- [ ] Tab/indent handling, convert tabs→spaces (pref exists)
- [ ] Paste/drag-drop images → save to a sidecar folder and insert a link
- [ ] Optional focus/typewriter mode (iA Writer-style), distraction-free toggle
- [ ] **Detect external file changes and offer to reload** — MacDown's [#1230](https://github.com/MacDownApp/macdown/issues/1230) and [#630](https://github.com/MacDownApp/macdown/issues/630) are long-standing open asks for exactly this; without it, editing the same file from another tool (or a sync conflict) silently diverges from what's on disk
- [ ] **Optional line numbers in the editor gutter** — MacDown's [#23](https://github.com/MacDownApp/macdown/issues/23) is its single most-upvoted open issue (53 👍); make it a togglable preference, not default-on, to keep the minimal look
- [ ] Autosave / crash recovery for unsaved changes — recurring ask across MacDown ([#70](https://github.com/MacDownApp/macdown/issues/70)) and MarkText ([#732](https://github.com/marktext/marktext/issues/732), 17 👍)
- [ ] (Considered, not committed) **Vim-style modal keybindings** — MarkText's [#596](https://github.com/marktext/marktext/issues/596) is the single highest-upvoted open issue across every comparable editor surveyed (98 👍), well ahead of anything found for Fen's current roadmap items. Worth an issue to scope cost/approach before committing — a native `NSTextView`/SwiftUI text-editing surface makes full modal editing a real undertaking, not a toggle.

---

## 3. Preview & theming polish
- [ ] **Eliminate preview flicker/flash on typing and scroll** — this is MacDown's all-time top complaint by a wide margin: [#1104](https://github.com/MacDownApp/macdown/issues/1104) (91 👍, 77 comments) and its duplicate [#1057](https://github.com/MacDownApp/macdown/issues/1057) (23 👍) both describe the preview pane flashing/flickering while editing, and [#1256](https://github.com/MacDownApp/macdown/issues/1256) frames it as a genuine photosensitive-epilepsy accessibility risk, not just an annoyance. Fen's debounced re-render should already avoid a full-page reload per keystroke — add a regression test/manual check that confirms no visible flash before shipping preview changes.
- [ ] Dark-mode preview that follows system appearance (and a manual toggle)
- [ ] Tighten scroll-sync accuracy on long/uneven documents
- [ ] Preview style picker polish; allow user custom CSS
- [ ] Per-document front-matter driven options where sensible
- [ ] Rendered preview font-size control — MacDown [#482](https://github.com/MacDownApp/macdown/issues/482) (14 👍)
- [ ] Copy-code-to-clipboard button on rendered code blocks — a small, well-liked win in comparable apps (Joplin [#2383](https://github.com/laurent22/joplin/issues/2383), 49 👍)
- [ ] Check GFM alert/callout syntax (`> [!NOTE]`, `> [!WARNING]`, etc.) renders correctly and is exercised in `assets/demo.md` — repeatedly requested as "admonitions" in Zettlr ([#4982](https://github.com/Zettlr/Zettlr/issues/4982), [#532](https://github.com/Zettlr/Zettlr/issues/532)) and MarkText ([#2115](https://github.com/marktext/marktext/issues/2115))

---

## 4. Export & printing

*Moved down from the former #1 slot.* Real users do ask for this — one Reddit poster lists PDF export as a co-equal requirement alongside FOSS/WYSIWYG/LaTeX support — but it's not the universal must-have the old ordering implied: several "what writers actually care about" checklists and "holy grail" wishlists for this exact app category omit export/PDF entirely, and Typora's own PDF/HTML/DOCX/EPUB/LaTeX export isn't cited anywhere as a competitive strength. Treat this as real, not top-priority, demand — worth building, but after navigation and system integration.

- [ ] **Export to PDF** — render the preview `WKWebView` to paginated PDF (`createPDF`), with page size/margins and a print stylesheet
  - Handle page breaks and content clipping at page boundaries correctly — MacDown never fixed this ([#190](https://github.com/MacDownApp/macdown/issues/190), [#644](https://github.com/MacDownApp/macdown/issues/644)); it's the specific complaint that shows up once PDF export actually ships
  - Don't render YAML front matter as visible text in the PDF ([#171](https://github.com/MacDownApp/macdown/issues/171))
- [ ] **Export to HTML** — wire a UI onto the existing `composeForExport` (self-contained vs. linked assets toggle)
- [ ] **Print** support (`NSPrintOperation` via the web view)
- [ ] **Copy as HTML** / **Copy as Rich Text** to clipboard
- [ ] `fen export` CLI/command-line export path — asked for repeatedly on MacDown ([#202](https://github.com/MacDownApp/macdown/issues/202), 8 👍) for scripting batch conversions; low cost to add once `composeForExport` has a stable HTML/PDF entry point

---

## 5. Knowledge suite (Fen's long game)

This is what sets Fen apart from a single-file editor: your notes stop living as isolated files and become a connected knowledge base.

- [ ] **Multi-file workspace** — open a folder of Markdown files as one project, not one document at a time
- [ ] **Local search & indexing** — fast full-text search across a workspace, built on an on-device index
- [ ] **Ontology / tagging layer** — structured tags and note types that let you query your notes like a lightweight knowledge graph, not just grep
- [ ] **Backlinks & wiki-links** (`[[note-name]]` linking, backlinks panel) — *lower priority than the items above.* Wikilinks/backlinks show up as an expectation specifically when an app is positioned as an "Obsidian alternative" (e.g. a Hacker News commenter flagged their absence in exactly that framing); Fen isn't pitched that way, so this stays useful but optional rather than core.
- [ ] **Graph view** — visualize how notes connect; same positioning caveat as backlinks, and lowest priority in this section.

---

## 6. App polish
- [x] **Icon refinement** — a Fen mark that fits the brand
- [x] About panel with credits (Tzu-ping Chung, Mou) and bundled third-party licenses
- [ ] First-run sample document / light onboarding
- [ ] Settings screen polish and grouping pass

---

## 7. Distribution & ops
- [x] GitHub Actions signing secrets — CI cuts signed and notarized releases on every tag push (see `RELEASING.md`) — this already avoids MacDown's recurring, high-engagement "MacDown is damaged and can't be opened" / "unidentified developer" Gatekeeper complaints ([#1106](https://github.com/MacDownApp/macdown/issues/1106), 20 👍/66 comments; [#1249](https://github.com/MacDownApp/macdown/issues/1249); [#515](https://github.com/MacDownApp/macdown/issues/515)) — keep signing/notarization on every release to keep it that way
- [ ] In-app update check (e.g. Sparkle) for the non-App-Store build
- [ ] (Deferred) Mac App Store — needs a sandboxed second build flavor, revisit later
- [ ] Homebrew Cask — if added, test install/upgrade permissions explicitly; MacDown's Cask had a recurring permission-error report ([#1173](https://github.com/MacDownApp/macdown/issues/1173))
- If Fen ever charges for anything, favor a one-time purchase over a subscription — a vocal segment of this exact audience treats subscriptions as a dealbreaker and one-time pricing as a loyalty driver (see e.g. long-time iA Writer owners citing "never had to repurchase" as a reason they stayed).

---

## 8. iOS / iPadOS
- [ ] iPad-class layout, document browser, keyboard shortcuts
- [ ] Share-sheet import/export

---

## Explicitly out of scope

- **Cloud- or server-backed AI writing/organizing features.** This privacy- and local-first-minded audience skews actively anti-AI, not merely indifferent: Bear's developer publicly declined in-app AI specifically because it would mean "uploading all the user notes to an online server we don't control," and the overwhelming majority of commenters on a thread arguing *for* Bear AI pushed back, several saying they'd cancel if it shipped; Obsidian users describe keeping LLMs out of their vault as central to the tool's value. Given that, an AI-assistance item doesn't belong on this roadmap even as a stretch goal — it reads as a risk to Fen's target audience, not a draw. A fully local, fully opt-in model is a different, untested question and isn't ruled out, but nothing here depends on it.
- **A proprietary storage format or "library"/vault abstraction.** Plain-file, Finder-visible, iCloud-compatible storage is a hard requirement for part of this audience, not a nice-to-have — keep every future feature (search index, tag layer, graph view) as metadata *alongside* plain `.md` files, never as a replacement for them.

---

### Performance guardrails (apply throughout)
- Keep launch instant and typing latency invisible.
- Incremental/debounced rendering for large files.
- No feature ships if it makes the editor feel heavier.
