#!/usr/bin/env swift
// Renders the OrcaPad app icon (1024×1024 PNG): a nozzle laying filament on a
// small stack, matching the launch animation.
//
//   scripts/make_ios_app_icon.swift ios-app/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "AppIcon.png")

guard let context = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("cannot create bitmap context")
}

func color(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

let background = color(0.129, 0.145, 0.161)  // deep slate, close to the app window
let accent = color(0.0, 0.588, 0.533)        // Orca #009688
let accentLight = color(0.133, 0.749, 0.690)
let metal = color(0.62, 0.65, 0.68)

// Background.
context.setFillColor(background)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Printed stack: layers narrowing towards the top (y grows upward in CG).
let layerHeight = 66.0
let gap = 18.0
let baseY = 250.0
let baseWidth = 620.0
let taper = 52.0
let layers = 4

for index in 0..<layers {
    let width = baseWidth - Double(index) * taper * 2
    let rect = CGRect(x: (size - width) / 2,
                      y: baseY + Double(index) * (layerHeight + gap),
                      width: width, height: layerHeight)
    context.setFillColor(index == layers - 1 ? accentLight : accent)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: layerHeight / 2,
                           cornerHeight: layerHeight / 2, transform: nil))
    context.fillPath()
}

// Bed line under the stack.
context.setFillColor(color(0.35, 0.38, 0.41))
context.addPath(CGPath(roundedRect: CGRect(x: 170, y: baseY - 46, width: size - 340, height: 30),
                       cornerWidth: 15, cornerHeight: 15, transform: nil))
context.fillPath()

// Nozzle above the stack: body + tapered tip.
let topOfStack = baseY + Double(layers) * (layerHeight + gap)
let nozzleCenterX = size / 2
let tipY = topOfStack + 24

let tip = CGMutablePath()
tip.move(to: CGPoint(x: nozzleCenterX - 34, y: tipY))
tip.addLine(to: CGPoint(x: nozzleCenterX + 34, y: tipY))
tip.addLine(to: CGPoint(x: nozzleCenterX + 74, y: tipY + 96))
tip.addLine(to: CGPoint(x: nozzleCenterX - 74, y: tipY + 96))
tip.closeSubpath()
context.setFillColor(metal)
context.addPath(tip)
context.fillPath()

context.addPath(CGPath(roundedRect: CGRect(x: nozzleCenterX - 74, y: tipY + 96, width: 148, height: 150),
                       cornerWidth: 22, cornerHeight: 22, transform: nil))
context.fillPath()

// Filament feeding into the nozzle.
context.setFillColor(accentLight)
context.addPath(CGPath(roundedRect: CGRect(x: nozzleCenterX - 17, y: tipY + 230, width: 34, height: 150),
                       cornerWidth: 17, cornerHeight: 17, transform: nil))
context.fillPath()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("cannot encode PNG")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(output.path)") }
print("wrote \(output.path)")
