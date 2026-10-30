import AppKit
import CoreGraphics

// Draws the app icon. Regenerate each size in disk/Assets.xcassets/AppIcon.appiconset with:
//   swift scripts/app-icon.swift <output.png> <pixels>
let args = CommandLine.arguments
let output = args[1]
let pixels = Int(args[2])!
let canvas: CGFloat = 1024

func color(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(hue: h, saturation: s, brightness: b, alpha: a).usingColorSpace(.sRGB)!.cgColor
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
ctx.interpolationQuality = .high

// The macOS icon grid: an 824 pt rounded square centered on a 1024 pt canvas, with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0.62, 0.5, 0.2))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let background = CGGradient(colorsSpace: space,
                            colors: [color(0.62, 0.42, 0.30), color(0.64, 0.55, 0.13)] as CFArray,
                            locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// The fan window: half a sunburst sitting on the attic floor.
let center = CGPoint(x: 512, y: 268)
let hole: CGFloat = 62
let rings: [(outer: CGFloat, hues: [(CGFloat, CGFloat)])] = [
    // (hue, share of the half circle), largest first, like the app's chart.
    (158, [(0.31, 0.46), (0.52, 0.26), (0.60, 0.16), (0.11, 0.12)]),
    (240, [(0.31, 0.30), (0.33, 0.16), (0.52, 0.17), (0.50, 0.09), (0.60, 0.16), (0.11, 0.12)]),
    (318, [(0.31, 0.21), (0.33, 0.25), (0.52, 0.19), (0.60, 0.17), (0.11, 0.18)]),
]
var inner = hole
for (index, ring) in rings.enumerated() {
    // Starts at the left of the floor and sweeps clockwise over the top, ending at the right.
    var start = CGFloat.pi
    let brightness: CGFloat = 0.93 - CGFloat(index) * 0.08
    let saturation: CGFloat = 0.68 - CGFloat(index) * 0.07
    for (hue, share) in ring.hues {
        let end = start - CGFloat.pi * share
        let path = CGMutablePath()
        path.addArc(center: center, radius: ring.outer, startAngle: start, endAngle: end, clockwise: true)
        path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: false)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color(hue, saturation, brightness))
        ctx.fillPath()
        // Dark seams keep the segments readable at small sizes.
        ctx.addPath(path)
        ctx.setStrokeColor(color(0.64, 0.55, 0.13))
        ctx.setLineWidth(9)
        ctx.strokePath()
        start = end
    }
    inner = ring.outer
}

// The roof: one bold gable over the window, with the floor beneath it.
let cream = color(0.11, 0.10, 0.98)
let roof = CGMutablePath()
roof.move(to: CGPoint(x: 150, y: 452))
roof.addLine(to: CGPoint(x: 512, y: 812))
roof.addLine(to: CGPoint(x: 874, y: 452))
ctx.addPath(roof)
ctx.setStrokeColor(cream)
ctx.setLineWidth(58)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

ctx.setFillColor(cream)
ctx.addPath(CGPath(roundedRect: CGRect(x: 150, y: 212, width: 724, height: 44), cornerWidth: 22, cornerHeight: 22, transform: nil))
ctx.fillPath()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
