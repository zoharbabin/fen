#!/usr/bin/env swift
//
// make-icon.swift — render the MacDown (Swift) app icon to a 1024×1024 PNG.
//
// Concept: the classic Markdown "M↓" mark on a refreshed blue squircle, with
// the down-arrow in Swift's signature orange — "MacDown, in Swift."
//
// Usage:  swift scripts/make-icon.swift [output.png]
//
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/macdown-icon.png"
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

// Diagonal blue gradient (cyan top-left -> deep blue bottom-right), MacDown heritage.
let top = NSColor(srgbRed: 0.32, green: 0.78, blue: 0.96, alpha: 1)      // cyan
let bottom = NSColor(srgbRed: 0.12, green: 0.45, blue: 0.92, alpha: 1)   // blue
let gradient = NSGradient(starting: top, ending: bottom)!
gradient.draw(in: rect, angle: -55)

// Subtle top highlight for a bit of dimensionality.
let highlight = NSGradient(
    colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0.0)]
)!
highlight.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
ctx.restoreGState()

// --- Mark geometry: "M" on the left, "↓" on the right, vertically centered.
let markHeight = rect.height * 0.40
let markCenterY = rect.midY
let white = NSColor.white
let swiftOrange = NSColor(srgbRed: 0.941, green: 0.318, blue: 0.220, alpha: 1) // #F05138

// "M" drawn with a heavy rounded system font.
let mFont = NSFont.systemFont(ofSize: markHeight * 1.30, weight: .heavy)
let roundedM: NSFont = {
    if let d = mFont.fontDescriptor.withDesign(.rounded) { return NSFont(descriptor: d, size: mFont.pointSize) ?? mFont }
    return mFont
}()
let mAttrs: [NSAttributedString.Key: Any] = [.font: roundedM, .foregroundColor: white]
let mStr = NSAttributedString(string: "M", attributes: mAttrs)
let mSize = mStr.size()
let mX = rect.minX + rect.width * 0.165
let mRect = CGRect(x: mX, y: markCenterY - mSize.height / 2, width: mSize.width, height: mSize.height)
mStr.draw(in: mRect)

// Down arrow (Swift orange): vertical stem + chevron head, rounded caps.
// Raised slightly so it optically centers with the capital "M".
let arrowCenterX = mX + mSize.width + rect.width * 0.185
let arrowCenterY = markCenterY + markHeight * 0.07
let stemTop = arrowCenterY + markHeight / 2
let stemBottom = arrowCenterY - markHeight / 2
let lineWidth = markHeight * 0.20

swiftOrange.setStroke()
let stem = NSBezierPath()
stem.lineWidth = lineWidth
stem.lineCapStyle = .round
stem.lineJoinStyle = .round
stem.move(to: CGPoint(x: arrowCenterX, y: stemTop))
stem.line(to: CGPoint(x: arrowCenterX, y: stemBottom))
stem.stroke()

let headSpan = markHeight * 0.42
let head = NSBezierPath()
head.lineWidth = lineWidth
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.move(to: CGPoint(x: arrowCenterX - headSpan, y: stemBottom + headSpan))
head.line(to: CGPoint(x: arrowCenterX, y: stemBottom))
head.line(to: CGPoint(x: arrowCenterX + headSpan, y: stemBottom + headSpan))
head.stroke()

image.unlockFocus()

// --- Write PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode PNG")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
