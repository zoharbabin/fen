// Copy-to-clipboard button on code blocks (issue #28).
//
// navigator.clipboard.writeText is unavailable here: this script only ever runs inside a
// WKWebView loaded through the fen-preview:// custom URL scheme, which WebKit does not
// treat as a secure context (confirmed directly: window.isSecureContext is false and
// typeof navigator.clipboard is "undefined" in this app). The execCommand('copy') fallback
// via a temporary, off-screen, focused, selected <textarea> is deprecated but still fully
// functional in WebKit, and is the only clipboard-write path available in this context.

(function () {
  var COPIED_LABEL = "Copied";
  var COPIED_RESET_MS = 1500;

  function copyText(text) {
    var textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.style.position = "fixed";
    textarea.style.left = "-9999px";
    textarea.style.top = "0";
    document.body.appendChild(textarea);
    textarea.focus();
    textarea.select();
    var succeeded = false;
    try {
      succeeded = document.execCommand("copy");
    } catch (e) {
      succeeded = false;
    }
    document.body.removeChild(textarea);
    return succeeded;
  }

  function makeButton(pre) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "fen-copy-button";
    button.title = "Copy code";
    button.setAttribute("aria-label", "Copy code");
    button.textContent = "Copy";

    button.addEventListener("click", function () {
      // Not pre.textContent: highlight.init.js's line-numbers mode (see that file) wraps each
      // line in its own display:block <span class="fen-line"> joined with no separator, so
      // textContent would silently concatenate every line into one. innerText respects
      // rendered block-level boundaries and inserts a line break at each one, matching what
      // the user actually sees.
      var succeeded = copyText(pre.innerText);
      if (!succeeded) {
        return;
      }
      var originalLabel = button.textContent;
      button.textContent = COPIED_LABEL;
      button.classList.add("fen-copy-button-copied");
      window.setTimeout(function () {
        button.textContent = originalLabel;
        button.classList.remove("fen-copy-button-copied");
      }, COPIED_RESET_MS);
    });

    return button;
  }

  function init() {
    document.querySelectorAll("pre").forEach(function (pre) {
      if (pre.closest(".fen-code-block-container")) {
        return;
      }
      var container = document.createElement("div");
      container.className = "fen-code-block-container";
      pre.parentNode.insertBefore(container, pre);
      container.appendChild(pre);
      container.appendChild(makeButton(pre));
    });
  }

  if (typeof window.addEventListener != "undefined") {
    window.addEventListener("load", init, false);
  } else {
    window.attachEvent("onload", init);
  }
})();
