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
  // Starts dirty so the very first read builds the table. Every real invalidation
  // trigger below (ResizeObserver, MutationObserver, font-scale write, Mermaid/MathJax
  // completion, window 'resize') sets this unconditionally rather than comparing layout
  // scalars against a cached snapshot -- a scalar comparison can alias: an in-flight
  // resize can pass through an intermediate size that happens to match a previously
  // cached triple, or content can rewrap to a coincidentally identical scrollHeight at a
  // different width, either of which would wrongly skip a rebuild while real rendered
  // positions have moved. A boolean has no value space to alias against.
  var anchorsDirty = true;
  // scrollHeight the anchor table's "rendered" axis was last normalized against -- an
  // additional staleness signal alongside anchorsDirty, not a replacement for it. Neither
  // ResizeObserver (fires on documentElement's own border-box/viewport size, not its content
  // overflow height) nor MutationObserver (fires on DOM node adds/removes, not layout-only
  // changes) ever fires when scrollHeight alone settles to a new value after a resize --
  // observed via the debug log for the "maximize with no further trigger" repro: a single
  // ResizeObserver notification landed while text reflow was still catching up to the new
  // width, rebuilding anchors against a transient scrollHeight, and no later event ever
  // invalidated it even though the real scrollHeight kept settling afterward. Comparing this
  // scalar can only ever force an *extra* rebuild (when the live value no longer matches),
  // never skip one anchorsDirty would otherwise have triggered -- so it can't reintroduce the
  // intermediate-frame aliasing anchorsDirty's own doc comment above warns a scalar comparison
  // risks; it only closes the gap where nothing at all marks the table dirty.
  var anchorsScrollHeight = null;
  // The last source fraction either a genuine preview scroll or an editor-driven
  // scrollAssignmentJS/fontScaleAssignmentJS write recorded -- see reconcileScroll's doc
  // comment for why this exists: WebKit's own scrollTop-clamping during a window resize
  // needs a known-good fraction to re-home to, since the resize-clamped scrollTop itself
  // no longer means anything relative to where the anchor table now says that content is.
  var lastKnownSourceFraction = null;
  // maxScroll as of the last reconcileScroll call, so a later call can tell a real resize
  // (this changed) apart from an ordinary scroll (this didn't).
  var lastObservedMaxScroll = null;
  // Coalesces a burst of ResizeObserver frames (a window zoom/maximize animation) into a
  // single scroll-position reconcile, the same way scheduleRefresh already coalesces a burst
  // of dirtying events into one anchor rebuild -- see scheduleScrollReconcile.
  var scrollReconcileScheduled = false;
  // Coalesces a burst of dirtying events (several ResizeObserver frames while a split
  // divider settles, several MutationObserver batches while Mermaid/highlight.js insert
  // nodes) into a single repaint, the same way a burst of resize frames already costs
  // exactly one rebuild via the lazy anchorsDirty check -- see refreshAnchorsIfStale.
  var refreshScheduled = false;

  function markAnchorsDirty() {
    anchorsDirty = true;
    // Anchors (scroll-sync fractions) stay pull-based: nothing reads them until the user
    // scrolls or the editor asks for a fraction, so leaving them lazy here is correct and
    // matches rule 4.1 (issue #110) -- confirmed by ScrollSyncVerifyTest's
    // anchorTableRecomputesAfterReflow/burstOfMarkDirtyCallsCostsOneRebuild, which assert a
    // burst of dirtying events costs zero rebuilds until the next explicit read. The gutter
    // is different: it's painted onto the page with nothing else ever "reading" it, so it
    // needs a push, not a pull -- scheduled only when the feature that needs pushing is on.
    if (window.__fenShowLineNumbers) {
      scheduleRefresh();
    }
    scheduleScrollReconcile();
  }

  // Proactively corrects the preview's scroll position after a reflow, instead of waiting
  // for WKWebView's own 'scroll' event -- which only fires when it has to clamp scrollTop to
  // a smaller maxScroll. A resize that changes scrollHeight without making the existing
  // scrollTop exceed the new maxScroll (e.g. shrinking a wide page whose scrollTop was already
  // near the top) never triggers that clamp, so no 'scroll' event -- and therefore no
  // reconcileScroll call -- ever fires, leaving the preview stuck at its old raw pixel offset
  // while the editor (whose scrollViewDidScroll re-homes on every notification) moves on.
  // Confirmed via the debug log for the "shrink, scroll, then maximize" repro: the
  // ResizeObserver fired and rebuilt the anchor table, but zero 'JS scroll'/'PREVIEW scroll'
  // events followed -- the clamp this whole mechanism relies on simply never happened.
  // setTimeout (not requestAnimationFrame, for the same reason scheduleRefresh uses it) lets a
  // burst of ResizeObserver frames during an animated window zoom collapse into one reconcile
  // after the frame settles, rather than fighting a user's own in-progress scroll frame by frame.
  function scheduleScrollReconcile() {
    if (scrollReconcileScheduled || lastKnownSourceFraction === null) {
      return;
    }
    scrollReconcileScheduled = true;
    setTimeout(function () {
      scrollReconcileScheduled = false;
      reconcileScroll(document.documentElement.scrollTop);
    }, 0);
  }

  // Proactively pulls the dirty flag for the gutter instead of leaving it purely passive.
  // Before this, a ResizeObserver/MutationObserver firing with no later scroll or
  // `resize`/`load` DOM event (e.g. the split view's WKWebView settling its frame size after
  // launch, or Mermaid/MathJax/highlight.js inserting content after the page's first paint,
  // with the user never scrolling) left every gutter number frozen at whatever pixel position
  // the very first, possibly pre-layout-settled paint computed -- visibly wrong the further
  // down the document a block sits, since each stale number compounds the drift of every
  // block above it. Deliberately `setTimeout`, not `requestAnimationFrame`: rAF only fires
  // while a display link is driving the page (see ScrollSyncJS.swift's scrollObserverJS doc
  // comment, which hit this exact gap and abandoned rAF for the same reason), which a
  // background/off-screen WKWebView -- or `swift test`'s headless one -- never has. A 0ms
  // timeout still coalesces a synchronous burst of triggers (several ResizeObserver frames,
  // several MutationObserver batches in the same tick) into one repaint, since they all
  // schedule before any timeout callback gets a chance to run.
  function scheduleRefresh() {
    if (refreshScheduled) {
      return;
    }
    refreshScheduled = true;
    setTimeout(function () {
      refreshScheduled = false;
      refreshAnchorsIfStale();
    }, 0);
  }

  // Exposed so `ScrollSyncJS.swift`'s `fontScaleAssignmentJS` can force a rebuild right
  // after its live CSS-var write -- that write changes layout through CSS `zoom`, which
  // fires neither a `resize` event nor a DOM mutation the MutationObserver above would
  // catch, so it needs an explicit call rather than relying on either observer.
  window.__fenScrollSyncMarkDirty = markAnchorsDirty;

  function refreshAnchorsIfStale() {
    var liveScrollHeight = document.documentElement.scrollHeight;
    if (!anchorsDirty && anchorsScrollHeight === liveScrollHeight) {
      return;
    }
    anchorsDirty = false;
    anchors = computeAnchors();
    anchorsScrollHeight = document.documentElement.scrollHeight;
    if (window.__fenShowLineNumbers) {
      lineNumberAnchors = computeLineNumberAnchors();
      renderLineNumberGutter();
    }
    // Exposed only for Tests/FenTests/ScrollSyncVerifyTest.swift, mirroring
    // window.__fenScrollSync.lineNumberAnchors's "exposed for tests" precedent -- lets a test
    // assert a burst of dirtying events (several resizes, several mutations) still costs
    // exactly one rebuild per read, not one per event.
    window.__fenScrollSyncRebuildCount = (window.__fenScrollSyncRebuildCount || 0) + 1;
  }

  // Reacts to genuine layout-box changes -- a window resize, a split-divider drag, or
  // any other reflow that changes documentElement's box -- rather than polling scalars,
  // so there's no intermediate-frame value to alias against (see anchorsDirty above).
  // The callback only flags dirty; the actual recompute stays lazy, deferred to the next
  // renderedFractionForSource/sourceFractionForRendered/lineNumberAnchors() call, so a
  // burst of resize frames still costs exactly one rebuild, not one per frame.
  if (typeof ResizeObserver != "undefined") {
    new ResizeObserver(markAnchorsDirty).observe(document.documentElement);
  }

  // Catches DOM changes a ResizeObserver can miss: Mermaid/MathJax replacing placeholder
  // nodes with rendered output after window.onload already fired and refreshAnchorsIfStale
  // already ran once, or any other async/format-driven content change. Kept alongside the
  // explicit ready-promise hooks below (belt-and-suspenders) since a promise resolving with
  // no net DOM change (e.g. an empty diagram) still means "safe to assume settled" even
  // though no mutation fires.
  // Ignores a mutation batch that is nothing but renderLineNumberGutter's own
  // .fen-gutter-line add/remove churn -- without this, markAnchorsDirty (now that it
  // actively schedules a repaint, see scheduleRefresh) would re-trigger itself forever:
  // refreshAnchorsIfStale repaints the gutter -> that DOM write is observed here -> marks
  // dirty again -> schedules another repaint -> repeat every animation frame, permanently.
  function isOnlyGutterChurn(mutations) {
    for (var i = 0; i < mutations.length; i++) {
      var changed = mutations[i].addedNodes.length + mutations[i].removedNodes.length;
      if (changed === 0) {
        continue;
      }
      var nodes = [];
      for (var a = 0; a < mutations[i].addedNodes.length; a++) {
        nodes.push(mutations[i].addedNodes[a]);
      }
      for (var r = 0; r < mutations[i].removedNodes.length; r++) {
        nodes.push(mutations[i].removedNodes[r]);
      }
      for (var n = 0; n < nodes.length; n++) {
        if (!nodes[n].classList || !nodes[n].classList.contains("fen-gutter-line")) {
          return false;
        }
      }
    }
    return true;
  }

  if (typeof MutationObserver != "undefined") {
    new MutationObserver(function (mutations) {
      if (isOnlyGutterChurn(mutations)) {
        return;
      }
      markAnchorsDirty();
    }).observe(document.body, { childList: true, subtree: true });
  }

  if (window.__fenMermaidReadyPromise) {
    window.__fenMermaidReadyPromise.then(markAnchorsDirty, markAnchorsDirty);
  }
  if (window.MathJax && window.MathJax.startup && window.MathJax.startup.promise) {
    window.MathJax.startup.promise.then(markAnchorsDirty, markAnchorsDirty);
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

  // Shared by computeAnchors and computeLineNumberAnchors. Always measures via a Range over
  // the element's contents rather than the element's own `getBoundingClientRect()`, for two
  // reasons: (1) `getBoundingClientRect()` reports every field as 0 for an element with
  // `display: contents` -- it has no CSS box of its own to measure. HTMLComposer's
  // `li > p:first-child { display: contents; }` rule (list-marker/line-box alignment for
  // loose list items) puts exactly this style on some data-sourcepos leaf <p> elements, which
  // would otherwise anchor them (and every subsequent gutter number relying on document
  // order) to the top of the page. (2) Even for an ordinary boxed element, `top` is the top of
  // its *line box*, which includes CSS half-leading -- the extra space `line-height` adds
  // above a font's natural metrics, split evenly above and below the glyphs. That gap grows
  // with `line-height - font-size`, so it's small for body text and large for headings (a
  // measured 6px gap at a 28px/44.8px h1 vs. 3px at 14px/22.4px body text) -- exactly why a
  // heading's gutter number visibly sits above its text while a paragraph's looks closer.
  // A Range's rect comes from its (still-boxed) descendants' actual glyph extent, not the
  // line box, so it reports where the text visually starts in both cases.
  //
  // A childless leaf (e.g. <hr>, which has no child nodes at all) breaks that Range approach:
  // selectNodeContents on an empty element selects nothing, so the Range's rect comes back
  // with every field at 0 regardless of where the element actually renders -- pinning its
  // gutter number to the very top of the page instead of its true position. Detect that exact
  // degenerate shape (all four fields simultaneously 0, which real rendered content practically
  // never produces) and fall back to the element's own box rect, which is accurate for a
  // childless element precisely because it has no text content to suffer the half-leading gap
  // rangeRectFor exists to correct for.
  function elementTop(element) {
    var rect = rangeRectFor(element);
    if (rect.top === 0 && rect.left === 0 && rect.width === 0 && rect.height === 0) {
      rect = element.getBoundingClientRect();
    }
    return rect.top + window.scrollY;
  }

  function rangeRectFor(element) {
    var range = document.createRange();
    range.selectNodeContents(element);
    return range.getBoundingClientRect();
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
      var top = elementTop(elements[i]);
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
      var top = elementTop(elements[i]);
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
    // The rail (background + divider, styled to match the editor gutter's own ruler chrome --
    // see lineNumberGutterCSS's doc comment in HTMLComposer.swift) is `position: fixed`, so
    // unlike the numbers below it never needs repositioning as the anchor table changes.
    // Inserted once and left alone on every later rebuild, rather than removed/recreated
    // alongside the numbers, so it triggers isOnlyGutterChurn's markAnchorsDirty exactly once
    // (its class isn't "fen-gutter-line", so that one insertion doesn't get ignored) instead of
    // on every rebuild -- removing and recreating it here the same way the numbers below do
    // would mean every rebuild adds a non-"fen-gutter-line" node, permanently defeating that
    // guard's self-retriggering-loop protection.
    if (!document.querySelector(".fen-gutter-rail")) {
      var rail = document.createElement("div");
      rail.className = "fen-gutter-rail";
      document.body.appendChild(rail);
    }

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

  // WKWebView clamps document.documentElement.scrollTop to the new (possibly much smaller)
  // maxScroll as part of a resize reflow -- e.g. a window zoom/maximize that re-wraps text
  // and collapses scrollHeight -- and that clamp fires a genuine 'scroll' event with no
  // actual user action behind it. Converting that clamped scrollTop through the anchor
  // table as if it were a real scroll produces a spurious jump (observed climbing toward
  // renderedFraction 1.0, i.e. clamped to the new max, in the debug log for the "shrink,
  // scroll, then maximize" repro). Detecting "maxScroll changed since the last call" and
  // re-homing to the last known-good source fraction instead -- mirroring how
  // MarkdownTextView.swift's scrollViewDidScroll re-homes NSClipView's analogous stale
  // pixel offset -- treats the resize-clamp as a layout artifact to correct for, not a
  // scroll to report.
  function reconcileScroll(scrollTop) {
    refreshAnchorsIfStale();
    var maxScroll = document.documentElement.scrollHeight - document.documentElement.clientHeight;
    var resized = lastObservedMaxScroll !== null && maxScroll !== lastObservedMaxScroll;
    lastObservedMaxScroll = maxScroll;
    if (resized && lastKnownSourceFraction !== null) {
      var targetRendered = interpolate(anchors, "source", "rendered", lastKnownSourceFraction);
      var targetTop = targetRendered * Math.max(1, maxScroll);
      if (Math.abs(scrollTop - targetTop) > 1) {
        window.__fenExpectedScrollTop = targetTop;
        document.documentElement.scrollTop = targetTop;
      }
      return null;
    }
    var renderedFraction = scrollTop / Math.max(1, maxScroll);
    var sourceFraction = interpolate(anchors, "rendered", "source", renderedFraction);
    lastKnownSourceFraction = sourceFraction;
    return sourceFraction;
  }

  window.__fenScrollSync = {
    renderedFractionForSource: function (fraction) {
      refreshAnchorsIfStale();
      lastKnownSourceFraction = fraction;
      return interpolate(anchors, "source", "rendered", fraction);
    },
    sourceFractionForRendered: function (fraction) {
      refreshAnchorsIfStale();
      var source = interpolate(anchors, "rendered", "source", fraction);
      lastKnownSourceFraction = source;
      return source;
    },
    reconcileScroll: reconcileScroll,
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
