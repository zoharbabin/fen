// Adds pan/zoom controls to each rendered Mermaid diagram, scoped to that diagram's own
// wrapper so multiple diagrams in one document zoom independently of each other and of the
// surrounding text (the font-size preference explicitly excludes diagrams from its scaling).

(function () {
  var MIN_SCALE = 0.25;
  var MAX_SCALE = 4;
  var STEP = 0.25;

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function setupDiagram(container) {
    var viewport = container.querySelector(".fen-mermaid-viewport");
    var pan = container.querySelector(".fen-mermaid-pan");
    if (!viewport || !pan) {
      return;
    }

    // The viewport is a block box, so without an explicit height it shrink-wraps to the
    // pan div's unscaled layout height — `transform: scale()` only repaints pixels, it
    // never changes that layout size. Capture the natural height once, up front, before
    // any zoom is applied, so `apply()` can grow the viewport to match the zoomed-in
    // content instead of clipping it at the pre-zoom size.
    var naturalHeight = viewport.getBoundingClientRect().height;

    var scale = 1;
    var originX = 0;
    var originY = 0;
    var isDragging = false;
    var startX = 0;
    var startY = 0;

    function apply() {
      pan.style.transform = "translate(" + originX + "px, " + originY + "px) scale(" + scale + ")";
      var maxHeight = window.innerHeight * 0.8;
      viewport.style.height = Math.min(naturalHeight * scale, maxHeight) + "px";
    }

    function zoomBy(delta) {
      scale = clamp(scale + delta, MIN_SCALE, MAX_SCALE);
      apply();
    }

    function reset() {
      scale = 1;
      originX = 0;
      originY = 0;
      apply();
    }

    viewport.addEventListener(
      "wheel",
      function (event) {
        event.preventDefault();
        zoomBy(event.deltaY < 0 ? STEP : -STEP);
      },
      { passive: false }
    );

    viewport.addEventListener("mousedown", function (event) {
      isDragging = true;
      startX = event.clientX - originX;
      startY = event.clientY - originY;
      viewport.classList.add("fen-mermaid-dragging");
    });

    window.addEventListener("mousemove", function (event) {
      if (!isDragging) {
        return;
      }
      originX = event.clientX - startX;
      originY = event.clientY - startY;
      apply();
    });

    window.addEventListener("mouseup", function () {
      isDragging = false;
      viewport.classList.remove("fen-mermaid-dragging");
    });

    var zoomInButton = container.querySelector(".fen-mermaid-zoom-in");
    var zoomOutButton = container.querySelector(".fen-mermaid-zoom-out");
    var resetButton = container.querySelector(".fen-mermaid-zoom-reset");
    if (zoomInButton) {
      zoomInButton.addEventListener("click", function () {
        zoomBy(STEP);
      });
    }
    if (zoomOutButton) {
      zoomOutButton.addEventListener("click", function () {
        zoomBy(-STEP);
      });
    }
    if (resetButton) {
      resetButton.addEventListener("click", reset);
    }
  }

  // Called by mermaid.init.js once every diagram's SVG and wrapper controls exist.
  window.__fenSetupMermaidZoom = function () {
    var containers = document.querySelectorAll(".fen-mermaid-container");
    for (var i = 0; i < containers.length; i++) {
      setupDiagram(containers[i]);
    }
  };
})();
