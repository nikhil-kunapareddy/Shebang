// Draws Resources/dmg-background.tiff, the drag-to-install backdrop of the DMG window.
//
//   swift Scripts/make-dmg-background.swift Resources/dmg-background.tiff
//
// The TIFF holds a 72 dpi and a 144 dpi page so Finder picks the sharp one on Retina displays.
// Geometry matches Scripts/dmg-settings.py: a 600x400 pt window with icons centred at x 150 and 450, y 190.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = CGSize(width: 600, height: 400)
let iconCentreY: CGFloat = 190

func render(scale: CGFloat) -> CGImage {
    let context = CGContext(
        data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)
    // Draw in top-left coordinates, like Finder's icon positions.
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1),
                 CGColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // Arrow from the app icon towards the Applications folder.
    let arrow = CGColor(srgbRed: 0.55, green: 0.55, blue: 0.6, alpha: 1)
    context.setStrokeColor(arrow)
    context.setFillColor(arrow)
    context.setLineWidth(6)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 240, y: iconCentreY))
    context.addLine(to: CGPoint(x: 342, y: iconCentreY))
    context.strokePath()
    context.move(to: CGPoint(x: 362, y: iconCentreY))
    context.addLine(to: CGPoint(x: 336, y: iconCentreY - 17))
    context.addLine(to: CGPoint(x: 336, y: iconCentreY + 17))
    context.closePath()
    context.fillPath()

    let font = CTFontCreateUIFontForLanguage(.system, 14, nil)!
    let text = NSAttributedString(string: "Drag Shebang to Applications to install", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1),
    ])
    let line = CTLineCreateWithAttributedString(text)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    // Core Text draws upright in bottom-left coordinates, so flip back around the baseline.
    context.saveGState()
    context.textMatrix = .identity
    context.translateBy(x: (size.width - CGFloat(width)) / 2, y: 330)
    context.scaleBy(x: 1, y: -1)
    CTLineDraw(line, context)
    context.restoreGState()

    return context.makeImage()!
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/dmg-background.tiff")
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
for scale in [1, 2] as [CGFloat] {
    let dpi = 72 * scale
    CGImageDestinationAddImage(destination, render(scale: scale), [
        kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5],  // LZW
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(output.path)") }
print("Wrote \(output.path)")
