@testable import FenCore
import Foundation
import Network
import Testing

/// Proves issue #33 rule 2.3: `ClipboardExporter` never lets `NSAttributedString`'s HTML-to-
/// rich-text importer fetch a remaining remote `<img>` reference. Unlike `ExportAssetResolver`
/// (issue #31), which never itself performs a fetch, the importer used for "Copy as Rich Text"
/// is an OS API that fetches on its own for any `http`/`https` `src` it's handed directly --
/// confirmed by a local repro before this file was written. `strippingNonDataImages` is the one
/// guard between composed HTML and that importer.
struct ClipboardExporterSecurityTests {
    private func sourceOfClipboardExporter() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClipboardExporterSecurityTests.swift
            .deletingLastPathComponent() // FenTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Shared/Rendering/ClipboardExporter.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    @Test func sourceContainsNoShellOutOrDynamicExecution() throws {
        let source = try sourceOfClipboardExporter()
        for forbidden in ["Process(", "/bin/sh", "NSAppleScript", "eval("] {
            #expect(!source.contains(forbidden), "ClipboardExporter.swift must not contain '\(forbidden)'")
        }
    }

    /// Starts a loopback listener and returns it alongside the port it bound to -- a positive
    /// hit on this listener means something fetched a URL pointing at it. Runs on its own
    /// background queue, not `.main`: `NSAttributedString`'s HTML importer blocks the calling
    /// thread synchronously while it waits on its own fetch, so a `.main`-queued connection
    /// handler would never get a chance to run until that blocking call already timed out.
    private struct LoopbackListener {
        let listener: NWListener
        let port: UInt16
        let hits: Hits
    }

    private func startLoopbackListener() throws -> LoopbackListener {
        let hits = Hits()
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "ClipboardExporterSecurityTests.listener")
        listener.newConnectionHandler = { connection in
            hits.record()
            connection.cancel()
        }
        listener.start(queue: queue)
        var boundPort: UInt16?
        for _ in 0 ..< 50 {
            if let port = listener.port?.rawValue, port != 0 {
                boundPort = port
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let port = try #require(boundPort, "listener never bound to a port")
        return LoopbackListener(listener: listener, port: port, hits: hits)
    }

    private final class Hits: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    @Test func strippingRemovesARemoteImageReferenceBeforeRichTextConversion() throws {
        let probe = try startLoopbackListener()
        defer { probe.listener.cancel() }

        let html = #"<html><body><p>Hello</p><img src="http://127.0.0.1:\#(probe.port)/tracker.png"></body></html>"#
        let exporter = ClipboardExporter()
        let stripped = exporter.strippingNonDataImages(from: html)
        #expect(!stripped.contains("img"), "the remote <img> tag must be fully removed before conversion")

        _ = exporter.attributedString(from: stripped)

        // Give any (incorrectly) in-flight fetch a moment to reach the listener before asserting.
        Thread.sleep(forTimeInterval: 0.5)
        #expect(probe.hits.value == 0, "converting stripped HTML must never fetch the removed remote reference")
    }

    @Test func unstrippedRemoteImageReferenceWouldBeFetchedByTheImporterItself() throws {
        // Documents the actual OS behavior `strippingNonDataImages` exists to guard against:
        // handing the importer *unstripped* HTML with a remaining remote reference does trigger
        // a fetch, proving the guard in the test above is necessary, not just defensive.
        let probe = try startLoopbackListener()
        defer { probe.listener.cancel() }

        let html = #"<html><body><img src="http://127.0.0.1:\#(probe.port)/tracker.png"></body></html>"#
        _ = ClipboardExporter().attributedString(from: html)

        Thread.sleep(forTimeInterval: 0.5)
        #expect(probe.hits.value > 0, "expected the OS HTML importer to fetch the remaining remote reference")
    }
}
