// init mermaid

(function () {

  mermaid.initialize({
    startOnLoad: false,
    theme: window.__fenMermaidTheme || "default",
    flowchart: {
      htmlLabels: false,
      useMaxWidth: true
    },
    // Without this, mermaid.render() on a parse error still throws the error we catch below,
    // but only after first drawing its own "Syntax error in text" bomb-icon SVG into a
    // temporary <div> it appends directly to document.body -- and it never removes that div,
    // since the removal-on-error cleanup path only runs when this flag is set. Left unset,
    // every broken diagram leaves an orphaned bomb-icon graphic behind at the end of the
    // document, alongside our own error panel.
    suppressErrorRendering: true
  });

  // Mermaid's parser is Jison-generated (a yacc/bison-style LALR parser), so on a syntax
  // error its only built-in reporting is a raw shift-reduce dump: the grammar's internal
  // terminal names (BRKT, point_start, AXIS-TEXT-DELIMITER, ...) rather than a human
  // sentence. That's true of every Mermaid diagram grammar, not just one -- Mermaid exposes
  // no friendlier error-formatting API to opt into. The patterns below translate the small
  // set of failure signatures we've verified by hand (see MermaidErrorPanelVerifyTest.swift)
  // into a plain sentence; anything we haven't verified falls through honestly to Mermaid's
  // own technical message instead of guessing at a translation that might be wrong.
  function friendlyMermaidError(error) {
    if (!error) return null;
    var hash = error.hash;

    if (!hash) {
      if (error.name === "UnknownDiagramError") {
        return "Fen doesn't recognize this as a Mermaid diagram type. Check that the " +
          "first line names a real diagram kind (flowchart, sequenceDiagram, " +
          "quadrantChart, etc.) and isn't misspelled.";
      }
      return null;
    }

    var expected = hash.expected || [];
    function expects(name) {
      return expected.indexOf("'" + name + "'") !== -1;
    }

    if (hash.token === "COLON" && expects("point_start")) {
      return "This label contains a colon (:), which quadrantChart reserves for its own " +
        "\"Label: [x, y]\" point syntax. Remove the colon from the label, or rephrase it " +
        "without one.";
    }

    if (hash.token === "MINUS" && expects("START_LINK") && expects("LINK") && expects("LINK_ID")) {
      return "This looks like an arrow written with a single dash (-). Flowchart arrows " +
        "need two dashes, e.g. --> instead of ->.";
    }

    if (hash.token === "NEWLINE" && expected.length === 1 && expects("TXT")) {
      return "This line has an arrow (like ->> or -->>) but no message text after it. Add " +
        "text after the colon, e.g. \"Alice->>Bob: some text\".";
    }

    return null;
  }

  // Mermaid's line number is relative to the diagram's own source, not the document --
  // "line 6" means nothing to a reader looking at their Markdown file. The fenced code
  // block's `data-sourcepos` (set by MarkdownRenderer when rendering for the real editor)
  // gives the document line the fence itself starts on; the diagram's first line of content
  // is one line after that, so document line = fence's sourcepos line + Mermaid's line.
  function documentLine(preElement, error) {
    var sourcepos = preElement.getAttribute("data-sourcepos");
    var fenceLine = sourcepos && parseInt(sourcepos.split(":")[0], 10);
    var mermaidLine = error && error.hash && error.hash.loc && error.hash.loc.first_line;
    if (!fenceLine || isNaN(fenceLine) || !mermaidLine) return null;
    return fenceLine + mermaidLine;
  }

  // Shown verbatim (via textContent, never innerHTML) so the reader knows to fix their
  // Markdown, not to suspect Fen.
  function renderErrorPanel(dom, graphSource, error) {
    var panel = document.createElement("div");
    panel.className = "fen-mermaid-error";

    var heading = document.createElement("p");
    heading.className = "fen-mermaid-error-heading";
    heading.textContent = "This diagram didn't render — there's a syntax problem in the Markdown below, not in Fen.";
    panel.appendChild(heading);

    var friendly = friendlyMermaidError(error);
    var docLine = documentLine(dom, error);
    if (friendly) {
      var summary = document.createElement("p");
      summary.className = "fen-mermaid-error-summary";
      summary.textContent = docLine
        ? friendly + " (line " + docLine + " of your document)"
        : friendly;
      panel.appendChild(summary);
    } else {
      var noTranslation = document.createElement("p");
      noTranslation.className = "fen-mermaid-error-summary";
      noTranslation.textContent = "Fen doesn't have a plain-English translation for this " +
        "specific error yet — here's Mermaid's own technical parser output, which names " +
        "the exact line and unexpected token:" + (docLine ? " (line " + docLine + " of your document)" : "");
      panel.appendChild(noTranslation);
    }

    var details = document.createElement("details");
    details.className = "fen-mermaid-error-technical";
    if (!friendly) details.setAttribute("open", "");
    var detailsSummary = document.createElement("summary");
    detailsSummary.textContent = "Show Mermaid's raw parser output";
    var message = document.createElement("pre");
    message.className = "fen-mermaid-error-message";
    message.textContent = (error && error.message) || String(error);
    details.appendChild(detailsSummary);
    details.appendChild(message);
    panel.appendChild(details);

    var help = document.createElement("p");
    help.className = "fen-mermaid-error-help";
    var helpLink = document.createElement("a");
    helpLink.href = "https://mermaid.js.org/intro/syntax-reference.html";
    helpLink.textContent = "mermaid.js.org/intro/syntax-reference.html";
    help.appendChild(document.createTextNode("Check the flagged line against Mermaid's syntax reference: "));
    help.appendChild(helpLink);
    panel.appendChild(help);

    var sourceDetails = document.createElement("details");
    sourceDetails.className = "fen-mermaid-error-source";
    var sourceSummary = document.createElement("summary");
    sourceSummary.textContent = "Show diagram source";
    var sourcePre = document.createElement("pre");
    sourcePre.textContent = graphSource;
    sourceDetails.appendChild(sourceSummary);
    sourceDetails.appendChild(sourcePre);
    panel.appendChild(sourceDetails);

    dom.innerHTML = "";
    dom.appendChild(panel);
  }

  var init = async function() {
    var domAll = document.querySelectorAll(".language-mermaid");
    for (var i = 0; i < domAll.length; i++) {
      var dom = domAll[i];
      var graphSource = dom.innerText || dom.textContent;

      dom = dom.parentElement;

      var result;
      try {
        result = await mermaid.render("graphDiv" + i, graphSource);
      } catch (error) {
        renderErrorPanel(dom, graphSource, error);
        continue;
      }

      var container = document.createElement("div");
      container.className = "fen-mermaid-container";

      var viewport = document.createElement("div");
      viewport.className = "fen-mermaid-viewport";

      var pan = document.createElement("div");
      pan.className = "fen-mermaid-pan";
      pan.innerHTML = result.svg;

      var controls = document.createElement("div");
      controls.className = "fen-mermaid-controls";
      controls.innerHTML =
        '<button type="button" class="fen-mermaid-zoom-out" title="Zoom out" aria-label="Zoom out">−</button>' +
        '<button type="button" class="fen-mermaid-zoom-reset" title="Reset zoom" aria-label="Reset zoom">⛶</button>' +
        '<button type="button" class="fen-mermaid-zoom-in" title="Zoom in" aria-label="Zoom in">+</button>';

      viewport.appendChild(pan);
      container.appendChild(controls);
      container.appendChild(viewport);

      dom.innerHTML = "";
      dom.appendChild(container);

      if (result.bindFunctions) {
        result.bindFunctions(pan);
      }
    }

    if (typeof window.__fenSetupMermaidZoom === "function") {
      window.__fenSetupMermaidZoom();
    }
  };

  if (typeof window.addEventListener != "undefined") {
    window.addEventListener("load", init, false);
  } else {
    window.attachEvent("onload", init);
  }
})();
