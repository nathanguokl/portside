#!/usr/bin/env swift
import AppKit

guard CommandLine.arguments.count == 3,
      let logo = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 800,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Usage: swift make-dmg-background.swift LOGO.png OUTPUT.png")
}

bitmap.size = NSSize(width: 640, height: 400)
let context = NSGraphicsContext(cgContext: bitmapContext.cgContext, flipped: true)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: 2, y: 2)
context.cgContext.translateBy(x: 0, y: 400)
context.cgContext.scaleBy(x: 1, y: -1)

let blue = NSColor(srgbRed: 8 / 255, green: 118 / 255, blue: 239 / 255, alpha: 1)
let ink = NSColor(srgbRed: 16 / 255, green: 41 / 255, blue: 71 / 255, alpha: 1)
NSColor(srgbRed: 0.95, green: 0.97, blue: 0.99, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 400)).fill()

func text(_ string: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (string as NSString).draw(in: NSRect(x: 30, y: y, width: 580, height: 40), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ])
}

logo.draw(in: NSRect(x: 215, y: 36, width: 44, height: 44), from: .zero,
          operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
("Portside" as NSString).draw(in: NSRect(x: 273, y: 37, width: 200, height: 44), withAttributes: [
    .font: NSFont.systemFont(ofSize: 31, weight: .semibold), .foregroundColor: ink
])
text("Drag Portside to Applications to install.", y: 101, size: 16, weight: .regular, color: ink.withAlphaComponent(0.75))

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 292, y: 220))
arrow.line(to: NSPoint(x: 348, y: 220))
arrow.move(to: NSPoint(x: 337, y: 209))
arrow.line(to: NSPoint(x: 348, y: 220))
arrow.line(to: NSPoint(x: 337, y: 231))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
blue.setStroke()
arrow.stroke()
text("Open Portside from Applications to get started.", y: 353, size: 13, weight: .regular,
     color: ink.withAlphaComponent(0.6))

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode the DMG background")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
