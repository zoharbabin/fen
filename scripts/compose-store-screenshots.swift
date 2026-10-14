#!/usr/bin/env swift
//
// compose-store-screenshots.swift: turn raw captures into the App Store screenshot sizes.
//
// Each picture gets the app icon's teal and moss gradient, a caption, and the capture with rounded
// corners and a soft shadow. Sizes are the ones App Store Connect takes:
//   Mac     2880 x 1800
//   iPhone  1320 x 2868  (6.9 inch)
//   iPad    2064 x 2752  (13 inch)
//
// Usage:  swift scripts/compose-store-screenshots.swift <raw-dir> <output-dir>
// Raw names: mac-*.png, phone-*.png, pad-*.png (see scripts/make-store-screenshots.sh).
//
import AppKit

struct Slide {
    let raw: String
    let output: String
    let caption: String
}

struct Layout {
    let canvas: CGSize
    /// Where the capture goes: its top edge from the canvas top, and the largest size it may fill.
    let captureTop: CGFloat
    let captureMax: CGSize
    let captionSize: CGFloat
    let captionTop: CGFloat
    /// Corner radius in canvas pixels.
    let radius: CGFloat
}

let mac = Layout(
    canvas: CGSize(width: 2880, height: 1800), captureTop: 420, captureMax: CGSize(width: 2300, height: 1300),
    captionSize: 100, captionTop: 80, radius: 44
)
let phone = Layout(
    canvas: CGSize(width: 1320, height: 2868), captureTop: 470, captureMax: CGSize(width: 1100, height: 2300),
    captionSize: 96, captionTop: 110, radius: 96
)
let pad = Layout(
    canvas: CGSize(width: 2064, height: 2752), captureTop: 470, captureMax: CGSize(width: 1700, height: 2200),
    captionSize: 120, captionTop: 110, radius: 72
)

let macSlides = [
    Slide(raw: "mac-split", output: "mac-1-write", caption: "Write on the left.\nSee it on the right."),
    Slide(raw: "mac-preview", output: "mac-2-preview", caption: "Math, tables and diagrams,\ndrawn for you."),
    Slide(raw: "mac-search", output: "mac-3-search", caption: "Find notes by words\nor by meaning."),
    Slide(raw: "mac-ask", output: "mac-4-ask", caption: "Ask your notes.\nGet answers with sources."),
    Slide(raw: "mac-related", output: "mac-5-related", caption: "See related notes\nwhile you write."),
]
func deviceSlides(_ prefix: String) -> [Slide] {
    [
        Slide(raw: "\(prefix)-preview", output: "\(prefix)-1-preview", caption: "Your notes, beautifully rendered."),
        Slide(raw: "\(prefix)-editor", output: "\(prefix)-2-write", caption: "Plain Markdown, in plain files."),
        Slide(raw: "\(prefix)-math", output: "\(prefix)-3-math", caption: "Math and tables, drawn for you."),
        Slide(raw: "\(prefix)-search", output: "\(prefix)-4-search", caption: "Find notes by words or by meaning."),
        Slide(raw: "\(prefix)-ask", output: "\(prefix)-5-ask", caption: "Ask your notes. Get answers with sources."),
    ]
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: compose-store-screenshots.swift <raw-dir> <output-dir>\n".utf8))
    exit(2)
}

let rawDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let teal = NSColor(srgbRed: 0.09, green: 0.42, blue: 0.46, alpha: 1)
let moss = NSColor(srgbRed: 0.11, green: 0.30, blue: 0.20, alpha: 1)

func compose(_ slide: Slide, layout: Layout) throws -> Bool {
    let source = rawDir.appendingPathComponent("\(slide.raw).png")
    guard let capture = NSImage(contentsOf: source) else { return false }
    let w = Int(layout.canvas.width), h = Int(layout.canvas.height)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    let canvas = CGRect(origin: .zero, size: layout.canvas)

    NSGradient(starting: teal, ending: moss)?.draw(in: canvas, angle: -60)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.14), NSColor(white: 1, alpha: 0)])?
        .draw(in: CGRect(x: 0, y: canvas.height * 0.55, width: canvas.width, height: canvas.height * 0.45), angle: -90)

    // Caption, centered, near the top. AppKit's origin is bottom-left.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineHeightMultiple = 1.05
    let text = NSAttributedString(string: slide.caption, attributes: [
        .font: NSFont.systemFont(ofSize: layout.captionSize, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
    ])
    let captionHeight = layout.captureTop - layout.captionTop - 40
    text.draw(in: CGRect(
        x: 80, y: canvas.height - layout.captionTop - captionHeight, width: canvas.width - 160, height: captionHeight
    ))

    // Capture: scaled to fit, rounded, with a shadow.
    let size = capture.size
    let scale = min(layout.captureMax.width / size.width, layout.captureMax.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    let frame = CGRect(
        x: (canvas.width - fitted.width) / 2, y: canvas.height - layout.captureTop - fitted.height,
        width: fitted.width, height: fitted.height
    )
    let rounded = NSBezierPath(roundedRect: frame, xRadius: layout.radius, yRadius: layout.radius)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: NSColor(white: 0, alpha: 0.45).cgColor)
    NSColor.black.setFill()
    rounded.fill()
    context.restoreGState()
    context.saveGState()
    rounded.addClip()
    capture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    // App Store Connect wants pictures without an alpha channel, so copy into a context that skips it.
    guard let cg = bitmap.cgImage,
          let flat = CGContext(
              data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          )
    else { return false }
    flat.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let flatImage = flat.makeImage(),
          let png = NSBitmapImageRep(cgImage: flatImage).representation(using: .png, properties: [:])
    else { return false }
    try png.write(to: outDir.appendingPathComponent("\(slide.output).png"))
    return true
}

var made = 0
for (slides, layout) in [(macSlides, mac), (deviceSlides("phone"), phone), (deviceSlides("pad"), pad)] {
    for slide in slides where try compose(slide, layout: layout) {
        made += 1
        print("wrote \(slide.output).png")
    }
}

print("\(made) pictures in \(outDir.path)")
