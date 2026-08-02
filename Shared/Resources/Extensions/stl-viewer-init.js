// Renders ASCII STL fenced code blocks (`language-stl`) as an interactive 3D viewer, using the
// vendored three.js + STLLoader + OrbitControls (issue #120). Each block gets its own
// Scene/Camera/Renderer/Controls instance scoped to its own container (rule 1.1) -- no shared
// module-level three.js state, so rotating one viewer never affects another's camera, and one
// document's viewers never affect another WKWebView's.
//
// STL source text is read via `.textContent` (never `.innerHTML`) and handed to
// `THREE.STLLoader.parse()` as a plain string, which only ever produces a `BufferGeometry` of
// numeric vertex/normal float arrays -- it never interprets its input as markup, so this can't
// become an injection vector even if the STL text itself contains HTML-special byte sequences
// (rule 2.1).
//
// Each viewer also gets a wireframe toggle button (issue #122) that flips its own material's
// `wireframe` flag in place -- no geometry re-parse, no shared state across viewers.

(function () {
  // Facet-count cap matching what a Markdown-embedded model realistically needs -- an ASCII STL
  // this large (1.5M+ float coordinates) risks a multi-second synchronous parse/render on the
  // main thread; falling back to a message instead keeps the rest of the document responsive
  // (rule 4.2).
  var MAX_FACETS = 500000;

  function renderErrorPanel(container, message) {
    var panel = document.createElement("div");
    panel.className = "fen-stl-error";
    var text = document.createElement("p");
    text.className = "fen-stl-error-message";
    // Set via textContent, never innerHTML -- the message may echo back a snippet of the
    // malformed source, which must never be interpreted as markup (rule 2.1).
    text.textContent = message;
    panel.appendChild(text);
    container.innerHTML = "";
    container.appendChild(panel);
  }

  function facetCount(geometry) {
    var position = geometry.attributes && geometry.attributes.position;
    return position ? Math.floor(position.count / 3) : 0;
  }

  // Toggling `material.wireframe` is a WebGLRenderer draw-mode switch (gl.LINES vs
  // gl.TRIANGLES), not a shader recompile -- it never touches `geometry`, so this can't
  // trigger a re-parse of the STL source or a new BufferGeometry (issue #122 rule 4.1).
  // `material` is captured from this viewer's own closure (issue #122 rule 1.1), so toggling
  // one viewer's button can never affect another viewer's material.
  function makeWireframeToggle(material) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "fen-stl-wireframe-toggle";
    button.title = "Show wireframe";
    button.setAttribute("aria-label", "Show wireframe");
    button.setAttribute("aria-pressed", "false");
    button.textContent = "▦";

    button.addEventListener("click", function () {
      var next = !material.wireframe;
      material.wireframe = next;
      button.setAttribute("aria-pressed", next ? "true" : "false");
      var label = next ? "Show shaded" : "Show wireframe";
      button.title = label;
      button.setAttribute("aria-label", label);
      button.classList.toggle("fen-stl-wireframe-toggle-active", next);
    });

    return button;
  }

  function setupViewer(pre) {
    var stlSource = pre.textContent;
    var container = document.createElement("div");
    container.className = "fen-stl-container";

    var geometry;
    try {
      geometry = new THREE.STLLoader().parse(stlSource);
    } catch (error) {
      renderErrorPanel(container, "This STL block couldn't be parsed -- it doesn't look like valid ASCII STL geometry.");
      pre.parentElement.replaceChild(container, pre);
      return Promise.resolve();
    }

    if (facetCount(geometry) > MAX_FACETS) {
      renderErrorPanel(container, "This model has too many facets to render inline (over " + MAX_FACETS.toLocaleString() + ").");
      pre.parentElement.replaceChild(container, pre);
      return Promise.resolve();
    }

    var canvas = document.createElement("canvas");
    container.appendChild(canvas);
    pre.parentElement.replaceChild(container, pre);

    try {
      var width = container.clientWidth || 600;
      var height = Math.round(width * 0.6);

      var scene = new THREE.Scene();
      var camera = new THREE.PerspectiveCamera(45, width / height, 0.1, 10000);
      var renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: true, preserveDrawingBuffer: true });
      renderer.setSize(width, height);

      geometry.computeBoundingSphere();
      var sphere = geometry.boundingSphere;
      var center = sphere ? sphere.center : new THREE.Vector3();
      var radius = sphere && sphere.radius > 0 ? sphere.radius : 1;

      // DoubleSide: STL files don't guarantee consistent outward-facing winding order, and the
      // default camera position isn't guaranteed to face a model's front side -- FrontSide (the
      // default) silently culls whichever faces point away from the camera, which can render as
      // an all-black frame for models where every triangle happens to be backwards from the
      // initial view.
      var material = new THREE.MeshNormalMaterial({ side: THREE.DoubleSide });
      var mesh = new THREE.Mesh(geometry, material);
      scene.add(mesh);

      // Exposes the parsed BufferGeometry so a test can confirm toggling wireframe (issue
      // #122 rule 4.1) never replaces it with a new one -- the material flip must be the
      // only thing that changes.
      canvas.__fenGeometry = geometry;

      // Attached only on this success path, never to a `.fen-stl-error` panel (issue #122
      // rule 2.2) -- a malformed/oversized block has no material to toggle, so it gets no
      // button rather than one that would do nothing.
      container.appendChild(makeWireframeToggle(material));

      camera.position.set(center.x, center.y, center.z + radius * 2.5);
      camera.lookAt(center);

      var controls = new THREE.OrbitControls(camera, renderer.domElement);
      controls.target.copy(center);
      controls.update();

      // Exposes each canvas's own orbit-change count, scoped to that element -- proves rule 1.1
      // (no shared camera/controls state across viewers) without depending on a real animation
      // frame, which an offscreen/backgrounded WKWebView may never fire.
      canvas.__fenOrbitChangeCount = 0;
      controls.addEventListener("change", function () {
        canvas.__fenOrbitChangeCount++;
      });

      var frameHandle = null;
      function animate() {
        frameHandle = requestAnimationFrame(animate);
        controls.update();
        renderer.render(scene, camera);
      }
      animate();

      // Stops the render loop once its canvas is no longer in the document -- e.g. the user
      // switched to a different file in the same preview WKWebView (rule 1.1: cleans up its
      // own state, doesn't rely on any other viewer or global to do it).
      new MutationObserver(function () {
        if (!document.body.contains(canvas)) {
          cancelAnimationFrame(frameHandle);
          this.disconnect();
        }
      }).observe(document.body, { childList: true, subtree: true });

      return new Promise(function (resolve) {
        requestAnimationFrame(function () {
          renderer.render(scene, camera);
          resolve();
        });
      });
    } catch (error) {
      renderErrorPanel(container, "This STL model couldn't be rendered -- your browser's WebGL context may be unavailable.");
      return Promise.resolve();
    }
  }

  var init = function () {
    var blocks = document.querySelectorAll("pre > code.language-stl");
    var readyPromises = [];
    for (var i = 0; i < blocks.length; i++) {
      readyPromises.push(setupViewer(blocks[i].parentElement));
    }
    return Promise.all(readyPromises);
  };

  // Exposes when every viewer has finished its first paint (or errored) -- mirrors
  // `window.__fenMermaidReadyPromise`, awaited alongside it by
  // `HTMLComposer.renderCompletionTags` before `PDFRenderer` captures the page, so export/print
  // never races the viewers' async first frame.
  window.__fenSTLReadyPromise = new Promise(function (resolve) {
    if (typeof window.addEventListener != "undefined") {
      window.addEventListener("load", function () {
        init().then(resolve, resolve);
      }, false);
    } else {
      window.attachEvent("onload", function () {
        init().then(resolve, resolve);
      });
    }
  });
})();
