import AppKit
import Foundation

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
let artwork = NSImage(size: NSSize(width: 1024, height: 1024))
artwork.lockFocus()
let shape = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205)
let gradient = NSGradient(starting: NSColor(red: 0.47, green: 0.43, blue: 0.96, alpha: 1), ending: NSColor(red: 0.25, green: 0.20, blue: 0.67, alpha: 1))!
gradient.draw(in: shape, angle: -60)
let text: NSString = "php"
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 260, weight: .bold), .foregroundColor: NSColor.white]
let size = text.size(withAttributes: attributes)
text.draw(at: NSPoint(x: (1024-size.width)/2, y: 430), withAttributes: attributes)
let arrows = NSBezierPath()
arrows.lineWidth = 34; arrows.lineCapStyle = .round; arrows.lineJoinStyle = .round
arrows.move(to: NSPoint(x: 285, y: 355)); arrows.line(to: NSPoint(x: 739, y: 355))
arrows.move(to: NSPoint(x: 675, y: 410)); arrows.line(to: NSPoint(x: 739, y: 355)); arrows.line(to: NSPoint(x: 675, y: 300))
arrows.move(to: NSPoint(x: 739, y: 245)); arrows.line(to: NSPoint(x: 285, y: 245))
arrows.move(to: NSPoint(x: 349, y: 300)); arrows.line(to: NSPoint(x: 285, y: 245)); arrows.line(to: NSPoint(x: 349, y: 190))
NSColor.white.withAlphaComponent(0.8).setStroke(); arrows.stroke()
artwork.unlockFocus()
for base in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = base * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination + "/icon_\(base)x\(base)\(suffix).png"))
    }
}
