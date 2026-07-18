@testable import FenCore
import Foundation
import Testing

/// Proves rule 2.1 from issue #20's spec (github.com/zoharbabin/fen/issues/20): the monitor only
/// ever watches `presentedItemURL` -- the exact URL it was constructed with -- and never derives,
/// concatenates, or reconstructs a path from anything else (no directory-level watch, no
/// string-interpolated path). A source-level grep is the most direct proof, since the type has no
/// API surface that could take an untrusted path at all.
struct ExternalFileChangeSecurityTests {
    private func sourceOfMonitor() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ExternalFileChangeSecurityTests.swift
            .deletingLastPathComponent() // FenTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Shared/Models/ExternalFileChangeMonitor.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    @Test func monitorSourceContainsNoShellOutOrDynamicExecution() throws {
        let source = try sourceOfMonitor()
        for forbidden in ["Process(", "/bin/sh", "NSAppleScript", "eval(", "URLSession"] {
            #expect(!source.contains(forbidden), "ExternalFileChangeMonitor.swift must not contain '\(forbidden)'")
        }
    }

    /// The only path-bearing property `ExternalFileChangeMonitor` exposes is the `presentedItemURL`
    /// it was constructed with -- there is no separate directory-watch property, and no string
    /// concatenation/interpolation building a second path anywhere in the type.
    @Test func monitorSourceConstructsNoPathBeyondThePresentedItemURLItWasGiven() throws {
        let source = try sourceOfMonitor()
        #expect(
            !source.contains("appendingPathComponent"),
            "monitor must not derive any path beyond the URL it was given"
        )
        #expect(!source.contains("URL(fileURLWithPath:"), "monitor must not construct a second URL from a string path")
    }

    /// The monitor's `presentedItemURL` is always exactly the URL passed to `init`, never a
    /// resolved/rewritten/symlink-followed variant of it -- `NSFileCoordinator`'s own standard
    /// resolution happens at the OS level, not by any path logic this type adds.
    @Test @MainActor func presentedItemURLIsExactlyWhatWasPassedIn() {
        let fileURL = URL(fileURLWithPath: "/tmp/some-document.md")
        let monitor = ExternalFileChangeMonitor(
            fileURL: fileURL, onExternalChange: {}, onExternalDeletion: {}
        )
        defer { monitor.stop() }

        #expect(monitor.presentedItemURL == fileURL)
    }
}
