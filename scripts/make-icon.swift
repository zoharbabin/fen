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
// Usage:  swift scripts/make-icon.swift [output.png]
//
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/fen-icon.png"
let S: CGFloat = 1024

let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// --- Squircle background (Apple icon grid: ~824pt art area, large corner radius)
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let radius = rect.width * 0.2237
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
ctx.saveGState()
squircle.addClip()

// Diagonal wetland gradient (deep teal top-left -> mossy green bottom-right).
let top = NSColor(srgbRed: 0.09, green: 0.42, blue: 0.46, alpha: 1) // deep teal
let bottom = NSColor(srgbRed: 0.11, green: 0.30, blue: 0.20, alpha: 1) // deep moss green
let gradient = NSGradient(starting: top, ending: bottom)!
gradient.draw(in: rect, angle: -55)

/// Subtle top highlight for a bit of dimensionality, like light on still water.
let highlight = NSGradient(
    colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0.0)]
)!
highlight.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
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
        .withDesign(.rounded) { return NSFont(descriptor: d, size: fFont.pointSize) ?? fFont }
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

image.unlockFocus()

// --- Write PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    fatalError("failed to encode PNG")
}

try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
