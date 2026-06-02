#!/usr/bin/swift
// Run with: swift generate_icon.swift
// Outputs AppIcon.png (1024x1024) in the current directory.

import Foundation
import CoreGraphics
import AppKit

let size = 1024
let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.scaleBy(x: 1, y: -1)
ctx.translateBy(x: 0, y: -CGFloat(size))

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
}

// Background: deep indigo gradient
let bg = CGMutablePath()
bg.addRoundedRect(in: CGRect(x: 0, y: 0, width: size, height: size), cornerWidth: 220, cornerHeight: 220)
ctx.addPath(bg)

let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0.13, 0.11, 0.38), rgb(0.22, 0.16, 0.56)] as CFArray,
    locations: [0, 1])!
ctx.saveGState()
ctx.addPath(bg)
ctx.clip()
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(size)), options: [])
ctx.restoreGState()

// Shelf plank
let shelfY: CGFloat = 680
let shelf = CGRect(x: 90, y: shelfY, width: CGFloat(size) - 180, height: 36)
ctx.setFillColor(rgb(0.55, 0.38, 0.18))
ctx.fill(shelf)
// shelf shadow
ctx.setFillColor(rgb(0, 0, 0, 0.22))
ctx.fill(CGRect(x: 90, y: shelfY + 36, width: CGFloat(size) - 180, height: 12))

// Books — (x, width, height, r, g, b)
let books: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (130,  98, 310, 0.90, 0.28, 0.28),   // red
    (240, 110, 380, 0.22, 0.60, 0.86),   // blue
    (362,  82, 260, 0.98, 0.76, 0.22),   // yellow
    (456, 120, 340, 0.24, 0.78, 0.56),   // green
    (588,  90, 390, 0.88, 0.42, 0.78),   // pink
    (690, 105, 280, 0.40, 0.62, 0.95),   // light blue
    (807,  90, 355, 0.96, 0.55, 0.22),   // orange
]

for (x, w, h, r, g, b) in books {
    let bookRect = CGRect(x: x, y: shelfY - h, width: w, height: h)
    // spine
    ctx.setFillColor(rgb(r, g, b))
    ctx.fill(bookRect)
    // highlight strip on left edge
    ctx.setFillColor(rgb(min(r+0.18,1), min(g+0.18,1), min(b+0.18,1), 0.6))
    ctx.fill(CGRect(x: x, y: shelfY - h, width: 10, height: h))
    // dark right edge
    ctx.setFillColor(rgb(r*0.6, g*0.6, b*0.6, 0.8))
    ctx.fill(CGRect(x: x + w - 8, y: shelfY - h, width: 8, height: h))
    // page lines at top
    ctx.setFillColor(rgb(0.95, 0.92, 0.85))
    for i in 0..<4 {
        ctx.fill(CGRect(x: x + 6, y: shelfY - h + 14 + CGFloat(i) * 5, width: w - 14, height: 2))
    }
}

// Save
let cgImage = ctx.makeImage()!
let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
let tiff = nsImage.tiffRepresentation!
let bitmap = NSBitmapImageRep(data: tiff)!
let png = bitmap.representation(using: .png, properties: [:])!

let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("AppIcon.png")
try! png.write(to: outURL)
print("Saved: \(outURL.path)")
