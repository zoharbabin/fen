// init mermaid

(function () {

  mermaid.initialize({
    startOnLoad: false,
    theme: window.__fenMermaidTheme || "default",
    flowchart: {
      htmlLabels: false,
      useMaxWidth: true
    }
  });

  var init = async function() {
    var domAll = document.querySelectorAll(".language-mermaid");
    for (var i = 0; i < domAll.length; i++) {
      var dom = domAll[i];
      var graphSource = dom.innerText || dom.textContent;

      dom = dom.parentElement;

      var result = await mermaid.render("graphDiv" + i, graphSource);

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
