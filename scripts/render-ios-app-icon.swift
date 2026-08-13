import AppKit
import CoreGraphics
import Foundation

private let canvasSize = 1_024
private let circleDiameter: CGFloat = 430

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: xcrun swift scripts/render-ios-app-icon.swift <output.png>\n".utf8))
    exit(64)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: canvasSize * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write(Data("Could not create the app-icon drawing context.\n".utf8))
    exit(1)
}

context.setShouldAntialias(true)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

let origin = (CGFloat(canvasSize) - circleDiameter) / 2
context.setFillColor(CGColor(gray: 31 / 255, alpha: 1))
context.fillEllipse(in: CGRect(x: origin, y: origin, width: circleDiameter, height: circleDiameter))

guard let image = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("Could not encode the app-icon PNG.\n".utf8))
    exit(1)
}

try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
