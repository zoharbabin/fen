import SwiftUI
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Knows which window hosts a `SplitEditorView`, so a menu command can tell whether this window is
/// the one the user is working in (`CommandTarget`). Shared-state commands (Live Preview, print,
/// export) run only in that window. Without it, two windows toggle one shared preference twice, or
/// both open a print panel.
@MainActor
final class HostWindowProbe {
    #if os(macOS)
        weak var view: NSView?
    #else
        weak var view: UIView?
    #endif

    /// True when this window is the command target. A view that is not in a window yet counts as
    /// the target, so a lone window keeps working.
    var isCommandTarget: Bool {
        guard let window = view?.window else { return true }
        #if os(macOS)
            return window.isKeyWindow
        #else
            return CommandTarget.accepts(window: window)
        #endif
    }
}

/// Runs `perform` for a menu command, in the window the user is working in only.
private struct WindowCommandReceiver: ViewModifier {
    let name: Notification.Name
    let perform: () -> Void
    @State private var probe = HostWindowProbe()

    func body(content: Content) -> some View {
        content
            .background(HostWindowProbeView(probe: probe))
            .onReceive(NotificationCenter.default.publisher(for: name)) { _ in
                if probe.isCommandTarget {
                    perform()
                }
            }
    }
}

extension View {
    /// Like `onReceive` for a menu command, but runs only in the command target window.
    func onWindowCommand(_ name: Notification.Name, perform: @escaping () -> Void) -> some View {
        modifier(WindowCommandReceiver(name: name, perform: perform))
    }
}

// Invisible background view that reports its window to a `HostWindowProbe`.
#if os(macOS)
    struct HostWindowProbeView: NSViewRepresentable {
        let probe: HostWindowProbe

        func makeNSView(context _: Context) -> NSView {
            let view = NSView(frame: .zero)
            probe.view = view
            return view
        }

        func updateNSView(_: NSView, context _: Context) {}
    }
#else
    struct HostWindowProbeView: UIViewRepresentable {
        let probe: HostWindowProbe

        func makeUIView(context _: Context) -> UIView {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            probe.view = view
            return view
        }

        func updateUIView(_: UIView, context _: Context) {}
    }
#endif
