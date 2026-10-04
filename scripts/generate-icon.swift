#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
try? fileManager.removeItem(at: outputDirectory)
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    let pixels = variant.pixels
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else {
        throw IconError.couldNotCreateBitmap
    }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.couldNotCreateContext
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    let iconBounds = NSRect(x: 64, y: 64, width: 896, height: 896)
    let iconShape = NSBezierPath(roundedRect: iconBounds, xRadius: 205, yRadius: 205)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.31, green: 0.22, blue: 0.86, alpha: 1),
    ])!
    gradient.draw(in: iconShape, angle: -52)

    let noShadow = NSShadow()
    noShadow.shadowColor = .clear
    noShadow.shadowBlurRadius = 0
    noShadow.shadowOffset = .zero
    noShadow.set()

    let highlight = NSBezierPath(roundedRect: iconBounds.insetBy(dx: 12, dy: 12), xRadius: 193, yRadius: 193)
    NSColor.white.withAlphaComponent(0.18).setStroke()
    highlight.lineWidth = 10
    highlight.stroke()

    func screenPath(_ rect: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: 58, yRadius: 58)
    }

    let rearScreen = screenPath(NSRect(x: 350, y: 410, width: 470, height: 300))
    NSColor.white.withAlphaComponent(0.43).setFill()
    rearScreen.fill()
    NSColor.white.withAlphaComponent(0.78).setStroke()
    rearScreen.lineWidth = 43
    rearScreen.stroke()

    let frontScreen = screenPath(NSRect(x: 204, y: 286, width: 470, height: 300))
    NSColor(calibratedRed: 0.26, green: 0.34, blue: 0.91, alpha: 1).setFill()
    frontScreen.fill()
    NSColor.white.setStroke()
    frontScreen.lineWidth = 48
    frontScreen.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.couldNotEncodePNG
    }
    try png.write(to: outputDirectory.appendingPathComponent(variant.name))
}

enum IconError: Error {
    case couldNotCreateBitmap
    case couldNotCreateContext
    case couldNotEncodePNG
}
