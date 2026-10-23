// Find in the preview (issue #255). Swift does the matching (FindEngine), so editor and preview share one
// matcher. This script does the two jobs only the page can do: turn the rendered text into one string, and
// paint match offsets with the CSS Custom Highlight API. It never changes the DOM, so data-sourcepos anchors
// and scroll sync are untouched.
(function () {
    'use strict';
    if (window.__fenFind) { return; }

    var MAX_PAINTED = 5000;
    var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, TEXTAREA: 1, OPTION: 1, BUTTON: 1 };
    var BLOCK = 'p,li,td,th,tr,div,h1,h2,h3,h4,h5,h6,pre,blockquote,ul,ol,table,section,article,figure,' +
        'figcaption,dt,dd,details,summary,header,footer,hr,body,.fen-line';

    var supported = typeof Highlight === 'function' && !!(window.CSS && CSS.highlights);
    var segments = [];      // { node, start (offset in node data), length (in data), flat (offset in text), flatLength }
    var flat = '';
    var version = 0;
    var dirty = true;
    var offsets = [];       // flat [start, end, start, end ...]
    var current = -1;
    var style = null;

    function ensureStyle() {
        if (style) { return; }
        style = document.createElement('style');
        style.setAttribute('data-fen-find', '');
        style.textContent =
            '::highlight(fen-find) { background-color: rgba(255, 214, 10, 0.45); color: inherit; }' +
            '::highlight(fen-find-current) { background-color: rgba(255, 149, 0, 0.8); color: inherit; }';
        (document.head || document.documentElement).appendChild(style);
    }

    function skipped(node) {
        for (var el = node.parentElement; el; el = el.parentElement) {
            if (SKIP[el.tagName] || el.hasAttribute('hidden')) { return true; }
            var tag = el.tagName.toLowerCase();
            if (tag === 'mjx-assistive-mml') { return true; }
        }
        return false;
    }

    function isPre(node) {
        for (var el = node.parentElement; el; el = el.parentElement) {
            if (el.tagName === 'PRE' || el.tagName === 'CODE' && el.parentElement && el.parentElement.tagName === 'PRE') {
                return true;
            }
        }
        return false;
    }

    // One string for the whole page. Text in different blocks is separated by a newline, so a match can run
    // across <em>/<a>/<code> but not from one paragraph into the next. Runs of whitespace collapse to one
    // space outside <pre>, as the page renders them.
    function build() {
        segments = [];
        var parts = [];
        var length = 0;
        var lastChar = '\n';
        var lastBlock = null;
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, null);
        var node;
        while ((node = walker.nextNode())) {
            if (node.nodeType === Node.ELEMENT_NODE) {
                if (node.tagName === 'BR') { parts.push('\n'); length += 1; lastChar = '\n'; }
                continue;
            }
            if (skipped(node)) { continue; }
            var data = node.data;
            if (!data.length) { continue; }
            var parent = node.parentElement;
            var block = parent ? parent.closest(BLOCK) : null;
            if (block !== lastBlock && length > 0 && lastChar !== '\n') {
                parts.push('\n');
                length += 1;
                lastChar = '\n';
            }
            lastBlock = block;
            if (isPre(node)) {
                segments.push({ node: node, start: 0, length: data.length, flat: length, flatLength: data.length });
                parts.push(data);
                length += data.length;
                lastChar = data.charAt(data.length - 1);
                continue;
            }
            var i = 0;
            while (i < data.length) {
                var code = data.charCodeAt(i);
                var isSpace = code === 32 || code === 10 || code === 9 || code === 13 || code === 12;
                var j = i + 1;
                if (isSpace) {
                    while (j < data.length) {
                        var c = data.charCodeAt(j);
                        if (!(c === 32 || c === 10 || c === 9 || c === 13 || c === 12)) { break; }
                        j += 1;
                    }
                    // Drop a space that follows a space or a newline: the page shows one gap.
                    if (lastChar === ' ' || lastChar === '\n') { i = j; continue; }
                    segments.push({ node: node, start: i, length: j - i, flat: length, flatLength: 1 });
                    parts.push(' ');
                    length += 1;
                    lastChar = ' ';
                } else {
                    while (j < data.length) {
                        var d = data.charCodeAt(j);
                        if (d === 32 || d === 10 || d === 9 || d === 13 || d === 12) { break; }
                        j += 1;
                    }
                    segments.push({ node: node, start: i, length: j - i, flat: length, flatLength: j - i });
                    parts.push(data.substring(i, j));
                    length += j - i;
                    lastChar = data.charAt(j - 1);
                }
                i = j;
            }
        }
        flat = parts.join('');
        dirty = false;
        version += 1;
    }

    function ensureBuilt() {
        if (dirty) { build(); }
    }

    // Index of the first segment whose flat range ends after `position`.
    function segmentIndexAt(position) {
        var low = 0;
        var high = segments.length - 1;
        while (low < high) {
            var mid = (low + high) >> 1;
            var seg = segments[mid];
            if (seg.flat + seg.flatLength <= position) { low = mid + 1; } else { high = mid; }
        }
        return low;
    }

    // The DOM position for a flat offset. A flat offset can sit on a newline this script inserted between
    // blocks. A start there moves to the next text, an end there moves back to the end of the previous text.
    function point(position, isEnd) {
        if (!segments.length) { return null; }
        var probe = isEnd ? position - 1 : position;
        var index = segmentIndexAt(probe);
        var seg = segments[index];
        if (probe < seg.flat) {
            if (!isEnd) { return { node: seg.node, offset: seg.start }; }
            if (index === 0) { return null; }
            seg = segments[index - 1];
            return { node: seg.node, offset: seg.start + seg.length };
        }
        if (probe >= seg.flat + seg.flatLength) {
            return isEnd ? { node: seg.node, offset: seg.start + seg.length } : null;
        }
        if (seg.flatLength !== seg.length) {
            // A collapsed run of whitespace: the start of the run, or its end.
            return { node: seg.node, offset: seg.start + (isEnd ? seg.length : 0) };
        }
        var within = probe - seg.flat;
        return { node: seg.node, offset: seg.start + within + (isEnd ? 1 : 0) };
    }

    function rangeFor(index) {
        var a = point(offsets[index * 2], false);
        var b = point(offsets[index * 2 + 1], true);
        if (!a || !b) { return null; }
        try {
            return new StaticRange({ startContainer: a.node, startOffset: a.offset, endContainer: b.node, endOffset: b.offset });
        } catch (e) {
            return null;
        }
    }

    function count() { return offsets.length / 2; }

    function paint() {
        if (!supported) { return; }
        ensureStyle();
        var total = count();
        var first = 0;
        var last = total;
        if (total > MAX_PAINTED) {
            first = Math.max(0, Math.min(total - MAX_PAINTED, Math.max(current, 0) - (MAX_PAINTED >> 1)));
            last = first + MAX_PAINTED;
        }
        var all = [];
        for (var i = first; i < last; i += 1) {
            if (i === current) { continue; }
            var r = rangeFor(i);
            if (r) { all.push(r); }
        }
        CSS.highlights.set('fen-find', new Highlight(...all));
        var currentRange = current >= 0 && current < total ? rangeFor(current) : null;
        if (currentRange) {
            CSS.highlights.set('fen-find-current', new Highlight(currentRange));
        } else {
            CSS.highlights.delete('fen-find-current');
        }
    }

    function openAncestors(node) {
        for (var el = node.parentElement; el; el = el.parentElement) {
            if (el.tagName === 'DETAILS' && !el.open) { el.open = true; }
        }
    }

    // Scrolls only when the current match is outside the visible area, and keeps it clear of the edges.
    function reveal() {
        var r = current >= 0 ? rangeFor(current) : null;
        if (!r) { return; }
        openAncestors(r.startContainer);
        var live = document.createRange();
        live.setStart(r.startContainer, r.startOffset);
        live.setEnd(r.endContainer, r.endOffset);
        var rect = live.getBoundingClientRect();
        var height = window.innerHeight;
        var margin = Math.min(80, height / 4);
        if (rect.top < margin || rect.bottom > height - margin) {
            window.scrollTo({ top: window.scrollY + rect.top - height / 3, behavior: 'instant' });
        }
    }

    // The page changes after load when math or diagrams finish. While a search is open, tell Swift so the
    // offsets are recomputed instead of painting on text that moved.
    var active = false;
    var notifyTimer = null;
    new MutationObserver(function () {
        dirty = true;
        if (!active || notifyTimer) { return; }
        notifyTimer = setTimeout(function () {
            notifyTimer = null;
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.findHandler) {
                window.webkit.messageHandlers.findHandler.postMessage('changed');
            }
        }, 200);
    }).observe(document.body, { childList: true, subtree: true, characterData: true });

    window.__fenFind = {
        supported: supported,

        // The page text, or null when `known` is still current. Swift keeps the text between searches.
        snapshot: function (known) {
            active = true;
            ensureBuilt();
            return { version: version, text: known === version ? null : flat };
        },

        // Paints `list` (flat start/end pairs) if the page is still the one Swift searched. Returns the new
        // version when it changed, so Swift searches again; otherwise null.
        show: function (list, atVersion, currentIndex, scroll) {
            active = true;
            ensureBuilt();
            if (atVersion !== version) { return version; }
            offsets = list;
            current = currentIndex;
            paint();
            if (scroll) { reveal(); }
            return null;
        },

        setCurrent: function (index, scroll) {
            current = index;
            paint();
            if (scroll) { reveal(); }
        },

        clear: function () {
            active = false;
            offsets = [];
            current = -1;
            if (supported) {
                CSS.highlights.delete('fen-find');
                CSS.highlights.delete('fen-find-current');
            }
        },

        // Vertical positions (0...1 of the page height) of up to `limit` matches, for the scrollbar strip.
        positions: function (limit) {
            var total = count();
            var step = Math.max(1, Math.ceil(total / limit));
            var height = Math.max(1, document.documentElement.scrollHeight);
            var result = [];
            for (var i = 0; i < total; i += step) {
                var r = rangeFor(i);
                if (!r) { continue; }
                var live = document.createRange();
                live.setStart(r.startContainer, r.startOffset);
                live.setEnd(r.endContainer, r.endOffset);
                var rect = live.getBoundingClientRect();
                result.push(Math.max(0, Math.min(1, (rect.top + window.scrollY) / height)));
            }
            return result;
        },

        // The text a match covers on the page, for tests and the accessibility announcement.
        textOf: function (index) {
            return index >= 0 && index < count() ? flat.substring(offsets[index * 2], offsets[index * 2 + 1]) : null;
        }
    };
})();
