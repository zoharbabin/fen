#if os(iOS)
    import SwiftUI
    import UIKit

    /// Invisible `UIView` placed via `.background` on the toolbar `Menu` -- its own bounds become
    /// the popover anchor rect `UIPrintInteractionController.present(from:in:animated:completionHandler:)`
    /// requires on iPad (`.regular` horizontal size class), since that API has no SwiftUI-native
    /// equivalent and Fen's export/print entry point is a `Menu`, not a `UIBarButtonItem` (issue
    /// #32). Reports its own view back via `anchorView` once SwiftUI creates it.
    struct PrintAnchorView: UIViewRepresentable {
        @Binding var anchorView: UIView?

        func makeUIView(context _: Context) -> UIView {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            DispatchQueue.main.async {
                anchorView = view
            }
            return view
        }

        func updateUIView(_: UIView, context _: Context) {}
    }
#endif
