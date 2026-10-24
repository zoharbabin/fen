#if os(macOS)
    import SwiftUI

    /// Ticks along a pane's trailing edge, one per match (or per cluster, when there are many), so you
    /// see where the matches sit in the whole document. It never takes clicks.
    struct FindMatchStrip: View {
        /// Positions as a fraction of the document height, 0...1.
        var positions: [Double]

        var body: some View {
            Canvas { context, size in
                for position in positions {
                    let y = min(max(position, 0), 1) * (size.height - 2)
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 2)),
                        with: .color(.yellow.opacity(0.9))
                    )
                }
            }
            .frame(width: 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    extension View {
        /// Shows the find strip on this pane's trailing edge while the bar is open and has matches.
        func findStrip(_ positions: [Double], isActive: Bool) -> some View {
            overlay(alignment: .trailing) {
                if isActive, !positions.isEmpty {
                    FindMatchStrip(positions: positions)
                }
            }
        }
    }
#endif
