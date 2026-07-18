@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #29: proves the alert-transform pipeline holds no shared mutable
/// state across calls or instances, per rule 1.1 -- interleaves alert renders against two
/// different `MarkdownRenderer` instances and two different documents in one process and checks
/// neither call's result leaks into the other. Mirrors `MarkdownFormattingIsolationTests.swift`.
struct GFMAlertsIsolationTests {
    @Test func interleavedRendersAcrossInstancesDoNotShareState() {
        let rendererA = MarkdownRenderer()
        let rendererB = MarkdownRenderer()
        var opts = MarkdownRenderer.Options()
        opts.alerts = true

        let resultA1 = rendererA.render("> [!NOTE]\n> Alpha.", options: opts)
        let resultB1 = rendererB.render("> [!WARNING]\n> Beta.", options: opts)
        let resultA2 = rendererA.render("> [!NOTE]\n> Alpha.", options: opts)
        let resultB2 = rendererB.render("> [!WARNING]\n> Beta.", options: opts)

        #expect(resultA1.html == resultA2.html)
        #expect(resultB1.html == resultB2.html)
        #expect(resultA1.html.contains("markdown-alert-note"))
        #expect(!resultA1.html.contains("markdown-alert-warning"))
        #expect(resultB1.html.contains("markdown-alert-warning"))
        #expect(!resultB1.html.contains("markdown-alert-note"))
    }

    @Test func repeatedRendersOnDifferentAlertTypesNeverAccumulateAcrossCalls() {
        let renderer = MarkdownRenderer()
        var opts = MarkdownRenderer.Options()
        opts.alerts = true

        let types = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]
        let results = types.map { renderer.render("> [!\($0)]\n> Body.", options: opts).html }

        for (index, html) in results.enumerated() {
            let expectedClass = "markdown-alert-\(types[index].lowercased())"
            #expect(html.contains(expectedClass))
            for other in types where other != types[index] {
                #expect(!html.contains("markdown-alert-\(other.lowercased())"))
            }
        }
    }
}
