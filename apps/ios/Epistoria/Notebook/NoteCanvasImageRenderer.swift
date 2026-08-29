import EpistoriaCore
import UIKit

enum NoteCanvasImageRenderer {
    static func transformedImage(
        _ image: UIImage,
        configuration: NoteCanvasImageConfiguration?,
        maximumDimension: CGFloat = 2_048
    ) -> UIImage {
        let configuration = (configuration ?? NoteCanvasImageConfiguration()).sanitized
        let rotated = rotatedImage(image, quarterTurns: configuration.rotationQuarterTurns)
        let crop = configuration.crop.sanitized
        let pixelWidth = CGFloat(rotated.cgImage?.width ?? max(Int(rotated.size.width), 1))
        let pixelHeight = CGFloat(rotated.cgImage?.height ?? max(Int(rotated.size.height), 1))
        let pixelCrop = CGRect(
            x: CGFloat(crop.x) * pixelWidth,
            y: CGFloat(crop.y) * pixelHeight,
            width: CGFloat(crop.width) * pixelWidth,
            height: CGFloat(crop.height) * pixelHeight
        ).integral.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        let cropped: UIImage
        if let source = rotated.cgImage,
           pixelCrop.width >= 1,
           pixelCrop.height >= 1,
           let result = source.cropping(to: pixelCrop)
        {
            cropped = UIImage(cgImage: result, scale: 1, orientation: .up)
        } else {
            cropped = rotated
        }

        let sourceSize = cropped.size
        let scale = min(1, maximumDimension / max(max(sourceSize.width, sourceSize.height), 1))
        let outputSize = CGSize(
            width: max(sourceSize.width * scale, 1),
            height: max(sourceSize.height * scale, 1)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            let bounds = CGRect(origin: .zero, size: outputSize)
            maskPath(for: configuration, in: bounds).addClip()
            cropped.draw(in: bounds)
        }
    }

    static func draw(
        _ image: UIImage,
        configuration: NoteCanvasImageConfiguration?,
        in destination: CGRect,
        maximumDimension: CGFloat = 4_096
    ) {
        let transformed = transformedImage(
            image,
            configuration: configuration,
            maximumDimension: maximumDimension
        )
        transformed.draw(in: aspectFitRect(imageSize: transformed.size, destination: destination))
    }

    static func aspectFitRect(imageSize: CGSize, destination: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return destination }
        let scale = min(destination.width / imageSize.width, destination.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: destination.midX - size.width / 2,
            y: destination.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func rotatedImage(_ image: UIImage, quarterTurns: Int) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        }
        let outputSize = turns.isMultiple(of: 2)
            ? image.size
            : CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            context.rotate(by: CGFloat(turns) * .pi / 2)
            image.draw(in: CGRect(
                x: -image.size.width / 2,
                y: -image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            ))
        }
    }

    private static func maskPath(
        for configuration: NoteCanvasImageConfiguration,
        in bounds: CGRect
    ) -> UIBezierPath {
        switch configuration.mask {
        case .none:
            UIBezierPath(rect: bounds)
        case .roundedRectangle:
            UIBezierPath(
                roundedRect: bounds,
                cornerRadius: min(bounds.width, bounds.height)
                    * CGFloat(configuration.roundedCornerFraction)
            )
        case .ellipse:
            UIBezierPath(ovalIn: bounds)
        }
    }
}
