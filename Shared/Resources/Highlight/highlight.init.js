// init highlight.js

(function () {
  var init = function () {
    hljs.highlightAll();
    if (window.__fenLineNumbers) {
      document.querySelectorAll("pre code.hljs").forEach(function (block) {
        var lines = block.innerHTML.split("\n");
        if (lines.length > 1 && lines[lines.length - 1] === "") {
          lines.pop();
        }
        block.innerHTML = lines
          .map(function (line) {
            return '<span class="fen-line">' + line + "</span>";
          })
          .join("\n");
        block.classList.add("fen-line-numbers");
      });
    }
  };

  if (typeof window.addEventListener != "undefined") {
    window.addEventListener("load", init, false);
  } else {
    window.attachEvent("onload", init);
  }
})();
