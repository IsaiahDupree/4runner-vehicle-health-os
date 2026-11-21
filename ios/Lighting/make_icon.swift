// Bounded, local Apple asset generation. No external image, service or existing icon is edited.
import AppKit
let output = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
  bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(srgbRed: 0.035, green: 0.047, blue: 0.059, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
let accent = NSColor(srgbRed: 0.98, green: 0.65, blue: 0.40, alpha: 1)
accent.withAlphaComponent(0.55).setStroke()
let border = NSBezierPath(roundedRect: NSRect(x: 104, y: 104, width: 816, height: 816), xRadius: 210, yRadius: 210)
border.lineWidth = 6; border.stroke()
let text = NSAttributedString(string: "Ⅳ", attributes: [.font: NSFont.systemFont(ofSize: 545, weight: .black), .foregroundColor: accent])
text.draw(at: NSPoint(x: (1024 - text.size().width)/2, y: 235))
let colors = [accent, NSColor(srgbRed: 0.26, green: 0.82, blue: 0.73, alpha: 1), NSColor(srgbRed: 0.30, green: 0.50, blue: 1, alpha: 1), NSColor.white]
for (i, color) in colors.enumerated() {
  color.setFill()
  NSBezierPath(roundedRect: NSRect(x: 312 + i*104, y: 240, width: 76, height: 12), xRadius: 6, yRadius: 6).fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
