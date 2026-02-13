#!/usr/bin/env swift

// ============================================================
// Generate macOS app icon from SF Symbol "mic.fill"
// Outputs PNGs into the AppIcon.appiconset directory
// Usage: swift scripts/generate-icon.swift
// ============================================================

import AppKit
import Foundation

let assetDir = "DuaTalk/Resources/Assets.xcassets/AppIcon.appiconset"

// macOS icon sizes: (point size, scale) -> pixel size
let iconSizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

func generateIcon(pixelSize: Int) -> Data? {
    // Use NSBitmapImageRep directly to control exact pixel dimensions
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    bitmap.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context

    let size = NSSize(width: pixelSize, height: pixelSize)

    // Background: rounded rectangle with gradient
    let cornerRadius = CGFloat(pixelSize) * 0.22
    let rect = CGRect(origin: .zero, size: size)
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Gradient: dark blue to teal
    let gradient = NSGradient(
        starting: NSColor(red: 0.1, green: 0.1, blue: 0.35, alpha: 1.0),
        ending: NSColor(red: 0.15, green: 0.35, blue: 0.55, alpha: 1.0)
    )!
    gradient.draw(in: path, angle: -45)

    // Subtle border
    NSColor(white: 1.0, alpha: 0.1).setStroke()
    path.lineWidth = max(CGFloat(pixelSize) * 0.01, 0.5)
    path.stroke()

    // Draw mic.fill SF Symbol
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: CGFloat(pixelSize) * 0.48, weight: .medium)
    if let symbolImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig)
    {
        let symbolSize = symbolImage.size
        let x = (CGFloat(pixelSize) - symbolSize.width) / 2
        let y = (CGFloat(pixelSize) - symbolSize.height) / 2

        // Draw white symbol
        let tinted = NSImage(size: symbolSize)
        tinted.lockFocus()
        NSColor.white.set()
        let symbolRect = CGRect(origin: .zero, size: symbolSize)
        symbolImage.draw(in: symbolRect)
        symbolRect.fill(using: .sourceIn)
        tinted.unlockFocus()

        tinted.draw(
            in: CGRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.95
        )
    }

    NSGraphicsContext.restoreGraphicsState()

    return bitmap.representation(using: .png, properties: [:])
}

// Generate icons
var images: [[String: String]] = []

for (points, scale) in iconSizes {
    let pixelSize = points * scale
    let filename = "icon_\(points)x\(points)@\(scale)x.png"
    let outputPath = "\(assetDir)/\(filename)"

    print("Generating \(filename) (\(pixelSize)x\(pixelSize)px)...")

    guard let pngData = generateIcon(pixelSize: pixelSize) else {
        print("ERROR: Failed to generate icon for size \(pixelSize)")
        continue
    }

    try! pngData.write(to: URL(fileURLWithPath: outputPath))

    images.append([
        "filename": filename,
        "idiom": "mac",
        "scale": "\(scale)x",
        "size": "\(points)x\(points)",
    ])
}

// Write Contents.json
let contents: [String: Any] = [
    "images": images,
    "info": [
        "author": "xcode",
        "version": 1,
    ],
]

let jsonData = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
let jsonString = String(data: jsonData, encoding: .utf8)!
try! jsonString.write(toFile: "\(assetDir)/Contents.json", atomically: true, encoding: .utf8)

print("\nDone! Generated \(iconSizes.count) icon sizes in \(assetDir)/")
