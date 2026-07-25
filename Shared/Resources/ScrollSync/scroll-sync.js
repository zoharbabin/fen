// Corrects scroll-sync drift between the source Markdown and the rendered
// preview by mapping fractions through an anchor table built from each
// top-level block's data-sourcepos, instead of assuming both panes have
// the same content density throughout the document.

(function () {
  var anchors = [];
  // Whole-document line-number gutter positions (issue #21), rebuilt on the same
  // staleness signal as `anchors` below -- one {line, top} pair per leaf
  // data-sourcepos element, only ever populated when window.__fenShowLineNumbers
  // is on, so the feature costs nothing when the preference is off.
  var lineNumberAnchors = [];
  // Layout dimensions the cached anchors were built against. Any reflow that changes
  // these (resizing the window, dragging the split divider, an image finishing a late
  // load, Mermaid/MathJax finishing an async render) shifts every element's rendered
  // position, so a table built once on 'load' and never rechecked drifts further out of
  // sync the deeper the fraction lands in the document. Content growing/shrinking
  // (scrollHeight) fires no DOM event at all, so every lookup re-checks it directly
  // rather than relying solely on the 'resize' event, which only covers the viewport.
  var anchorWidth = -1;
  var anchorHeight = -1;
  var anchorScrollHeight = -1;

  function refreshAnchorsIfStale() {
    var width = document.documentElement.clientWidth;
    var height = document.documentElement.clientHeight;
    var scrollHeight = document.documentElement.scrollHeight;
    if (width === anchorWidth && height === anchorHeight && scrollHeight === anchorScrollHeight) {
      return;
    }
    anchorWidth = width;
    anchorHeight = height;
    anchorScrollHeight = scrollHeight;
    anchors = computeAnchors();
    if (window.__fenShowLineNumbers) {
      lineNumberAnchors = computeLineNumberAnchors();
      renderLineNumberGutter();
    }
  }

  // Shared by computeAnchors and computeLineNumberAnchors so both read the same
  // data-sourcepos parsing rule (rule 4.1/5.1) -- they differ only in which elements
  // they collect and what they do with the parsed line, not in how a line is parsed.
  function parseStartLine(element) {
    var pos = element.getAttribute("data-sourcepos");
    if (!pos) {
      return NaN;
    }
    return parseInt(pos.split(":")[0], 10);
  }

  function computeAnchors() {
    var maxScroll = document.documentElement.scrollHeight - document.documentElement.clientHeight;
    var totalLines = window.__fenTotalSourceLines || 0;
    if (maxScroll <= 0 || totalLines <= 0) {
      return [];
    }

    // data-sourcepos is relative to the Markdown after front-matter stripping;
    // add the stripped line count back to land on the raw source line the editor shows.
    var lineOffset = window.__fenSourceLineOffset || 0;

    var elements = document.querySelectorAll("[data-sourcepos]");
    var raw = [];
    for (var i = 0; i < elements.length; i++) {
      var startLine = parseStartLine(elements[i]);
      if (isNaN(startLine)) {
        continue;
      }
      var top = elements[i].getBoundingClientRect().top + window.scrollY;
      raw.push({
        source: Math.max(0, Math.min(1, (startLine - 1 + lineOffset) / totalLines)),
        rendered: Math.max(0, Math.min(1, top / maxScroll)),
      });
    }

    // Anchors come from the DOM in document order, so both axes are already
    // close to non-decreasing; drop anything that would still make the
    // interpolation table non-monotonic.
    var filtered = [{ source: 0, rendered: 0 }];
    for (var j = 0; j < raw.length; j++) {
      var candidate = raw[j];
      var previous = filtered[filtered.length - 1];
      if (candidate.source <= previous.source || candidate.rendered <= previous.rendered) {
        continue;
      }
      filtered.push(candidate);
    }
    filtered.push({ source: 1, rendered: 1 });
    return filtered;
  }

  // Leaf data-sourcepos elements only (issue #21) -- an element that itself carries
  // data-sourcepos but has no non-cell descendant that also does. cmark-gfm annotates
  // every block-level container (e.g. a loose list's <li> AND its inner <p>, a
  // <blockquote> AND its inner <p>), so walking every matched element would stack
  // duplicate numbers at the same rendered position. `td`/`th` cells are excluded from
  // both the candidate set and the descendant check: cmark-gfm annotates each cell with
  // its own data-sourcepos too, which would otherwise make every cell its own leaf and
  // number a single row once per column. Excluding them makes the row's own <tr> the
  // leaf instead -- one number per logical block (row, list item, paragraph), matching
  // the documented "starting source line, not one number per source line it spans"
  // convention (rule 3.3).
  function collectLeafSourceposElements() {
    var all = document.querySelectorAll("[data-sourcepos]:not(td):not(th)");
    var leaves = [];
    for (var i = 0; i < all.length; i++) {
      if (!all[i].querySelector("[data-sourcepos]:not(td):not(th)")) {
        leaves.push(all[i]);
      }
    }
    return leaves;
  }

  // One {line, top} pair per leaf data-sourcepos block (issue #21) -- `line` is that
  // block's raw (front-matter-inclusive) starting source line, `top` its rendered pixel
  // position, both computed the same way computeAnchors already does. This is the
  // documented source-line-numbering choice (rule 3.3): a block spanning several raw
  // source lines (a wrapped paragraph, a multi-line table row) is marked once, at its
  // first line, not once per raw line it spans.
  function computeLineNumberAnchors() {
    var totalLines = window.__fenTotalSourceLines || 0;
    if (totalLines <= 0) {
      return [];
    }
    var lineOffset = window.__fenSourceLineOffset || 0;
    var elements = collectLeafSourceposElements();
    var result = [];
    for (var i = 0; i < elements.length; i++) {
      var startLine = parseStartLine(elements[i]);
      if (isNaN(startLine)) {
        continue;
      }
      var top = elements[i].getBoundingClientRect().top + window.scrollY;
      result.push({ line: startLine + lineOffset, top: top });
    }
    return result;
  }

  // Draws `lineNumberAnchors` into the preview's whole-document gutter (issue #21).
  // Each number is a `position: absolute` div with no positioned ancestor, so its
  // `top` is relative to the initial containing block -- the same document-pixel
  // coordinate space `getBoundingClientRect().top + scrollY` already reads from --
  // meaning it scrolls with the page like ordinary content, with no scroll listener
  // or per-frame repositioning needed. Only ever called from refreshAnchorsIfStale,
  // so a rebuild happens exactly when the anchor table itself would rebuild (rule 4.2).
  // Writes only numeric textContent, never innerHTML (rule 2.2) -- document-derived
  // text never reaches this gutter, only the integer line numbers already reused by
  // computeAnchors above.
  function renderLineNumberGutter() {
    var stale = document.querySelectorAll(".fen-gutter-line");
    for (var i = 0; i < stale.length; i++) {
      stale[i].remove();
    }
    for (var j = 0; j < lineNumberAnchors.length; j++) {
      var lineDiv = document.createElement("div");
      lineDiv.className = "fen-gutter-line";
      lineDiv.style.top = lineNumberAnchors[j].top + "px";
      lineDiv.textContent = String(lineNumberAnchors[j].line);
      document.body.appendChild(lineDiv);
    }
  }

  // The same piecewise-linear-interpolation-with-clamped-endpoints technique as
  // Shared/Editor/EditorScrollAnchors.swift's interpolateEditorAnchor — kept in sync
  // deliberately; Tests/FenTests/CrossLanguageInterpolationTest.swift runs both
  // implementations against the same table and inputs to prove they agree.
  function interpolate(table, fromKey, toKey, value) {
    if (table.length < 2) {
      return value;
    }
    var first = table[0];
    if (value <= first[fromKey]) {
      return first[toKey];
    }
    var last = table[table.length - 1];
    if (value >= last[fromKey]) {
      return last[toKey];
    }
    for (var i = 1; i < table.length; i++) {
      if (value <= table[i][fromKey]) {
        var previous = table[i - 1];
        var current = table[i];
        var span = current[fromKey] - previous[fromKey];
        var t = span > 0 ? (value - previous[fromKey]) / span : 0;
        return previous[toKey] + t * (current[toKey] - previous[toKey]);
      }
    }
    return value;
  }

  window.__fenScrollSync = {
    renderedFractionForSource: function (fraction) {
      refreshAnchorsIfStale();
      return interpolate(anchors, "source", "rendered", fraction);
    },
    sourceFractionForRendered: function (fraction) {
      refreshAnchorsIfStale();
      return interpolate(anchors, "rendered", "source", fraction);
    },
    // Exposed (pure, side-effect-free) so tests can call the exact same interpolation
    // production code uses with an arbitrary literal table, instead of only ever exercising
    // it through a table built from a real DOM's data-sourcepos layout. See
    // Tests/FenTests/CrossLanguageInterpolationTest.swift, which drives this and Swift's
    // interpolateEditorAnchor with identical tables/inputs to prove the two stay in agreement.
    interpolate: interpolate,
    // Exposed for Tests/FenTests/PreviewGutterVerifyTest.swift -- lets a test force a
    // rebuild and read the exact anchors renderLineNumberGutter drew from, instead of only
    // being able to assert on the resulting .fen-gutter-line DOM elements.
    lineNumberAnchors: function () {
      refreshAnchorsIfStale();
      return lineNumberAnchors;
    },
  };

  if (typeof window.addEventListener != "undefined") {
    window.addEventListener("load", refreshAnchorsIfStale, false);
    window.addEventListener("resize", refreshAnchorsIfStale, false);
  } else {
    window.attachEvent("onload", refreshAnchorsIfStale);
    window.attachEvent("onresize", refreshAnchorsIfStale);
  }
})();
