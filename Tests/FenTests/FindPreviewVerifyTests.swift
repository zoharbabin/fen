import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Find in the real preview page: real composed HTML, the real `find.js`, a real `WKWebView`.
@Suite("Find in the preview")
@MainActor
struct FindPreviewVerifyTests {
    private func page(_ markdown: String) async throws -> (WKWebView, PreviewFindDriver, FindState) {
        var options = MarkdownRenderer.Options()
        options.tables = true
        options.taskList = true
        let webView = try await renderPreviewWebView(
            markdown: markdown, options: options, userScripts: [PreviewFindDriver.userScript()]
        )
        let driver = PreviewFindDriver(webView: webView)
        let find = FindState()
        // `FindState` holds its target weakly, as the preview coordinator owns the driver in the app.
        held.append(driver)
        held.append(webView)
        find.preview = driver
        find.visiblePanes = [.preview]
        return (webView, driver, find)
    }

    private func search(_ find: FindState, _ query: FindQuery) async throws {
        find.isPresented = true
        find.query = query
        find.queryChanged()
        try #require(await pollUntilTrue { !find.isSearching })
    }

    /// The text under each painted range, in document order.
    private func painted(_ webView: WKWebView, name: String = "fen-find") async throws -> [String] {
        let js = """
        (function () {
            var h = CSS.highlights.get('\(name)');
            if (!h) { return []; }
            return Array.from(h).map(function (r) {
                var x = document.createRange();
                x.setStart(r.startContainer, r.startOffset);
                x.setEnd(r.endContainer, r.endOffset);
                return x.toString();
            });
        })();
        """
        return try await webView.evaluateJavaScript(js) as? [String] ?? []
    }

    @Test("a match across inline tags is one highlight")
    func crossesInlineTags() async throws {
        let (webView, _, find) = try await page("Say **bold** text and `code` too.")
        try await search(find, FindQuery(text: "bold text"))
        #expect(find.previewCount == 1)
        let current = try await painted(webView, name: "fen-find-current")
        #expect(current == ["bold text"])
    }

    @Test("all matches paint, one of them as the current match")
    func paintsAll() async throws {
        let (webView, _, find) = try await page("fen one\n\nfen two\n\nfen three")
        try await search(find, FindQuery(text: "fen"))
        #expect(find.previewCount == 3)
        #expect(find.summary == "1 of 3")
        let others = try await painted(webView)
        let current = try await painted(webView, name: "fen-find-current")
        #expect(others.count == 2)
        #expect(current.count == 1)
    }

    @Test("highlights show on screen: the current match is orange, the others yellow, other text is not tinted")
    func highlightsAreVisible() async throws {
        let (webView, _, find) = try await page("fen one\n\nfen two\n\nplain words here")
        try await search(find, FindQuery(text: "fen"))
        let js = """
        (function () {
            function box(name, index) {
                var r = Array.from(CSS.highlights.get(name))[index];
                var x = document.createRange();
                x.setStart(r.startContainer, r.startOffset);
                x.setEnd(r.endContainer, r.endOffset);
                var b = x.getBoundingClientRect();
                return [b.left, b.top, b.width, b.height];
            }
            var p = document.querySelector('p:last-of-type').getBoundingClientRect();
            return { current: box('fen-find-current', 0), other: box('fen-find', 0),
                     plain: [p.left, p.top, p.width, p.height] };
        })();
        """
        let boxes = try #require(await webView.evaluateJavaScript(js) as? [String: [Double]])
        let image = try await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let scale = Double(rep.pixelsWide) / Double(webView.bounds.width)

        func colors(_ box: [Double]) -> [(r: Double, g: Double, b: Double)] {
            // A row just inside the bottom edge of the box, where glyphs rarely draw.
            let y = Int((box[1] + box[3] - 2) * scale)
            return stride(from: box[0] + 1, to: box[0] + box[2] - 1, by: 1).compactMap { x in
                rep.colorAt(x: Int(x * scale), y: y)?.usingColorSpace(.sRGB).map {
                    (Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent))
                }
            }
        }
        func warm(_ list: [(r: Double, g: Double, b: Double)], blueBelow: Double) -> Bool {
            list.contains { $0.r > 0.9 && $0.b < blueBelow }
        }
        let current = try colors(#require(boxes["current"]))
        let other = try colors(#require(boxes["other"]))
        let plain = try colors(#require(boxes["plain"]))
        // Orange (255, 149, 0 at 80%) is far less blue than yellow (255, 214, 10 at 45%) over a light page.
        #expect(warm(current, blueBelow: 0.45))
        #expect(warm(other, blueBelow: 0.85) && !warm(other, blueBelow: 0.45))
        #expect(!warm(plain, blueBelow: 0.95))
    }

    @Test("in split mode only the pane you drive shows a current match")
    func onlyTheActivePaneHasACurrentMatch() async throws {
        let text = "fen one\n\nfen two\n\nfen three"
        let (webView, _, find) = try await page(text)
        let editor = FakeFindEditor(text)
        find.editor = editor
        find.visiblePanes = [.editor, .preview]
        find.activePane = .editor
        try await search(find, FindQuery(text: "fen"))
        #expect(editor.shown.last?.current == 0)
        #expect(try await painted(webView, name: "fen-find-current").isEmpty)
        #expect(try await painted(webView).count == 3)

        find.switchPane(to: .preview)
        try #require(await pollUntilTrue { await (try? painted(webView, name: "fen-find-current"))?.count == 1 })
        #expect(editor.shown.last?.current == nil)
    }

    @Test("a match never runs from one paragraph into the next")
    func blocksSeparate() async throws {
        let (_, _, find) = try await page("end of one\n\nstart of two")
        try await search(find, FindQuery(text: "one start"))
        #expect(find.previewCount == 0)
    }

    @Test("a match that starts or ends on the newline between blocks still paints")
    func matchOnBlockEdge() async throws {
        let (webView, _, find) = try await page("end of one\n\nstart of two")
        try await search(find, FindQuery(text: "\\nstart", isRegex: true))
        #expect(find.previewCount == 1)
        #expect(try await painted(webView, name: "fen-find-current") == ["start"])
        try await search(find, FindQuery(text: "one\\n", isRegex: true))
        #expect(find.previewCount == 1)
        #expect(try await painted(webView, name: "fen-find-current") == ["one"])
    }

    @Test("the copy button's label and hidden elements are not searchable")
    func skipsChrome() async throws {
        let (webView, _, find) = try await page("```swift\nlet x = 1\n```\n\nafter")
        let text = try #require(await PreviewFindDriver(webView: webView).findSnapshot(known: nil)?.text)
        #expect(!text.localizedCaseInsensitiveContains("copy"))
        try await search(find, FindQuery(text: "let x"))
        #expect(find.previewCount == 1)
    }

    @Test("code keeps its spaces and line breaks")
    func codeKeepsWhitespace() async throws {
        let (_, _, find) = try await page("```\na  b\nc\n```")
        try await search(find, FindQuery(text: "a  b\nc"))
        #expect(find.previewCount == 1)
    }

    @Test("code with line numbers on keeps its lines apart")
    func lineNumberedCode() async throws {
        let (webView, driver, find) = try await page("```\nplaceholder\n```")
        try await webView.evaluateJavaScript(
            "document.querySelector('pre code').innerHTML = "
                + "'<span class=\"fen-line\">first</span><span class=\"fen-line\">second</span>'; 0"
        )
        let text = try #require(await driver.findSnapshot(known: nil)?.text)
        #expect(text.contains("first\nsecond"))
        try await search(find, FindQuery(text: "firstsecond"))
        #expect(find.previewCount == 0)
    }

    @Test("whitespace in prose collapses like the page shows it")
    func collapsesWhitespace() async throws {
        let (_, _, find) = try await page("one   two\nthree")
        try await search(find, FindQuery(text: "one two three"))
        #expect(find.previewCount == 1)
    }

    @Test("the rest of the engine applies: regex, whole word, case")
    func engineOptions() async throws {
        let (_, _, find) = try await page("Cat concat cat")
        try await search(find, FindQuery(text: "cat", wholeWord: true))
        #expect(find.previewCount == 2)
        try await search(find, FindQuery(text: "Cat"))
        #expect(find.previewCount == 1)
        try await search(find, FindQuery(text: "c[a-z]+t", isRegex: true))
        #expect(find.previewCount == 3)
    }

    @Test("Next scrolls an off-screen match into view and leaves visible ones where they are")
    func scrollsOnlyWhenNeeded() async throws {
        let filler = (0 ..< 120).map { "paragraph \($0)" }.joined(separator: "\n\n")
        let (webView, _, find) = try await page("fen top\n\n\(filler)\n\nfen bottom")
        try await search(find, FindQuery(text: "fen"))
        let before = try await webView.evaluateJavaScript("window.scrollY") as? Double
        #expect(before == 0)
        find.next()
        try #require(await pollUntilTrue(webView, js: "window.scrollY > 100"))
        let rect = try await webView.evaluateJavaScript(
            "(function(){var h=CSS.highlights.get('fen-find-current');var r=Array.from(h)[0];var x=document.createRange();"
                + "x.setStart(r.startContainer,r.startOffset);x.setEnd(r.endContainer,r.endOffset);"
                + "var b=x.getBoundingClientRect();return b.top>=0&&b.bottom<=window.innerHeight;})()"
        ) as? Bool
        #expect(rect == true)
        find.next()
        try #require(await pollUntilTrue(webView, js: "window.scrollY < 5"))
    }

    @Test("a match inside a closed details block opens it")
    func opensDetails() async throws {
        let (webView, _, find) = try await page("<details><summary>More</summary>\n\nhidden fen\n\n</details>")
        try await search(find, FindQuery(text: "hidden fen"))
        find.next()
        try #require(await pollUntilTrue(webView, js: "document.querySelector('details').open"))
    }

    @Test("a page that changed after the search is searched again")
    func staleVersion() async throws {
        let (webView, driver, find) = try await page("fen")
        try await search(find, FindQuery(text: "fen"))
        let snapshot = try #require(await driver.findSnapshot(known: nil))
        try await webView
            .evaluateJavaScript(
                "document.body.appendChild(Object.assign(document.createElement('p'),{textContent:'fen more'})) && 0"
            )
        let newer = await driver.findShow(offsets: [0, 3], version: snapshot.version, current: 0, scroll: false)
        #expect(newer != nil)
        #expect(newer != snapshot.version)
    }

    @Test("a late change to the page triggers a new search through the message handler")
    func lateChange() async throws {
        let (webView, _, find) = try await page("fen")
        let probe = MessageProbe()
        webView.configuration.userContentController.add(probe, name: PreviewFindDriver.messageName)
        try await search(find, FindQuery(text: "fen"))
        try await webView
            .evaluateJavaScript(
                "document.body.appendChild(Object.assign(document.createElement('p'),{textContent:'fen'})) && 0"
            )
        try #require(await pollUntilTrue { probe.count >= 1 })
        find.previewChanged()
        try #require(await pollUntilTrue { find.previewCount == 2 && !find.isSearching })
    }

    @Test("closing the bar removes every highlight and leaves the DOM alone")
    func clearLeavesDOM() async throws {
        let (webView, _, find) = try await page("fen and fen")
        let html = try await webView.evaluateJavaScript("document.body.innerHTML") as? String
        try await search(find, FindQuery(text: "fen"))
        find.dismiss()
        try #require(await pollUntilTrue(webView, js: "!CSS.highlights.has('fen-find')"))
        #expect(try await webView.evaluateJavaScript("document.body.innerHTML") as? String == html)
    }

    @Test("source position anchors used by scroll sync are untouched while searching")
    func scrollSyncAnchorsIntact() async throws {
        let (webView, _, find) = try await page("# Title\n\nfen para")
        let before = try await webView
            .evaluateJavaScript("document.querySelectorAll('[data-sourcepos]').length") as? Int
        try await search(find, FindQuery(text: "fen"))
        let after = try await webView.evaluateJavaScript("document.querySelectorAll('[data-sourcepos]').length") as? Int
        #expect(before == after)
    }

    @Test("strip positions are fractions of the page height")
    func stripPositions() async throws {
        let filler = (0 ..< 60).map { "paragraph \($0)" }.joined(separator: "\n\n")
        let (_, _, find) = try await page("fen top\n\n\(filler)\n\nfen bottom")
        try await search(find, FindQuery(text: "fen"))
        try #require(await pollUntilTrue { find.previewStrip.count == 2 })
        #expect(find.previewStrip[0] < 0.1)
        #expect(find.previewStrip[1] > 0.8)
    }
}

/// Keeps each test's page and driver alive for the process. The driver holds the page weakly.
@MainActor private var held: [AnyObject] = []

private final class MessageProbe: NSObject, WKScriptMessageHandler {
    private(set) var count = 0

    func userContentController(_: WKUserContentController, didReceive _: WKScriptMessage) {
        count += 1
    }
}
