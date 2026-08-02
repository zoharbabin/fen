// init highlight.js

(function () {
  // Wraps each source line of an already-highlighted <code> block in its own
  // <span class="fen-line">, walking the real tokenized DOM instead of string-splitting
  // innerHTML on "\n" (issue #124): a highlight.js grammar can match a token that spans
  // multiple visual lines (e.g. a run of "|"/"-" punctuation in ASCII art), and a raw
  // string split cuts through the middle of that token's <span>, corrupting the tag
  // structure the browser then silently "repairs" -- producing missing, duplicated, or
  // garbled line-number gutter cells. Walking the DOM and re-opening every still-open
  // ancestor span after each line break keeps every tag balanced by construction.
  function wrapLinesForLineNumbers(block) {
    var lines = [];
    var stack = [];
    var openClones = [];

    function currentInsertionPoint() {
      return openClones.length
        ? openClones[openClones.length - 1]
        : lines[lines.length - 1];
    }

    function startNewLine() {
      var lineRoot = document.createElement("span");
      lineRoot.className = "fen-line";
      lines.push(lineRoot);
      openClones = [];
      var parent = lineRoot;
      for (var i = 0; i < stack.length; i++) {
        var frame = stack[i];
        var el = document.createElement(frame.tag);
        for (var j = 0; j < frame.attrs.length; j++) {
          el.setAttribute(frame.attrs[j].name, frame.attrs[j].value);
        }
        parent.appendChild(el);
        openClones.push(el);
        parent = el;
      }
    }

    function walk(node) {
      if (node.nodeType === Node.TEXT_NODE) {
        var parts = node.textContent.split("\n");
        currentInsertionPoint().appendChild(document.createTextNode(parts[0]));
        for (var i = 1; i < parts.length; i++) {
          startNewLine();
          currentInsertionPoint().appendChild(document.createTextNode(parts[i]));
        }
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) {
        return;
      }
      var clone = document.createElement(node.tagName);
      for (var a = 0; a < node.attributes.length; a++) {
        clone.setAttribute(node.attributes[a].name, node.attributes[a].value);
      }
      currentInsertionPoint().appendChild(clone);
      stack.push({ tag: node.tagName, attrs: Array.prototype.slice.call(node.attributes) });
      openClones.push(clone);
      Array.prototype.slice.call(node.childNodes).forEach(walk);
      stack.pop();
      openClones.pop();
    }

    startNewLine();
    Array.prototype.slice.call(block.childNodes).forEach(walk);

    var lastLine = lines[lines.length - 1];
    if (lines.length > 1 && lastLine.textContent === "") {
      lines.pop();
    }

    block.textContent = "";
    lines.forEach(function (line) {
      block.appendChild(line);
    });
  }

  var init = function () {
    hljs.highlightAll();
    if (window.__fenLineNumbers) {
      document.querySelectorAll("pre code.hljs").forEach(function (block) {
        wrapLinesForLineNumbers(block);
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
