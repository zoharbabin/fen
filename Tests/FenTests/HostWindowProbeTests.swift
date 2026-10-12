import AppKit
@testable import FenCore
import SwiftUI
import Testing

/// Issue #42: Live Preview, Focus Mode, print and export change shared state, so with two windows
/// open only the key window may run them, or one shortcut would toggle the preference twice.
struct HostWindowProbeTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool {
            true
        }
    }

    @MainActor
    private func probe(in window: NSWindow) -> HostWindowProbe {
        let view = NSView(frame: .zero)
        window.contentView = view
        let probe = HostWindowProbe()
        probe.view = view
        return probe
    }

    private func window(_ type: NSWindow.Type) -> NSWindow {
        type.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    @Test @MainActor
    func onlyTheKeyWindowIsTheCommandTarget() {
        #expect(probe(in: window(KeyWindow.self)).isCommandTarget)
        #expect(!probe(in: window(NSWindow.self)).isCommandTarget)
    }

    @Test @MainActor
    func aProbeWithoutAWindowStillRuns() {
        #expect(HostWindowProbe().isCommandTarget)
    }

    @MainActor
    private final class Counter {
        var runs = 0
    }

    @Test @MainActor
    func theCommandModifierRunsOnlyInTheKeyWindow() async throws {
        let name = Notification.Name("hostWindowProbeTest-\(UUID().uuidString)")
        let key = Counter()
        let other = Counter()
        let keyWindow = window(KeyWindow.self)
        let otherWindow = window(NSWindow.self)
        keyWindow.contentView = NSHostingView(rootView: Color.clear.onWindowCommand(name) { key.runs += 1 })
        otherWindow.contentView = NSHostingView(rootView: Color.clear.onWindowCommand(name) { other.runs += 1 })
        // The subscription starts once SwiftUI has built the view, so post until the key window runs.
        let ran = try await pollUntilTrue {
            NotificationCenter.default.post(name: name, object: nil)
            return key.runs > 0
        }
        #expect(ran)
        #expect(other.runs == 0)
    }
}
