import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let artwork = NSImage(contentsOfFile: CommandLine.arguments[1]),
      artwork.isValid, artwork.size.width > 0, artwork.size.width == artwork.size.height else {
    fputs("Usage: swift Resources/MakeIcon.swift <square-source.png> <output.iconset>\n", stderr)
    exit(1)
}
let destination = CommandLine.arguments[2]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for base in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = base * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.current?.imageInterpolation = .high
        // Preserve the supplied artwork inside the app's existing macOS icon footprint.
        let drawingScale = CGFloat(pixels) / 1024
        let bounds = NSRect(x: 64 * drawingScale, y: 64 * drawingScale, width: 896 * drawingScale, height: 896 * drawingScale)
        NSBezierPath(roundedRect: bounds, xRadius: 205 * drawingScale, yRadius: 205 * drawingScale).addClip()
        artwork.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination + "/icon_\(base)x\(base)\(suffix).png"))
    }
}
