import Foundation
import WebKit
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Pictures of rendered blocks for Live Preview (issue #135, phase 3). A block renders once in an offscreen web
/// view, one at a time, and the picture is cached until the block, the width or the appearance changes. A block
/// that fails to render is remembered, so its source stays visible and nothing retries on every keystroke.
@MainActor
final class LivePreviewSnapshots {
    struct Key: Hashable {
        var kind: RenderedBlock.Kind
        var source: String
        /// A multiple of `widthStep`, so a small resize doesn't ask for a new picture.
        var width: Int
        var dark: Bool
        /// The preview settings the picture depends on, so a new style or custom CSS draws it again.
        var look: Int = 0
    }

    /// A rendered picture. `baseline` is the distance from its top to the text baseline, which only inline math has.
    struct Picture {
        var image: PlatformImage
        var baseline: CGFloat = 0
    }

    typealias Render = @MainActor (Key) async -> Picture?

    static let widthStep: CGFloat = 40
    static let maxSourceLength = 20000
    /// Inline math is laid out at one fixed width, so a resize never asks for a new picture.
    static let inlineWidth = 800
    static let maxInlineLength = 500

    /// Tests swap this for a stub.
    static var shared = LivePreviewSnapshots(
        kinds: { enabledKinds() },
        render: { key in await LivePreviewWebSnapshot.render(key, preferences: .shared) }
    )

    /// Which kinds of block are drawn as pictures right now.
    let kinds: @MainActor () -> Set<RenderedBlock.Kind>
    private let render: Render
    private let limit: Int
    /// How many inline formulas stay cached. They are small, and a note can hold many.
    private let inlineLimit: Int
    private var cache: [Key: Picture] = [:]
    private var recent: [Key] = []
    private var failed: Set<Key> = []
    private var queue: [Key] = []
    private var waiting: [Key: [ObjectIdentifier: @MainActor () -> Void]] = [:]
    private var isRunning = false

    init(
        limit: Int = 32, inlineLimit: Int = 512,
        kinds: @escaping @MainActor () -> Set<RenderedBlock.Kind>, render: @escaping Render
    ) {
        self.limit = limit
        self.inlineLimit = inlineLimit
        self.kinds = kinds
        self.render = render
    }

    /// For renderers that draw only a picture.
    convenience init(
        limit: Int = 32, inlineLimit: Int = 512,
        kinds: @escaping @MainActor () -> Set<RenderedBlock.Kind>,
        render: @escaping @MainActor (Key) async -> PlatformImage?
    ) {
        self.init(limit: limit, inlineLimit: inlineLimit, kinds: kinds) { key in
            await render(key).map { Picture(image: $0) }
        }
    }

    /// The kinds the preview settings turn on. A block whose renderer is off stays source, as in the preview.
    static func enabledKinds(_ preferences: Preferences = .shared) -> Set<RenderedBlock.Kind> {
        var kinds: Set<RenderedBlock.Kind> = []
        if preferences.htmlMermaid {
            kinds.insert(.mermaid)
        }
        if preferences.htmlMathJax {
            kinds.insert(.math)
            kinds.insert(.inlineMath)
        }
        if preferences.htmlGeoJSONMaps {
            kinds.insert(.map)
        }
        return kinds
    }

    /// The width a picture is rendered at for a column `columnWidth` wide: the column, rounded down to a step.
    static func pictureWidth(forColumn columnWidth: CGFloat) -> Int {
        Int(max((columnWidth / widthStep).rounded(.down), 4) * widthStep)
    }

    /// A number that changes when a preview setting that changes a picture changes.
    static func look(_ preferences: Preferences) -> Int {
        var hasher = Hasher()
        hasher.combine(preferences.htmlStyleName)
        hasher.combine(preferences.fontSize)
        hasher.combine(preferences.customCSSEnabled ? preferences.customCSS : "")
        return hasher.finalize()
    }

    /// The inline math delimiters to look for: none when math is off, `$ $` only when the preview reads them.
    static func mathDelimiters(
        _ kinds: Set<RenderedBlock.Kind>, preferences: Preferences = .shared
    ) -> LivePreviewEditing.MathDelimiters {
        guard kinds.contains(.inlineMath) else { return [] }
        return preferences.htmlMathJaxInlineDollar ? [.parentheses, .dollars] : .parentheses
    }

    /// The key of the formula `source`, delimiters included.
    static func key(
        forFormula source: String, background: PlatformColor, preferences: Preferences = .shared
    ) -> Key? {
        guard source.count <= maxInlineLength else { return nil }
        return Key(
            kind: .inlineMath,
            source: source,
            width: inlineWidth,
            dark: LivePreviewBlockStyle.luminance(of: background) < 0.5,
            look: look(preferences)
        )
    }

    static func key(
        for block: RenderedBlock, columnWidth: CGFloat, background: PlatformColor, preferences: Preferences = .shared
    ) -> Key? {
        guard block.source.count <= maxSourceLength else { return nil }
        return Key(
            kind: block.kind,
            source: block.source,
            width: pictureWidth(forColumn: columnWidth),
            dark: LivePreviewBlockStyle.luminance(of: background) < 0.5,
            look: look(preferences)
        )
    }

    func image(for key: Key) -> PlatformImage? {
        picture(for: key)?.image
    }

    func picture(for key: Key) -> Picture? {
        guard let picture = cache[key] else { return nil }
        recent.removeAll { $0 == key }
        recent.append(key)
        return picture
    }

    /// The newest picture of the same block at another width or look, with the same light or dark. It stands in
    /// while `key` renders, so a resize or a style change doesn't flash the source.
    func standIn(for key: Key) -> Picture? {
        guard let match = recent.last(where: {
            $0.kind == key.kind && $0.source == key.source && $0.dark == key.dark
        }) else { return nil }
        return cache[match]
    }

    /// The picture for `key` if there is one, or an older picture of the same source that stands in. A missing
    /// picture is requested, and `onReady` runs when it arrives. `nil` means the source stays as it is.
    func resolve(_ key: Key, owner: AnyObject, onReady: @escaping @MainActor () -> Void) -> Picture? {
        if let cached = picture(for: key) {
            return cached
        }
        request(key, owner: owner, onReady: onReady)
        return standIn(for: key)
    }

    func hasFailed(_ key: Key) -> Bool {
        failed.contains(key)
    }

    /// Renders `key` unless it is cached, failed or already queued. `onReady` runs once when the picture is
    /// cached, and never for a failure. One callback per `owner` and key: asking again replaces the earlier one.
    func request(_ key: Key, owner: AnyObject, onReady: @escaping @MainActor () -> Void) {
        guard cache[key] == nil, !failed.contains(key) else { return }
        let isNew = waiting[key] == nil
        waiting[key, default: [:]][ObjectIdentifier(owner)] = onReady
        if isNew {
            queue.append(key)
            pump()
        }
    }

    private func pump() {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        let key = queue.removeFirst()
        Task { @MainActor in
            let picture = await render(key)
            let callbacks = waiting.removeValue(forKey: key).map { Array($0.values) } ?? []
            isRunning = false
            if let picture, picture.image.size.width > 0, picture.image.size.height > 0 {
                cache[key] = picture
                recent.append(key)
                evict(inline: key.kind == .inlineMath)
                for callback in callbacks {
                    callback()
                }
            } else {
                failed.insert(key)
            }
            pump()
        }
    }

    /// Drops the oldest pictures of one class (blocks or formulas) beyond its limit.
    private func evict(inline: Bool) {
        let cap = inline ? inlineLimit : limit
        var count = recent.filter { ($0.kind == .inlineMath) == inline }.count
        while count > cap, let oldest = recent.firstIndex(where: { ($0.kind == .inlineMath) == inline }) {
            cache[recent.remove(at: oldest)] = nil
            count -= 1
        }
    }
}

/// Renders a block's Markdown through the same pipeline as export, so the picture matches the preview.
@MainActor
enum LivePreviewWebSnapshot {
    private static let timeout = Duration.seconds(20)
    /// The tallest picture, in points. A taller block is scaled down to this height, not cut off.
    static let maxPictureHeight: CGFloat = 1600
    /// The tallest block we lay out and snapshot. WebKit can't draw much more than this in one piece.
    private static let maxMeasuredHeight: CGFloat = 16000

    /// The width of the picture for a block `width` wide and `height` tall: `width`, or less when the block is
    /// taller than `maxPictureHeight`, which keeps its proportions.
    static func pictureWidth(blockWidth width: CGFloat, blockHeight height: CGFloat) -> CGFloat {
        guard height > maxPictureHeight else { return width }
        return max((width * maxPictureHeight / height).rounded(.down), 1)
    }

    static func render(_ key: LivePreviewSnapshots.Key, preferences: Preferences) async -> LivePreviewSnapshots
        .Picture? {
        if key.kind == .inlineMath {
            return await renderFormula(key, preferences: preferences)
        }
        let rendered = MarkdownRenderer().render(key.source, options: .from(preferences: preferences))
        let html = HTMLComposer().composeForExport(
            title: nil,
            body: rendered.html,
            preferences: preferences,
            includeStyles: true,
            includeHighlighting: false,
            appearanceOverride: key.dark ? .dark : .light
        )
        let size = CGSize(width: key.width, height: 20)
        guard let webView = try? await PDFRenderer()
            .loadOffscreenWebView(html: html, baseDirectory: nil, loadTimeout: timeout, size: size)
        else { return nil }
        makeTransparent(webView)
        guard let height = await prepare(webView, kind: key.kind) else { return nil }
        webView.frame.size.height = height
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: key.width, height: Int(height))
        configuration.snapshotWidth = NSNumber(
            value: pictureWidth(blockWidth: CGFloat(key.width), blockHeight: height)
        )
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
        return LivePreviewSnapshots.Picture(image: image)
    }

    /// Renders one formula in a line of its own and crops to it. The baseline comes from an empty inline box set
    /// right before the formula: the bottom of that box sits on the text baseline.
    private static func renderFormula(
        _ key: LivePreviewSnapshots.Key, preferences: Preferences
    ) async -> LivePreviewSnapshots.Picture? {
        let escaped = key.source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let body = "<p style=\"margin:0;white-space:nowrap\"><span id=\"fen-baseline\" "
            + "style=\"display:inline-block;width:0;height:0\"></span><span id=\"fen-formula\">\(escaped)</span></p>"
        let html = HTMLComposer().composeForExport(
            title: nil,
            body: body,
            preferences: preferences,
            includeStyles: true,
            includeHighlighting: false,
            appearanceOverride: key.dark ? .dark : .light
        )
        guard let webView = try? await PDFRenderer().loadOffscreenWebView(
            html: html, baseDirectory: nil, loadTimeout: timeout, size: CGSize(width: key.width, height: 20)
        ) else { return nil }
        makeTransparent(webView)
        let script = """
        (function () {
            document.documentElement.style.setProperty('background', 'transparent', 'important');
            var s = document.body.style;
            s.setProperty('background', 'transparent', 'important');
            s.setProperty('margin', '0', 'important');
            s.setProperty('padding', '0', 'important');
            s.setProperty('max-width', 'none', 'important');
            var math = document.querySelector('#fen-formula mjx-container svg');
            if (!math || document.querySelector('mjx-merror, [data-mml-node=merror], mtext[mathcolor=red]')) { return null; }
            var box = math.getBoundingClientRect();
            var baseline = document.getElementById('fen-baseline').getBoundingClientRect().bottom;
            return [box.left, box.top, box.width, box.height, baseline];
        })()
        """
        guard let values = try? await webView.evaluateJavaScript(script) as? [Double], values.count == 5,
              values[2] > 0, values[3] > 0 else { return nil }
        let rect = CGRect(
            x: floor(values[0]),
            y: floor(values[1]),
            width: ceil(values[2]) + 1,
            height: ceil(values[3]) + 1
        )
        webView.frame.size.height = max(rect.maxY, 1)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(rect.width))
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
        return LivePreviewSnapshots.Picture(image: image, baseline: CGFloat(values[4]) - rect.minY)
    }

    /// Strips the page chrome and measures what is left. `nil` when the renderer left an error or nothing.
    private static func prepare(_ webView: WKWebView, kind: RenderedBlock.Kind) async -> CGFloat? {
        let check = switch kind {
        case .mermaid: "!!document.querySelector('svg') && !document.body.innerText.includes('Syntax error')"
        case .math: "!!document.querySelector('mjx-container') && !document.querySelector('mjx-merror, [data-mml-node=merror], mtext[mathcolor=red]')"
        case .map: "!!document.querySelector('.leaflet-container')"
        case .inlineMath: "false"
        }
        let script = """
        (function () {
            document.documentElement.style.setProperty('background', 'transparent', 'important');
            var s = document.body.style;
            s.setProperty('background', 'transparent', 'important');
            s.setProperty('margin', '0', 'important');
            s.setProperty('padding', '0', 'important');
            s.setProperty('max-width', 'none', 'important');
            s.setProperty('display', 'flow-root', 'important');
            // The theme draws a card around a diagram. The editor draws the picture on its own background.
            document.querySelectorAll('pre, .fen-mermaid-container').forEach(function (box) {
                box.style.setProperty('background', 'transparent', 'important');
                box.style.setProperty('border', 'none', 'important');
                box.style.setProperty('box-shadow', 'none', 'important');
                box.style.setProperty('padding', '0', 'important');
                box.style.setProperty('margin', '0', 'important');
            });
            if (!(\(check))) { return -1; }
            return Math.ceil(document.body.getBoundingClientRect().height);
        })()
        """
        guard let height = try? await webView.evaluateJavaScript(script) as? Double, height > 0 else { return nil }
        return CGFloat(min(height, maxMeasuredHeight))
    }

    private static func makeTransparent(_ webView: WKWebView) {
        #if canImport(AppKit)
            webView.setValue(false, forKey: "drawsBackground")
        #else
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
        #endif
    }
}
