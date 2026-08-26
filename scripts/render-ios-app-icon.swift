import AppKit
import CoreGraphics
import Foundation

private let canvasSize = 1_024

guard (2 ... 3).contains(CommandLine.arguments.count) else {
    FileHandle.standardError.write(Data(
        "Usage: xcrun swift scripts/render-ios-app-icon.swift <output.png> [runtime.svg]\n".utf8
    ))
    exit(64)
}

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let sourceURL = repositoryRoot.appendingPathComponent("apps/ios/AppIconSource.svg")
let sourceData = try Data(contentsOf: sourceURL)
guard let sourceImage = NSImage(data: sourceData) else {
    FileHandle.standardError.write(Data("Could not open the canonical SVG.\n".utf8))
    exit(1)
}
var proposedRect = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
guard let sourceCGImage = sourceImage.cgImage(
    forProposedRect: &proposedRect,
    context: nil,
    hints: [.interpolation: NSImageInterpolation.high]
), let context = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: canvasSize * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write(Data("Could not render the canonical SVG.\n".utf8))
    exit(1)
}

context.setShouldAntialias(true)
context.interpolationQuality = .high
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
context.draw(sourceCGImage, in: CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

guard let rendered = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: rendered).representation(
        using: NSBitmapImageRep.FileType.png,
        properties: [:]
      ) else {
    FileHandle.standardError.write(Data("Could not encode the app-icon PNG.\n".utf8))
    exit(1)
}

try png.write(
    to: URL(fileURLWithPath: CommandLine.arguments[1]),
    options: Data.WritingOptions.atomic
)

if CommandLine.arguments.count == 3 {
    try sourceData.write(
        to: URL(fileURLWithPath: CommandLine.arguments[2]),
        options: Data.WritingOptions.atomic
    )
}
