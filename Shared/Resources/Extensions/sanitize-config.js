// Sanitizes the composed preview/export document's <body> innerHTML with the vendored
// DOMPurify (see purify.min.js, issue #118). Runs inside HTMLSanitizer's hidden WKWebView,
// invoked via evaluateJavaScript, never inside the live preview's own WKWebView -- see
// Shared/Preview/HTMLSanitizer.swift.
//
// The allowlist is the union of two needs: (1) GitHub's own raw-HTML-passthrough tag set
// (issue #118's Phase 1 spec), so Markdown source like `<details>`/`<sub>`/`<kbd>` renders the
// same as it does on github.com, and (2) every tag/attribute Fen's own normal Markdown-to-HTML
// pipeline legitimately emits (cmark-gfm core + GFM extensions + MarkdownRenderer's alert/TOC/
// highlight post-processing) -- sanitizing runs over the WHOLE composed body, not just literal
// raw-HTML fragments, so a narrower list would strip Fen's own rendering.
function fenSanitize(dirtyHTML) {
  return DOMPurify.sanitize(dirtyHTML, {
    ALLOWED_TAGS: [
      // GitHub raw-HTML passthrough (issue #118 Phase 1)
      'sub', 'sup', 'ins', 'kbd', 'br', 'details', 'summary', 'picture', 'source',
      'img', 'a', 'span', 'div', 'p', 'code', 'pre',
      // cmark-gfm core + GFM extensions (tables, strikethrough, tasklist, footnotes)
      'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote', 'ul', 'ol', 'li',
      'strong', 'em', 'hr', 'table', 'thead', 'tbody', 'tr', 'th', 'td',
      'del', 'section', 'input',
      // Fen's own post-processing (MarkdownRenderer+Alerts.swift, +Emoji via <mark>)
      'mark',
      // HTML comments are allowlisted content (issue #118 Phase 1) -- DOMPurify represents
      // them as a '#comment' node type, so this must be listed alongside ALLOW_COMMENTS below.
      '#comment',
    ],
    ALLOWED_ATTR: [
      'id', 'class', 'href', 'src', 'alt', 'title', 'start',
      'align', 'style', 'colspan', 'rowspan',
      'data-sourcepos', 'data-footnotes', 'data-footnote-ref', 'data-footnote-backref',
      'data-footnote-backref-idx', 'aria-label',
      'type', 'checked', 'disabled', 'name',
    ],
    ALLOW_DATA_ATTR: false,
    ALLOW_COMMENTS: true,
    // Without this, a leading HTML comment at the very start of dirtyHTML (before any element)
    // is dropped by the browser's own fragment parser before DOMPurify's DOM walk ever sees it
    // -- FORCE_BODY makes DOMPurify parse dirtyHTML as a full <body>, which preserves it.
    FORCE_BODY: true,
    // DOMPurify's own default ALLOWED_URI_REGEXP already permits relative paths (Fen's
    // fen-preview:// asset links, PreviewSchemeHandler.swift) and http(s)/mailto, and its
    // default DATA_URI_TAGS already permits `data:` on img/source (self-contained HTML export's
    // inlined images, ExportAssetResolver.swift) -- no override needed here.
    //
    // USE_PROFILES: { html: true } is deliberately NOT set -- it merges in DOMPurify's entire
    // built-in HTML tag profile (which includes 'form' and others outside this allowlist) on
    // top of ALLOWED_TAGS rather than restricting to it, silently widening the allowlist above.
    // ALLOWED_TAGS/ALLOWED_ATTR alone are the complete, exhaustive allowlist.
  });
}
