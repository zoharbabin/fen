import Foundation
import WebKit
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Renders a block's Markdown through the same pipeline as export, so the picture matches the preview.
@MainActor
enum LivePreviewWebSnapshot {
    private static let timeout = Duration.seconds(20)
    /// What MathJax leaves in the page for a formula it can't read, including an unknown macro.
    private static let mathError = "mjx-merror, [data-mml-node=merror], mtext[mathcolor=red]"
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
            return await renderFormulas([key], preferences: preferences).first ?? nil
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

    /// Renders formulas, each in a line of its own, and crops to each. The baseline comes from an empty inline
    /// box set right before the formula: the bottom of that box sits on the text baseline. A formula MathJax
    /// can't read gives `nil`.
    static func renderFormulas(
        _ keys: [LivePreviewSnapshots.Key], preferences: Preferences
    ) async -> [LivePreviewSnapshots.Picture?] {
        guard let first = keys.first else { return [] }
        let lines = keys.enumerated().map { index, key in
            let escaped = MarkdownRenderer.mathJaxSource(key.source)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<p style=\"margin:0;white-space:nowrap\"><span id=\"fen-baseline-\(index)\" "
                + "style=\"display:inline-block;width:0;height:0\"></span>"
                + "<span id=\"fen-formula-\(index)\">\(escaped)</span></p>"
        }
        let html = HTMLComposer().composeForExport(
            title: nil,
            body: lines.joined(),
            preferences: preferences,
            includeStyles: true,
            includeHighlighting: false,
            appearanceOverride: first.dark ? .dark : .light
        )
        let none = [LivePreviewSnapshots.Picture?](repeating: nil, count: keys.count)
        guard let webView = try? await PDFRenderer().loadOffscreenWebView(
            html: html, baseDirectory: nil, loadTimeout: timeout, size: CGSize(width: first.width, height: 20)
        ) else { return none }
        makeTransparent(webView)
        let script = measureScript(count: keys.count)
        guard let measured = try? await webView.evaluateJavaScript(script) as? [Any] else { return none }
        let boxes: [[Double]?] = measured.map { value in
            guard let values = value as? [Double], values.count == 5, values[2] > 0, values[3] > 0 else { return nil }
            return values
        }
        let rects = boxes.map { values in
            values.map {
                CGRect(x: floor($0[0]), y: floor($0[1]), width: ceil($0[2]) + 1, height: ceil($0[3]) + 1)
            }
        }
        webView.frame.size.height = max(rects.compactMap { $0?.maxY }.max() ?? 1, 1)
        var pictures: [LivePreviewSnapshots.Picture?] = []
        for (index, rect) in rects.enumerated() {
            guard let rect, let values = boxes[index] else {
                pictures.append(nil)
                continue
            }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect
            configuration.snapshotWidth = NSNumber(value: Double(rect.width))
            guard let image = try? await webView.takeSnapshot(configuration: configuration) else {
                pictures.append(nil)
                continue
            }
            pictures.append(LivePreviewSnapshots.Picture(image: image, baseline: CGFloat(values[4]) - rect.minY))
        }
        return pictures
    }

    private static func measureScript(count: Int) -> String {
        """
        (function () {
            document.documentElement.style.setProperty('background', 'transparent', 'important');
            var s = document.body.style;
            s.setProperty('background', 'transparent', 'important');
            s.setProperty('margin', '0', 'important');
            s.setProperty('padding', '0', 'important');
            s.setProperty('max-width', 'none', 'important');
            var out = [];
            for (var i = 0; i < \(count); i++) {
                var host = document.getElementById('fen-formula-' + i);
                var math = host.querySelector('mjx-container svg');
                if (!math || host.querySelector('\(mathError)')) { out.push(null); continue; }
                var box = math.getBoundingClientRect();
                var baseline = document.getElementById('fen-baseline-' + i).getBoundingClientRect().bottom;
                out.push([box.left, box.top, box.width, box.height, baseline]);
            }
            return out;
        })()
        """
    }

    /// Strips the page chrome and measures what is left. `nil` when the renderer left an error or nothing.
    private static func prepare(_ webView: WKWebView, kind: RenderedBlock.Kind) async -> CGFloat? {
        let check = switch kind {
        case .mermaid: "!!document.querySelector('svg') && !document.body.innerText.includes('Syntax error')"
        case .math: "!!document.querySelector('mjx-container') && !document.querySelector('\(mathError)')"
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
