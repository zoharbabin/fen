#!/usr/bin/env swift
//
// make-icon.swift — render the Fen app icon to a 1024×1024 PNG.
//
// Concept: a bold rounded "F" on a wetland gradient (deep teal to green,
// evoking still water and reeds), with a single amber reed blade curving
// beside it — a fen is a self-sustaining wetland that keeps growing,
// which is the idea behind the app: notes that grow into more. Kept to
// one thick blade (rather than several thin ones) so the mark still
// reads clearly at 16–32px Dock/Finder sizes.
//
// Usage:  swift scripts/make-icon.swift [output.png] [--store]
//
// --store writes the App Store version: a full-bleed square with no transparency. Apple rejects
// an icon with alpha, and the system rounds the corners itself.
//
import AppKit

let storeIcon = CommandLine.arguments.contains("--store")
let paths = CommandLine.arguments.dropFirst().filter { $0 != "--store" }
let outPath = paths.first ?? "/tmp/fen-icon.png"
let S: CGFloat = 1024

// Draw into a 1024 x 1024 pixel bitmap.
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("no bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let ctx = graphics.cgContext

// --- Squircle background (Apple icon grid: ~824pt art area, large corner radius)
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let radius = rect.width * 0.2237
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
ctx.saveGState()
let background = storeIcon ? CGRect(x: 0, y: 0, width: S, height: S) : rect
if !storeIcon {
    squircle.addClip()
}

// Diagonal wetland gradient (deep teal top-left -> mossy green bottom-right).
let top = NSColor(srgbRed: 0.09, green: 0.42, blue: 0.46, alpha: 1) // deep teal
let bottom = NSColor(srgbRed: 0.11, green: 0.30, blue: 0.20, alpha: 1) // deep moss green
let gradient = NSGradient(starting: top, ending: bottom)!
gradient.draw(in: background, angle: -55)

/// Subtle top highlight for a bit of dimensionality, like light on still water.
let highlight = NSGradient(
    colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0.0)]
)!
highlight.draw(
    in: CGRect(x: background.minX, y: background.midY, width: background.width, height: background.height / 2),
    angle: -90
)
ctx.restoreGState()

// --- Mark geometry: bold "F" on the left, three reed blades rising beside it.
let markHeight = rect.height * 0.42
let markCenterY = rect.midY
let white = NSColor(srgbRed: 0.96, green: 0.98, blue: 0.96, alpha: 1)
let reedAmber = NSColor(srgbRed: 0.91, green: 0.71, blue: 0.25, alpha: 1) // sunlit amber

// "F" drawn with a heavy rounded system font.
let fFont = NSFont.systemFont(ofSize: markHeight * 1.30, weight: .heavy)
let roundedF: NSFont = {
    if let d = fFont.fontDescriptor
        .withDesign(.rounded) {
        return NSFont(descriptor: d, size: fFont.pointSize) ?? fFont
    }
    return fFont
}()

let fAttrs: [NSAttributedString.Key: Any] = [.font: roundedF, .foregroundColor: white]
let fStr = NSAttributedString(string: "F", attributes: fAttrs)
let fSize = fStr.size()
let fX = rect.minX + rect.width * 0.20
let fRect = CGRect(x: fX, y: markCenterY - fSize.height / 2, width: fSize.width, height: fSize.height)
fStr.draw(in: fRect)

// A single bold reed blade curving beside the "F" — thick enough to
// still read at Dock/Finder sizes.
let reedBaseX = fX + fSize.width + rect.width * 0.19
let reedBaseY = markCenterY - markHeight * 0.50
let reedHeight = markHeight * 1.12
let reedLean: CGFloat = 0.10
let tipX = reedBaseX + reedHeight * reedLean
let controlX = reedBaseX + reedHeight * reedLean * 0.4

reedAmber.setStroke()
let blade = NSBezierPath()
blade.lineWidth = rect.width * 0.052
blade.lineCapStyle = .round
blade.move(to: CGPoint(x: reedBaseX, y: reedBaseY))
blade.curve(
    to: CGPoint(x: tipX, y: reedBaseY + reedHeight),
    controlPoint1: CGPoint(x: controlX, y: reedBaseY + reedHeight * 0.55),
    controlPoint2: CGPoint(x: tipX, y: reedBaseY + reedHeight * 0.85)
)
blade.stroke()

NSGraphicsContext.restoreGraphicsState()

/// --- Write PNG
var png: Data
if storeIcon {
    // Copy into a context that skips the alpha channel, so the PNG has none.
    guard let cg = bitmap.cgImage,
          let flat = CGContext(
              data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else { fatalError("no flat context") }
    flat.draw(cg, in: CGRect(x: 0, y: 0, width: S, height: S))
    guard let flatImage = flat.makeImage() else { fatalError("no flat image") }
    png = NSBitmapImageRep(cgImage: flatImage).representation(using: .png, properties: [:]) ?? Data()
} else {
    png = bitmap.representation(using: .png, properties: [:]) ?? Data()
}

if png.isEmpty {
    fatalError("failed to encode PNG")
}

try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
