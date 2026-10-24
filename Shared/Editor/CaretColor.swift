import SwiftUI

/// Shared helper: pick a readable caret/insertion-point color for a background.
@MainActor
func caretColor(for background: PlatformColor) -> PlatformColor {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    #if os(macOS)
        (background.usingColorSpace(.deviceRGB) ?? background).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    #else
        background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    #endif
    let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
    return luminance < 0.5 ? .white : .black
}
