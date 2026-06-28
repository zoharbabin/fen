# MacDown (Swift) — Roadmap

**North star:** be the *default* app people reach for to open and edit `.md`
files on macOS — clean, fast, and native. We take inspiration from Typora,
iA Writer, Bear, and the original MacDown, but we stay minimal: speed and
clarity over feature sprawl.

Status legend: `[ ]` planned · `[~]` partial/started

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
- [ ] Verify/strengthen UTI + document-type registration so macOS offers MacDown as a handler and it can be **Set as Default** for `.md`/`.markdown`/`.mdown`/`.mkd`
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

## 4. App polish
- [ ] **Icon refinement** (cleanup of the current M↓ / Swift-arrow mark)
- [ ] About panel with credits (Tzu-ping Chung, Mou) and bundled third-party licenses
- [ ] First-run sample document / light onboarding
- [ ] Settings screen polish and grouping pass

---

## 5. Distribution & ops
- [ ] Add GitHub Actions signing secrets so CI cuts signed+notarized releases on tag push (see `RELEASING.md`)
- [ ] In-app update check (e.g. Sparkle) for the non-App-Store build
- [ ] (Deferred) Mac App Store: requires a sandboxed second build flavor — revisit later
- [ ] Homebrew Cask once releases are automated

---

## 6. iOS / iPadKit
- [ ] iPad-class layout, document browser, keyboard shortcuts
- [ ] Share-sheet import/export

---

### Performance guardrails (apply throughout)
- Keep launch instant and typing latency invisible.
- Incremental/debounced rendering for large files.
- No feature ships if it makes the editor feel heavier.
