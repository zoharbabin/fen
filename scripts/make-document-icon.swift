#!/usr/bin/env swift
//
// make-document-icon.swift — render Fen's Finder document icon (for .md files)
// to a 1024×1024 PNG. See issue #14 (github.com/zoharbabin/fen/issues/14).
//
// Concept: a plain parchment page with a folded top-right corner — the
// familiar "document" silhouette, so it reads as a file rather than the
// app itself — carrying a small mark in the app icon's wetland palette
// (teal-to-moss gradient, amber reed accent) so a Fen-owned .md file is
// still recognizable at a glance next to icons from other editors.
//
// Usage:  swift scripts/make-document-icon.swift [output.png]
//
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/fen-document-icon.png"
let S: CGFloat = 1024

let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// --- Page geometry: a tall rounded rectangle with a folded top-right corner,
// sized within Apple's document-icon safe area (page art narrower than the
// full canvas, centered, so it doesn't look like a squircle app icon).
let pageWidth: CGFloat = S * 0.62
let pageHeight: CGFloat = S * 0.80
let pageX = (S - pageWidth) / 2
let pageY = (S - pageHeight) / 2
let cornerFold: CGFloat = pageWidth * 0.28
let cornerRadius: CGFloat = pageWidth * 0.05

let pagePath = NSBezierPath()
pagePath.move(to: CGPoint(x: pageX + cornerRadius, y: pageY))
pagePath.line(to: CGPoint(x: pageX + pageWidth - cornerFold, y: pageY))
pagePath.line(to: CGPoint(x: pageX + pageWidth, y: pageY + cornerFold))
pagePath.line(to: CGPoint(x: pageX + pageWidth, y: pageY + pageHeight - cornerRadius))
pagePath.curve(
    to: CGPoint(x: pageX + pageWidth - cornerRadius, y: pageY + pageHeight),
    controlPoint1: CGPoint(x: pageX + pageWidth, y: pageY + pageHeight),
    controlPoint2: CGPoint(x: pageX + pageWidth, y: pageY + pageHeight)
)
pagePath.line(to: CGPoint(x: pageX + cornerRadius, y: pageY + pageHeight))
pagePath.curve(
    to: CGPoint(x: pageX, y: pageY + pageHeight - cornerRadius),
    controlPoint1: CGPoint(x: pageX, y: pageY + pageHeight),
    controlPoint2: CGPoint(x: pageX, y: pageY + pageHeight)
)
pagePath.line(to: CGPoint(x: pageX, y: pageY + cornerRadius))
pagePath.curve(
    to: CGPoint(x: pageX + cornerRadius, y: pageY),
    controlPoint1: CGPoint(x: pageX, y: pageY),
    controlPoint2: CGPoint(x: pageX, y: pageY)
)
pagePath.close()

// Soft drop shadow, like a page resting on the Finder background.
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
shadow.shadowOffset = NSSize(width: 0, height: -S * 0.012)
shadow.shadowBlurRadius = S * 0.02
shadow.set()

/// Parchment page fill.
let parchment = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1)
parchment.setFill()
pagePath.fill()
ctx.restoreGState()

/// Thin page border, mossy-teal to tie it to the app icon palette.
let borderColor = NSColor(srgbRed: 0.11, green: 0.30, blue: 0.20, alpha: 0.35)
borderColor.setStroke()
pagePath.lineWidth = S * 0.004
pagePath.stroke()

// --- Folded corner: a small triangle in the top-right, shaded darker than
// the page to read as a fold, echoing the app icon's teal-to-moss gradient.
ctx.saveGState()
let foldPath = NSBezierPath()
foldPath.move(to: CGPoint(x: pageX + pageWidth - cornerFold, y: pageY))
foldPath.line(to: CGPoint(x: pageX + pageWidth, y: pageY + cornerFold))
foldPath.line(to: CGPoint(x: pageX + pageWidth - cornerFold, y: pageY + cornerFold))
foldPath.close()
foldPath.addClip()
let foldTop = NSColor(srgbRed: 0.09, green: 0.42, blue: 0.46, alpha: 1) // deep teal
let foldBottom = NSColor(srgbRed: 0.11, green: 0.30, blue: 0.20, alpha: 1) // deep moss
NSGradient(starting: foldTop, ending: foldBottom)!.draw(
    in: CGRect(x: pageX + pageWidth - cornerFold, y: pageY, width: cornerFold, height: cornerFold),
    angle: -45
)
ctx.restoreGState()
foldPath.lineWidth = S * 0.004
borderColor.setStroke()
foldPath.stroke()

/// --- Small reed-amber accent mark near the bottom of the page, echoing the
/// app icon's reed blade, plus a few horizontal "text lines" for a document feel.
let lineColor = NSColor(srgbRed: 0.11, green: 0.30, blue: 0.20, alpha: 0.18)
lineColor.setFill()
let lineInsetX = pageWidth * 0.16
let lineHeight = S * 0.014
let lineStartY = pageY + pageHeight * 0.62
let lineWidths: [CGFloat] = [0.68, 0.55, 0.62]
for (i, widthFraction) in lineWidths.enumerated() {
    let y = lineStartY - CGFloat(i) * (lineHeight * 2.2)
    let rect = CGRect(
        x: pageX + lineInsetX, y: y,
        width: pageWidth * widthFraction, height: lineHeight
    )
    NSBezierPath(roundedRect: rect, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
}

let reedAmber = NSColor(srgbRed: 0.91, green: 0.71, blue: 0.25, alpha: 1)
reedAmber.setStroke()
let bladeBaseX = pageX + lineInsetX
let bladeBaseY = pageY + pageHeight * 0.22
let bladeHeight = pageHeight * 0.16
let blade = NSBezierPath()
blade.lineWidth = pageWidth * 0.035
blade.lineCapStyle = .round
blade.move(to: CGPoint(x: bladeBaseX, y: bladeBaseY))
blade.curve(
    to: CGPoint(x: bladeBaseX + bladeHeight * 0.22, y: bladeBaseY + bladeHeight),
    controlPoint1: CGPoint(x: bladeBaseX + bladeHeight * 0.05, y: bladeBaseY + bladeHeight * 0.55),
    controlPoint2: CGPoint(x: bladeBaseX + bladeHeight * 0.22, y: bladeBaseY + bladeHeight * 0.85)
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
