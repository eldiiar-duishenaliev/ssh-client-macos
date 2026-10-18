#!/usr/bin/env swift
//
// Renders the app icon at 1024x1024 as a PNG.
//
// Design: a rounded "app tile" with an indigo→cyan gradient, carrying a white
// terminal prompt (`>_`) with a dotted hop arc above it — the prompt stands for
// the terminal, the arc and its two nodes for reaching a host through a
// bastion.
//
// Usage: swift Scripts/make-icon.swift <output.png>
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024.png"

let size = 1024
let side = CGFloat(size)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("could not create a drawing context\n".utf8))
    exit(1)
}

// Work in top-left origin coordinates.
context.translateBy(x: 0, y: side)
context.scaleBy(x: 1, y: -1)

let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

// MARK: - Tile

let inset: CGFloat = 112
let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 190, cornerHeight: 190, transform: nil)

context.saveGState()
context.addPath(tilePath)
context.clip()

let colors = [
    CGColor(red: 0.20, green: 0.16, blue: 0.48, alpha: 1), // indigo
    CGColor(red: 0.02, green: 0.58, blue: 0.74, alpha: 1)  // cyan
] as CFArray

if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: inset, y: inset),
        end: CGPoint(x: side - inset, y: side - inset),
        options: []
    )
}
context.restoreGState()

// Soft top highlight so the tile does not look flat.
context.saveGState()
context.addPath(tilePath)
context.clip()
if let gloss = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray,
    locations: [0, 1]
) {
    context.drawLinearGradient(
        gloss,
        start: CGPoint(x: inset, y: inset),
        end: CGPoint(x: inset, y: inset + 420),
        options: []
    )
}
context.restoreGState()

// MARK: - Hop arc (bastion)

context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.8))
context.setLineWidth(30)
context.setLineCap(.round)
context.setLineDash(phase: 0, lengths: [2, 34])
context.beginPath()
context.move(to: CGPoint(x: 372, y: 398))
context.addQuadCurve(to: CGPoint(x: 652, y: 398), control: CGPoint(x: 512, y: 252))
context.strokePath()
context.setLineDash(phase: 0, lengths: [])

context.setFillColor(white)
for point in [CGPoint(x: 372, y: 398), CGPoint(x: 652, y: 398)] {
    context.fillEllipse(in: CGRect(x: point.x - 26, y: point.y - 26, width: 52, height: 52))
}

// MARK: - Terminal prompt

context.setStrokeColor(white)
context.setLineWidth(58)
context.setLineCap(.round)
context.setLineJoin(.round)
context.beginPath()
context.move(to: CGPoint(x: 352, y: 486))
context.addLine(to: CGPoint(x: 452, y: 568))
context.addLine(to: CGPoint(x: 352, y: 650))
context.strokePath()

context.setFillColor(white)
let cursor = CGRect(x: 512, y: 604, width: 178, height: 56)
context.addPath(CGPath(roundedRect: cursor, cornerWidth: 28, cornerHeight: 28, transform: nil))
context.fillPath()

// MARK: - Write

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("could not render the icon\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    FileHandle.standardError.write(Data("could not open \(outputPath)\n".utf8))
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write the PNG\n".utf8))
    exit(1)
}

print("wrote \(outputPath)")
