#!/usr/bin/env swift
// Draws MacUp's icon and writes build/MacUp.icns.
//
// The mark is kept to two shapes so it survives being 16 points wide: an
// arrow pointing up, standing on a base. Up for what the app is for, the
// base for the machine it does not disturb.
//
//   swift scripts/make-icon.swift

import AppKit
import CoreGraphics
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: "build/MacUp.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Top-down coordinates read better for layout; flip once here.
    func y(_ value: CGFloat) -> CGFloat { s - value * s }
    func x(_ value: CGFloat) -> CGFloat { value * s }

    // The rounded square, close to the macOS corner curve.
    let plate = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth: s * 0.2237,
        cornerHeight: s * 0.2237,
        transform: nil
    )
    context.saveGState()
    context.addPath(plate)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: 0.35, green: 0.62, blue: 1.00, alpha: 1),
            CGColor(red: 0.03, green: 0.31, blue: 0.78, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    context.restoreGState()

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

    // The arrow: a stem with a chevron head.
    let stem = CGPath(
        roundedRect: CGRect(x: x(0.45), y: y(0.66), width: s * 0.10, height: s * 0.34),
        cornerWidth: s * 0.05,
        cornerHeight: s * 0.05,
        transform: nil
    )
    context.addPath(stem)
    context.fillPath()

    context.setLineWidth(s * 0.10)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: x(0.28), y: y(0.47)))
    context.addLine(to: CGPoint(x: x(0.50), y: y(0.27)))
    context.addLine(to: CGPoint(x: x(0.72), y: y(0.47)))
    context.strokePath()

    // The base it stands on.
    let base = CGPath(
        roundedRect: CGRect(x: x(0.26), y: y(0.79), width: s * 0.48, height: s * 0.075),
        cornerWidth: s * 0.037,
        cornerHeight: s * 0.037,
        transform: nil
    )
    context.addPath(base)
    context.fillPath()

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = draw(size: size) else { exit(1) }
    // An iconset wants each size as both 1x and the 2x of the size below it.
    if size <= 512 {
        try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    }
    if size >= 32 {
        let half = size / 2
        try data.write(to: iconset.appendingPathComponent("icon_\(half)x\(half)@2x.png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", "build/MacUp.icns", iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
try? FileManager.default.removeItem(at: iconset)
print("build/MacUp.icns")
