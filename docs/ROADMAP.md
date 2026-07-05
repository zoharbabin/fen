# Fen — Roadmap

**North star:** be the app people reach for to write and *think* in Markdown on macOS — clean, fast, and native, that grows into a connected knowledge base instead of a pile of loose files. We take inspiration from Typora, iA Writer, Bear, Obsidian, and the original MacDown, but we stay minimal: speed and clarity over feature sprawl.

Status legend: `[ ]` planned · `[~]` partial/started · `[x]` done

---

## 1. Next up (high value, aligned with the north star)

### Export (the big one)
- [ ] **Export to PDF** — render the preview `WKWebView` to paginated PDF (`createPDF`), with page size/margins and a print stylesheet
- [ ] **Export to HTML** — wire a UI onto the existing `composeForExport` (self-contained vs. linked assets toggle)
- [ ] **Print** support (`NSPrintOperation` via the web view)
- [ ] **Copy as HTML** / **Copy as Rich Text** to clipboard

### Formatting toolbar
- [ ] Toolbar + menu actions for: bold, italic, strikethrough, inline code, code block, H1–H3, bullet/numbered list, task item, blockquote, link, image, horizontal rule, table
- [ ] Smart toggling (apply/remove around selection; wrap empty selection with placeholder)
- [ ] Reuse/extend the existing `insertMarkdownFormatting` notification path; add the missing actions

### "Default `.md` editor" system integration
- [ ] Verify/strengthen UTI + document-type registration so macOS offers Fen as a handler and it can be **Set as Default** for `.md`/`.markdown`/`.mdown`/`.mkd`
- [ ] A **document icon** for `.md` files in Finder
- [ ] Restore last session / recent documents; sensible new-doc behavior
- [ ] (Stretch) Quick Look preview extension for Markdown files

---

## 2. Editing quality (fast, frictionless)
- [ ] Find & Replace — confirm the native find bar works; add replace UX
- [ ] Auto-continue lists + smart renumbering (prefs exist; wire them up)
- [ ] Auto-pair brackets/quotes; wrap selection with pairs (pref exists)
- [ ] Tab/indent handling, convert tabs→spaces (pref exists)
- [ ] Paste/drag-drop images → save to a sidecar folder and insert a link
- [ ] Document **outline / TOC** navigator (jump to headings)
- [ ] Optional focus/typewriter mode (iA Writer-style), distraction-free toggle

---

## 3. Preview & theming polish
- [ ] Dark-mode preview that follows system appearance (and a manual toggle)
- [ ] Tighten scroll-sync accuracy on long/uneven documents
- [ ] Preview style picker polish; allow user custom CSS
- [ ] Per-document front-matter driven options where sensible

---

## 4. Knowledge suite (Fen's long game)

This is what sets Fen apart from a single-file editor: your notes stop living as isolated files and become a connected knowledge base.

- [ ] **Multi-file workspace** — open a folder of Markdown files as one project, not one document at a time
- [ ] **Backlinks & wiki-links** — `[[note-name]]` linking between files, with a backlinks panel
- [ ] **Local search & indexing** — fast full-text search across a workspace, built on an on-device index
- [ ] **Ontology / tagging layer** — structured tags and note types that let you query your notes like a lightweight knowledge graph, not just grep
- [ ] **Graph view** — visualize how notes connect
- [ ] (Stretch) On-device AI assistance for summarizing, linking, and organizing notes — privacy-first, no server round-trip required

---

## 5. App polish
- [x] **Icon refinement** — a Fen mark that fits the brand
- [ ] About panel with credits (Tzu-ping Chung, Mou) and bundled third-party licenses
- [ ] First-run sample document / light onboarding
- [ ] Settings screen polish and grouping pass

---

## 6. Distribution & ops
- [x] GitHub Actions signing secrets — CI cuts signed and notarized releases on every tag push (see `RELEASING.md`)
- [ ] In-app update check (e.g. Sparkle) for the non-App-Store build
- [ ] (Deferred) Mac App Store — needs a sandboxed second build flavor, revisit later
- [ ] Homebrew Cask

---

## 7. iOS / iPadOS
- [ ] iPad-class layout, document browser, keyboard shortcuts
- [ ] Share-sheet import/export

---

### Performance guardrails (apply throughout)
- Keep launch instant and typing latency invisible.
- Incremental/debounced rendering for large files.
- No feature ships if it makes the editor feel heavier.
