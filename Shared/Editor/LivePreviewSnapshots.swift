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
    }

    typealias Render = @MainActor (Key) async -> PlatformImage?

    static let widthStep: CGFloat = 40
    static let maxSourceLength = 20000

    /// Tests swap this for a stub.
    static var shared = LivePreviewSnapshots(
        kinds: { enabledKinds() },
        render: { key in await LivePreviewWebSnapshot.render(key, preferences: .shared) }
    )

    /// Which kinds of block are drawn as pictures right now.
    let kinds: @MainActor () -> Set<RenderedBlock.Kind>
    private let render: Render
    private let limit: Int
    private var cache: [Key: PlatformImage] = [:]
    private var recent: [Key] = []
    private var failed: Set<Key> = []
    private var queue: [Key] = []
    private var waiting: [Key: [ObjectIdentifier: @MainActor () -> Void]] = [:]
    private var isRunning = false

    init(limit: Int = 32, kinds: @escaping @MainActor () -> Set<RenderedBlock.Kind>, render: @escaping Render) {
        self.limit = limit
        self.kinds = kinds
        self.render = render
    }

    /// The kinds the preview settings turn on. A block whose renderer is off stays source, as in the preview.
    static func enabledKinds(_ preferences: Preferences = .shared) -> Set<RenderedBlock.Kind> {
        var kinds: Set<RenderedBlock.Kind> = []
        if preferences.htmlMermaid {
            kinds.insert(.mermaid)
        }
        if preferences.htmlMathJax {
            kinds.insert(.math)
        }
        if preferences.htmlGeoJSONMaps {
            kinds.insert(.map)
        }
        return kinds
    }

    static func key(for block: RenderedBlock, columnWidth: CGFloat, background: PlatformColor) -> Key? {
        guard block.source.count <= maxSourceLength else { return nil }
        let steps = max((columnWidth / widthStep).rounded(.down), 4)
        return Key(
            kind: block.kind,
            source: block.source,
            width: Int(steps * widthStep),
            dark: LivePreviewBlockStyle.luminance(of: background) < 0.5
        )
    }

    func image(for key: Key) -> PlatformImage? {
        guard let image = cache[key] else { return nil }
        recent.removeAll { $0 == key }
        recent.append(key)
        return image
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
            let image = await render(key)
            let callbacks = waiting.removeValue(forKey: key).map { Array($0.values) } ?? []
            isRunning = false
            if let image, image.size.width > 0, image.size.height > 0 {
                cache[key] = image
                recent.append(key)
                while recent.count > limit {
                    cache[recent.removeFirst()] = nil
                }
                for callback in callbacks {
                    callback()
                }
            } else {
                failed.insert(key)
            }
            pump()
        }
    }
}

/// Renders a block's Markdown through the same pipeline as export, so the picture matches the preview.
@MainActor
enum LivePreviewWebSnapshot {
    private static let timeout = Duration.seconds(20)

    static func render(_ key: LivePreviewSnapshots.Key, preferences: Preferences) async -> PlatformImage? {
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
        configuration.snapshotWidth = NSNumber(value: key.width)
        return try? await webView.takeSnapshot(configuration: configuration)
    }

    /// Strips the page chrome and measures what is left. `nil` when the renderer left an error or nothing.
    private static func prepare(_ webView: WKWebView, kind: RenderedBlock.Kind) async -> CGFloat? {
        let check = switch kind {
        case .mermaid: "!!document.querySelector('svg') && !document.body.innerText.includes('Syntax error')"
        case .math: "!!document.querySelector('mjx-container') && !document.querySelector('mjx-merror')"
        case .map: "!!document.querySelector('.leaflet-container')"
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
            if (!(\(check))) { return -1; }
            return Math.ceil(document.body.getBoundingClientRect().height);
        })()
        """
        guard let height = try? await webView.evaluateJavaScript(script) as? Double, height > 0 else { return nil }
        return CGFloat(min(height, 1600))
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
