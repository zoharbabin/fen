@testable import FenCore
import Foundation
import Testing

@Suite("MarkdownChunker")
struct MarkdownChunkerTests {
    @Test("headings make chunks with a heading trail and the right start line")
    func headingTrail() {
        let text = "# Guide\nIntro text.\n\n## Install\nRun the installer.\n\n### Mac\nUse the dmg.\n\n## Use\nOpen it.\n"
        let doc = MarkdownChunker.parse(text, path: "guide.md")
        #expect(doc.title == "Guide")
        #expect(doc.chunks.map(\.heading) == ["Guide", "Guide > Install", "Guide > Install > Mac", "Guide > Use"])
        #expect(doc.chunks.map(\.startLine) == [2, 5, 8, 11])
        #expect(doc.chunks[2].text == "Use the dmg.")
    }

    @Test("a chunk starts on its first line of text, not on the blank lines before it")
    func startsOnText() {
        let text = "# Guide\n\n\nIntro text.\n\n## Decision\n\nWe charge per seat.\n"
        let doc = MarkdownChunker.parse(text, path: "guide.md")
        let lines = text.components(separatedBy: "\n")
        #expect(doc.chunks.map(\.startLine) == [4, 8])
        for chunk in doc.chunks {
            #expect(lines[chunk.startLine - 1] == chunk.text.components(separatedBy: "\n")[0])
        }
    }

    @Test("every piece of a long section starts on the line where its text begins")
    func longSectionPieces() {
        let paragraphs = (1 ... 6).map { "Paragraph \($0) " + String(repeating: "word ", count: 60) }
        let text = "# Long\n\n" + paragraphs.joined(separator: "\n\n") + "\n"
        let doc = MarkdownChunker.parse(text, path: "long.md")
        let lines = text.components(separatedBy: "\n")
        #expect(doc.chunks.count > 1)
        for chunk in doc.chunks {
            let first = chunk.text.components(separatedBy: "\n")[0]
            #expect(lines[chunk.startLine - 1].hasPrefix(first.prefix(20)))
        }
        #expect(Set(doc.chunks.map(\.startLine)).count == doc.chunks.count)
    }

    @Test("front matter is one chunk that is not embedded, and gives the title")
    func frontMatter() {
        let text = "---\ntitle: \"My Note\"\ntags: [a, b]\n---\n# Heading\nBody\n"
        let doc = MarkdownChunker.parse(text, path: "n.md")
        #expect(doc.title == "My Note")
        #expect(doc.chunks.first?.heading == "Front matter")
        #expect(doc.chunks.first?.embeddable == false)
        #expect(doc.chunks.dropFirst().filter { !$0.embeddable }.isEmpty)
        #expect(doc.chunks.last?.startLine == 6)
    }

    @Test("a file with no heading falls back to its name, and CRLF is handled")
    func noHeadingAndCRLF() {
        let doc = MarkdownChunker.parse("Just words.\r\nMore words.\r\n", path: "folder/plain note.txt")
        #expect(doc.title == "plain note")
        #expect(doc.chunks.count == 1)
        #expect(doc.chunks[0].text == "Just words.\nMore words.")
        #expect(doc.chunks[0].heading.isEmpty)
    }

    @Test("a # inside a fenced code block is not a heading, and links inside it are ignored")
    func fencesAreCode() {
        let text = "# Real\n```sh\n# comment\n[x](other.md)\n```\nAfter [y](kept.md).\n"
        let doc = MarkdownChunker.parse(text, path: "a.md")
        #expect(doc.chunks.map(\.heading) == ["Real"])
        #expect(doc.chunks[0].text.contains("# comment"))
        #expect(doc.links == [DocumentLink(kind: .path, target: "kept.md")])
    }

    @Test("empty sections are skipped and empty text gives no chunks")
    func empties() {
        #expect(MarkdownChunker.parse("", path: "e.md").chunks.isEmpty)
        #expect(MarkdownChunker.parse("# A\n## B\n", path: "e.md").chunks.isEmpty)
    }

    @Test("a long section is split below the limit, at paragraph then word boundaries")
    func longSections() {
        let paragraph = String(repeating: "word ", count: 100)
        let text = "# Long\n" + (0 ..< 10).map { _ in paragraph }.joined(separator: "\n\n")
        let doc = MarkdownChunker.parse(text, path: "l.md")
        #expect(doc.chunks.count > 1)
        #expect(doc.chunks.allSatisfy { $0.text.count <= MarkdownChunker.maxChunkCharacters })
        let one = MarkdownChunker.parse("# L\n" + String(repeating: "x", count: 5000), path: "l.md")
        #expect(one.chunks.allSatisfy { $0.text.count <= MarkdownChunker.maxChunkCharacters })
        #expect(one.chunks.map(\.text.count).reduce(0, +) == 5000 || one.chunks.count >= 4)
    }

    @Test("the chunk count is capped for huge files")
    func cap() {
        let text = (0 ..< 3000).map { "## S\($0)\nbody \($0)\n" }.joined()
        #expect(MarkdownChunker.parse(text, path: "big.md").chunks.count == MarkdownChunker.maxChunks)
    }

    @Test("a multi-megabyte data URI line is cut short and does not flood the index")
    func dataURILine() {
        let payload = String(repeating: "QUJD", count: 1_250_000)
        let text = "# Doc\nIntro.\n![pic](data:image/png;base64,\(payload))\nAfter.\n"
        let clock = ContinuousClock()
        var doc = ParsedDocument(title: "", chunks: [], links: [])
        let elapsed = clock.measure { doc = MarkdownChunker.parse(text, path: "doc.md") }
        #expect(doc.chunks.count == 1)
        #expect(doc.chunks.allSatisfy { $0.text.count <= MarkdownChunker.maxChunkCharacters })
        #expect(elapsed < .seconds(10))
    }

    @Test("a raw multi-megabyte run with no spaces is skipped")
    func opaqueRun() {
        let text = "# Doc\n" + String(repeating: "QUJD", count: 1_250_000) + "\n"
        let clock = ContinuousClock()
        var doc = ParsedDocument(title: "", chunks: [], links: [])
        let elapsed = clock.measure { doc = MarkdownChunker.parse(text, path: "doc.md") }
        #expect(doc.chunks.isEmpty)
        #expect(elapsed < .seconds(10))
    }

    @Test("one multi-megabyte line of words stops at the chunk cap")
    func longLineOfWords() {
        let text = "# Doc\n" + String(repeating: "word ", count: 1_000_000) + "\n"
        let clock = ContinuousClock()
        var doc = ParsedDocument(title: "", chunks: [], links: [])
        let elapsed = clock.measure { doc = MarkdownChunker.parse(text, path: "doc.md") }
        #expect(doc.chunks.count == MarkdownChunker.maxChunks)
        #expect(elapsed < .seconds(10))
    }

    @Test("a piece whose first line also appears earlier in the section still gets its own line")
    func repeatedFirstLine() {
        let first = String(repeating: "alpha ", count: 190).trimmingCharacters(in: .whitespaces)
        let second = String(repeating: "alpha ", count: 60).trimmingCharacters(in: .whitespaces)
        let text = "# T\n" + first + "\n\n" + second + "\n"
        let doc = MarkdownChunker.parse(text, path: "t.md")
        #expect(doc.chunks.map(\.startLine) == [2, 4])
    }

    @Test("links in headings are extracted")
    func headingLinks() {
        let doc = MarkdownChunker.parse("# See [Other](other.md) and [[Wiki Page]]\nBody.\n", path: "a.md")
        #expect(doc.links.contains(DocumentLink(kind: .path, target: "other.md")))
        #expect(doc.links.contains(DocumentLink(kind: .wiki, target: "wiki page")))
    }

    @Test("links resolve relative to the document and never leave the workspace")
    func linkResolution() {
        #expect(MarkdownChunker.resolve("b.md", from: "docs/a.md") == "docs/b.md")
        #expect(MarkdownChunker.resolve("../README.md#top", from: "docs/a.md") == "README.md")
        #expect(MarkdownChunker.resolve("/docs/b.md", from: "x/a.md") == "docs/b.md")
        #expect(MarkdownChunker.resolve("my%20note.md", from: "a.md") == "my note.md")
        #expect(MarkdownChunker.resolve("../../outside.md", from: "docs/a.md") == nil)
        #expect(MarkdownChunker.resolve("https://example.com/x.md", from: "a.md") == nil)
        #expect(MarkdownChunker.resolve("mailto:a@b.c", from: "a.md") == nil)
        #expect(MarkdownChunker.resolve("#section", from: "a.md") == nil)
    }

    @Test("wiki links are matched by lowercase name without extension")
    func wikiLinks() {
        let links = MarkdownChunker.extractLinks(
            from: "See [[Project Plan]] and [[notes/Ideas.md|my ideas]] and [[Doc#Part]].",
            documentPath: "a.md"
        )
        #expect(links.map(\.target) == ["project plan", "notes/ideas", "doc"])
        #expect(links.allSatisfy { $0.kind == .wiki })
    }
}
