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
      dom.innerHTML = result.svg;
      if (result.bindFunctions) {
        result.bindFunctions(dom);
      }
    }
  };

  if (typeof window.addEventListener != "undefined") {
    window.addEventListener("load", init, false);
  } else {
    window.attachEvent("onload", init);
  }
})();
