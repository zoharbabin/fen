// Renders `language-geojson`/`language-topojson` fenced code blocks as an interactive Leaflet.js
// map with a live OpenStreetMap tile basemap (issue #121) -- Fen's first-ever runtime network
// call, gated behind the `htmlGeoJSONMaps` preference (off by default) and only loaded when a
// matching block is actually present (see `HTMLComposer.geoJSONMapTags`).
//
// Each block gets its own `L.map()` instance scoped to its own container -- no shared
// module-level Leaflet state, so panning/zooming one map never affects another (rule 1.1).
//
// Source text is parsed via `JSON.parse`, never `eval`, so malformed content can only ever
// produce a thrown exception, not code execution (rule 2.1). TopoJSON is converted to GeoJSON
// via the vendored `topojson-client` before sharing the exact same render path as a native
// GeoJSON block (rule 5.1).
//
// Feature `properties` used for popup content (simplestyle-spec's `title`/`description`, or a
// fallback listing of all properties) are inserted via `textContent`, never `innerHTML` or a
// Leaflet `bindPopup(string)` call -- Leaflet only ever receives a plain `HTMLElement` built by
// this file, so no property value can execute as markup (rule 2.2).

(function () {
  // Matches a realistic large GeoJSON/TopoJSON payload (e.g. a detailed national boundary file)
  // while keeping the synchronous JSON.parse + Leaflet layer build off the main thread's danger
  // zone -- falls back to a message instead of risking a multi-second hang (rule 4.2).
  var MAX_SOURCE_LENGTH = 5 * 1024 * 1024;

  // `window.__fenGeoJSONTileURLOverride` lets tests point at an unreachable host to prove
  // shapes/markers still render when the tile fetch fails (rule 3.1), without any test making a
  // real request to OpenStreetMap's tile servers.
  var TILE_URL = window.__fenGeoJSONTileURLOverride || "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
  var TILE_ATTRIBUTION =
    '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';

  function renderErrorPanel(container, message) {
    var panel = document.createElement("div");
    panel.className = "fen-geojson-error";
    var text = document.createElement("p");
    text.className = "fen-geojson-error-message";
    // Set via textContent, never innerHTML -- the message may echo back a snippet of the
    // malformed source, which must never be interpreted as markup (rule 2.1).
    text.textContent = message;
    panel.appendChild(text);
    container.innerHTML = "";
    container.appendChild(panel);
  }

  // TopoJSON files name their layers arbitrarily under `objects`; there's no single "the"
  // layer, so every object is converted and merged into one FeatureCollection, matching how a
  // multi-layer TopoJSON renders when opened directly with topojson-client + Leaflet elsewhere.
  function toGeoJSON(parsed) {
    if (parsed.type === "Topology") {
      var features = [];
      var objectNames = Object.keys(parsed.objects || {});
      for (var i = 0; i < objectNames.length; i++) {
        var converted = topojson.feature(parsed, parsed.objects[objectNames[i]]);
        if (converted.type === "FeatureCollection") {
          features = features.concat(converted.features);
        } else {
          features.push(converted);
        }
      }
      return { type: "FeatureCollection", features: features };
    }
    return parsed;
  }

  // Builds the popup content element from a feature's `properties` -- simplestyle-spec's
  // `title`/`description` win when present, otherwise every property is listed as a fallback,
  // so a feature with neither still shows something useful instead of an empty popup.
  function buildPopupContent(properties) {
    var wrapper = document.createElement("div");
    wrapper.className = "fen-geojson-popup";
    if (!properties || Object.keys(properties).length === 0) {
      return null;
    }

    if (properties.title) {
      var title = document.createElement("p");
      title.className = "fen-geojson-popup-title";
      title.textContent = String(properties.title);
      wrapper.appendChild(title);
    }
    if (properties.description) {
      var description = document.createElement("p");
      description.textContent = String(properties.description);
      wrapper.appendChild(description);
    }
    if (!properties.title && !properties.description) {
      var list = document.createElement("ul");
      var keys = Object.keys(properties);
      for (var i = 0; i < keys.length; i++) {
        var item = document.createElement("li");
        item.textContent = keys[i] + ": " + String(properties[keys[i]]);
        list.appendChild(item);
      }
      wrapper.appendChild(list);
    }
    return wrapper;
  }

  // simplestyle-spec styling: https://github.com/mapbox/simplestyle-spec -- the same properties
  // GitHub's own GeoJSON renderer honors, so a block styled for GitHub looks the same in Fen.
  function styleForFeature(feature) {
    var props = feature.properties || {};
    return {
      color: props.stroke || "#3388ff",
      weight: props["stroke-width"] != null ? props["stroke-width"] : 2,
      opacity: props["stroke-opacity"] != null ? props["stroke-opacity"] : 1,
      fillColor: props.fill || props.stroke || "#3388ff",
      fillOpacity: props["fill-opacity"] != null ? props["fill-opacity"] : 0.2,
    };
  }

  function pointToLayer(feature, latlng) {
    var props = feature.properties || {};
    if (props["marker-color"]) {
      return L.circleMarker(latlng, {
        radius: 8,
        color: props["marker-color"],
        fillColor: props["marker-color"],
        fillOpacity: 0.8,
      });
    }
    return L.marker(latlng);
  }

  function setupMap(pre) {
    var source = pre.textContent;
    var container = document.createElement("div");
    container.className = "fen-geojson-container";

    if (source.length > MAX_SOURCE_LENGTH) {
      renderErrorPanel(
        container,
        "This block is too large to render inline (over " + MAX_SOURCE_LENGTH.toLocaleString() + " characters)."
      );
      pre.parentElement.replaceChild(container, pre);
      return Promise.resolve();
    }

    var geojson;
    try {
      geojson = toGeoJSON(JSON.parse(source));
    } catch (error) {
      renderErrorPanel(container, "This block couldn't be parsed -- it doesn't look like valid GeoJSON or TopoJSON.");
      pre.parentElement.replaceChild(container, pre);
      return Promise.resolve();
    }

    var mapEl = document.createElement("div");
    mapEl.className = "fen-geojson-map";
    container.appendChild(mapEl);
    pre.parentElement.replaceChild(container, pre);

    try {
      var map = L.map(mapEl, { scrollWheelZoom: false });
      L.tileLayer(TILE_URL, { attribution: TILE_ATTRIBUTION, maxZoom: 19 }).addTo(map);

      var layer = L.geoJSON(geojson, {
        style: styleForFeature,
        pointToLayer: pointToLayer,
        onEachFeature: function (feature, featureLayer) {
          var popupContent = buildPopupContent(feature.properties);
          if (popupContent) {
            featureLayer.bindPopup(popupContent);
          }
        },
      }).addTo(map);

      var bounds = layer.getBounds();
      if (bounds.isValid()) {
        map.fitBounds(bounds, { padding: [16, 16] });
      } else {
        map.setView([0, 0], 1);
      }

      return new Promise(function (resolve) {
        map.whenReady(resolve);
      });
    } catch (error) {
      renderErrorPanel(container, "This map couldn't be rendered.");
      return Promise.resolve();
    }
  }

  var init = function () {
    var blocks = document.querySelectorAll("pre > code.language-geojson, pre > code.language-topojson");
    var readyPromises = [];
    for (var i = 0; i < blocks.length; i++) {
      readyPromises.push(setupMap(blocks[i].parentElement));
    }
    return Promise.all(readyPromises);
  };

  // Mirrors `window.__fenSTLReadyPromise`/`window.__fenMermaidReadyPromise`, awaited by
  // `HTMLComposer.renderCompletionTags` before `PDFRenderer` captures the page, so export/print
  // never races a map's async tile load.
  window.__fenGeoJSONReadyPromise = new Promise(function (resolve) {
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
