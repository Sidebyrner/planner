// Draws Planner's app icon and writes every size the iOS and macOS builds need.
//
//   cd apple && swift scripts/make-icon.swift
//
// Output: Planner/Assets.xcassets/AppIcon.appiconset/*.png (Contents.json is kept by hand).
// iOS gets a full-bleed square (the system rounds it); macOS gets the inset rounded
// tile with a soft shadow that Mac icons use.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: "Planner/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let skyTop = rgb(0x48A2FF)
let skyBottom = rgb(0x0A5BDB)
let ink = rgb(0x0A63E8)
let header = rgb(0xDDEBFF)
let ring = rgb(0x0B4FB8)

/// Shadows ignore the drawing transform, so size them to the current scale and point them
/// down the page (device space has y up).
func shadow(_ c: CGContext, y: CGFloat, blur: CGFloat, color: CGColor) {
    let s = abs(c.ctm.d)
    c.setShadow(offset: CGSize(width: 0, height: -y * s), blur: blur * s, color: color)
}

/// The artwork on a 1024 × 1024 canvas, y pointing down, filling the whole square.
func drawArt(_ c: CGContext) {
    // Background gradient.
    let colors = [skyTop, skyBottom] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1024), options: [])

    // The calendar page, with a soft shadow.
    let card = CGRect(x: 202, y: 236, width: 620, height: 584)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 112, cornerHeight: 112, transform: nil)
    c.saveGState()
    shadow(c, y: 22, blur: 46, color: rgb(0x002A6B, 0.35))
    c.addPath(cardPath)
    c.setFillColor(rgb(0xFFFFFF))
    c.fillPath()
    c.restoreGState()

    // Header band, clipped to the page.
    c.saveGState()
    c.addPath(cardPath)
    c.clip()
    c.setFillColor(header)
    c.fill(CGRect(x: card.minX, y: card.minY, width: card.width, height: 150))
    c.restoreGState()

    // Binder rings across the top edge.
    c.setFillColor(ring)
    for x in [354.0, 626.0] {
        let tab = CGRect(x: x, y: 190, width: 44, height: 108)
        c.addPath(CGPath(roundedRect: tab, cornerWidth: 22, cornerHeight: 22, transform: nil))
    }
    c.fillPath()

    // The check.
    c.setStrokeColor(ink)
    c.setLineWidth(84)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.move(to: CGPoint(x: 368, y: 588))
    c.addLine(to: CGPoint(x: 470, y: 690))
    c.addLine(to: CGPoint(x: 664, y: 478))
    c.strokePath()
}

/// A bitmap context with y pointing down, at `pixels` square.
func canvas(_ pixels: Int) -> CGContext {
    let c = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    c.interpolationQuality = .high
    c.translateBy(x: 0, y: CGFloat(pixels))
    c.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    return c
}

func write(_ c: CGContext, _ name: String) throws {
    let url = out.appendingPathComponent(name)
    guard let image = c.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "icon", code: 1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 2) }
    print("wrote \(name)")
}

/// iOS: opaque, full bleed.
func iOSIcon() -> CGContext {
    let c = canvas(1024)
    drawArt(c)
    return c
}

/// macOS: the art inside the standard 824-point rounded tile, centred, with a drop shadow.
func macIcon(_ pixels: Int) -> CGContext {
    let c = canvas(pixels)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    c.saveGState()
    shadow(c, y: 10, blur: 20, color: rgb(0x000000, 0.3))
    c.addPath(shape)
    c.setFillColor(skyBottom)
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(shape)
    c.clip()
    c.translateBy(x: tile.minX, y: tile.minY)
    c.scaleBy(x: tile.width / 1024, y: tile.height / 1024)
    drawArt(c)
    c.restoreGState()
    return c
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try write(iOSIcon(), "icon-ios-1024.png")
for px in [16, 32, 64, 128, 256, 512, 1024] {
    try write(macIcon(px), "icon-mac-\(px).png")
}
