// Corrects scroll-sync drift between the source Markdown and the rendered
// preview by mapping fractions through an anchor table built from each
// top-level block's data-sourcepos, instead of assuming both panes have
// the same content density throughout the document.

(function () {
  var anchors = [];
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
      var pos = elements[i].getAttribute("data-sourcepos");
      var startLine = parseInt(pos.split(":")[0], 10);
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
  };

  if (typeof window.addEventListener != "undefined") {
    window.addEventListener("load", refreshAnchorsIfStale, false);
    window.addEventListener("resize", refreshAnchorsIfStale, false);
  } else {
    window.attachEvent("onload", refreshAnchorsIfStale);
    window.attachEvent("onresize", refreshAnchorsIfStale);
  }
})();
