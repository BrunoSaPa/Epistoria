@preconcurrency import PencilKit
@preconcurrency import UIKit
@preconcurrency import Vision
import EpistoriaCore
import Foundation

enum LocalTextOCRError: Error, LocalizedError {
    case emptyDrawing
    case imageTooLarge
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .emptyDrawing: "There is no changed handwriting to recognize."
        case .imageTooLarge: "The handwriting region is too large for local recognition."
        case .renderingFailed: "Epistoria could not render the handwriting region for recognition."
        }
    }
}

struct LocalOCRCapture: Sendable {
    let request: LocalOCRRequest
    let response: LocalOCRResponse
    let suggestsFormula: Bool
}

enum LocalTextOCRService {
    private static let maximumPNGBytes = 825_000
    private static let maximumDimension: CGFloat = 1_600

    static func recognizeChangedInk(
        accountId: UUID,
        noteId: UUID,
        blockId: UUID,
        inputRevision: Int,
        pageIndex: Int,
        pageSize: CGSize,
        drawingData: Data,
        previousDrawingData: Data?,
        preferredLanguages: [String]
    ) async throws -> [LocalOCRCapture] {
        try await Task.detached(priority: .utility) {
            let drawing = try PKDrawing(data: drawingData)
            guard !drawing.strokes.isEmpty else { throw LocalTextOCRError.emptyDrawing }
            let previous = try previousDrawingData.map(PKDrawing.init(data:))
            let changedStrokes: ArraySlice<PKStroke>
            if let previous, drawing.strokes.count >= previous.strokes.count {
                changedStrokes = drawing.strokes.dropFirst(previous.strokes.count)
            } else {
                changedStrokes = drawing.strokes[...]
            }
            let bounds = clusteredBounds(
                strokes: changedStrokes.isEmpty ? drawing.strokes[...] : changedStrokes,
                pageSize: pageSize
            )
            guard !bounds.isEmpty else { throw LocalTextOCRError.emptyDrawing }

            return try bounds.map { region in
                let png = try renderPNG(drawing: drawing, region: region)
                let response = try recognize(
                    png: png,
                    region: region,
                    pageSize: pageSize,
                    preferredLanguages: preferredLanguages
                )
                let locator = SourceLocator(
                    kind: .image,
                    rectangles: [normalized(region, in: pageSize)]
                )
                let request = LocalOCRRequest(
                    accountId: accountId,
                    targetKind: .notebookRegion,
                    targetId: blockId,
                    parentId: noteId,
                    noteId: noteId,
                    inputRevision: inputRevision,
                    pageNumber: pageIndex + 1,
                    locator: locator,
                    imageData: png,
                    preferredLanguages: preferredLanguages,
                    mode: .text
                )
                return LocalOCRCapture(
                    request: request,
                    response: response,
                    suggestsFormula: suggestsFormulaLayout(drawing: drawing, region: region)
                )
            }
        }.value
    }

    static func recognizeImage(
        accountId: UUID,
        sourceId: UUID,
        sourceVersionId: UUID,
        inputRevision: Int,
        imageData: Data,
        preferredLanguages: [String]
    ) async throws -> LocalOCRCapture {
        try await Task.detached(priority: .utility) {
            guard let image = UIImage(data: imageData), image.size.width > 0, image.size.height > 0
            else { throw LocalTextOCRError.renderingFailed }
            let png = try boundedPNG(image)
            let response = try recognize(
                png: png,
                region: CGRect(origin: .zero, size: image.size),
                pageSize: image.size,
                preferredLanguages: preferredLanguages
            )
            let request = LocalOCRRequest(
                accountId: accountId,
                targetKind: .image,
                targetId: sourceVersionId,
                parentId: sourceId,
                sourceVersionId: sourceVersionId,
                inputRevision: inputRevision,
                locator: SourceLocator(
                    kind: .image,
                    rectangles: [AnnotationRectangle(x: 0, y: 0, width: 1, height: 1)]
                ),
                imageData: png,
                preferredLanguages: preferredLanguages,
                mode: .text
            )
            return LocalOCRCapture(request: request, response: response, suggestsFormula: false)
        }.value
    }

    static func recognizeSourcePage(
        accountId: UUID,
        sourceId: UUID,
        sourceVersionId: UUID,
        inputRevision: Int,
        pageNumber: Int,
        imageData: Data,
        preferredLanguages: [String]
    ) async throws -> LocalOCRCapture {
        try await Task.detached(priority: .utility) {
            guard let image = UIImage(data: imageData), image.size.width > 0, image.size.height > 0
            else { throw LocalTextOCRError.renderingFailed }
            let png = try boundedPNG(image)
            let response = try recognize(
                png: png,
                region: CGRect(origin: .zero, size: image.size),
                pageSize: image.size,
                preferredLanguages: preferredLanguages
            )
            let locator = SourceLocator(
                kind: .pdf,
                page: pageNumber,
                rectangles: [AnnotationRectangle(x: 0, y: 0, width: 1, height: 1)]
            )
            let request = LocalOCRRequest(
                accountId: accountId,
                targetKind: .sourcePage,
                targetId: sourceVersionId,
                parentId: sourceId,
                sourceVersionId: sourceVersionId,
                inputRevision: inputRevision,
                pageNumber: pageNumber,
                locator: locator,
                imageData: png,
                preferredLanguages: preferredLanguages,
                mode: .text
            )
            return LocalOCRCapture(request: request, response: response, suggestsFormula: false)
        }.value
    }

    private static func clusteredBounds(
        strokes: ArraySlice<PKStroke>,
        pageSize: CGSize
    ) -> [CGRect] {
        let page = CGRect(origin: .zero, size: pageSize)
        var clusters: [CGRect] = []
        for stroke in strokes {
            var candidate = stroke.renderBounds.insetBy(dx: -22, dy: -22).intersection(page)
            guard !candidate.isNull, candidate.width > 1, candidate.height > 1 else { continue }
            var index = 0
            while index < clusters.count {
                let proximity = clusters[index].insetBy(dx: -44, dy: -44)
                if proximity.intersects(candidate) {
                    candidate = clusters.remove(at: index).union(candidate).intersection(page)
                    index = 0
                } else {
                    index += 1
                }
            }
            clusters.append(candidate)
        }
        return clusters.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
            .prefix(12).map(\.self)
    }

    private static func renderPNG(drawing: PKDrawing, region: CGRect) throws -> Data {
        var scale = min(3, maximumDimension / max(region.width, region.height))
        scale = max(scale, 0.35)
        while scale >= 0.35 {
            let ink = drawing.image(from: region, scale: scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: ink.size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: ink.size))
                ink.draw(at: .zero)
            }
            guard let png = rendered.pngData() else { throw LocalTextOCRError.renderingFailed }
            if png.count <= maximumPNGBytes { return png }
            scale *= 0.72
        }
        throw LocalTextOCRError.imageTooLarge
    }

    private static func suggestsFormulaLayout(drawing: PKDrawing, region: CGRect) -> Bool {
        let strokes = drawing.strokes.filter { $0.renderBounds.intersects(region) }
        guard strokes.count >= 3 else { return false }
        let bounds = strokes.map(\.renderBounds)

        // A fraction bar has overlapping marks on both sides of a thin horizontal stroke.
        for bar in bounds where bar.width >= max(bar.height * 4, 18) {
            let overlap = bar.insetBy(dx: -bar.width * 0.15, dy: 0)
            let hasNumerator = bounds.contains {
                $0 != bar && $0.maxY < bar.midY && $0.maxX >= overlap.minX
                    && $0.minX <= overlap.maxX
            }
            let hasDenominator = bounds.contains {
                $0 != bar && $0.minY > bar.midY && $0.maxX >= overlap.minX
                    && $0.minX <= overlap.maxX
            }
            if hasNumerator && hasDenominator { return true }
        }

        // A small raised group following normal-height ink is a likely exponent.
        let sorted = bounds.sorted { $0.minX < $1.minX }
        for index in sorted.indices.dropFirst() {
            let previous = sorted[index - 1]
            let raised = sorted[index]
            if raised.height < previous.height * 0.72,
                raised.midY < previous.midY - previous.height * 0.18,
                raised.minX <= previous.maxX + previous.height
            {
                return true
            }
        }
        return false
    }

    private static func boundedPNG(_ image: UIImage) throws -> Data {
        var scale = min(1, maximumDimension / max(image.size.width, image.size.height))
        while scale >= 0.2 {
            let target = CGSize(
                width: max(image.size.width * scale, 1),
                height: max(image.size.height * scale, 1)
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: target, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: target))
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            guard let png = rendered.pngData() else { throw LocalTextOCRError.renderingFailed }
            if png.count <= maximumPNGBytes { return png }
            scale *= 0.72
        }
        throw LocalTextOCRError.imageTooLarge
    }

    private static func recognize(
        png: Data,
        region: CGRect,
        pageSize: CGSize,
        preferredLanguages: [String]
    ) throws -> LocalOCRResponse {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = preferredLanguages.isEmpty
        if !preferredLanguages.isEmpty { request.recognitionLanguages = preferredLanguages }
        let handler = VNImageRequestHandler(data: png, orientation: .up)
        try handler.perform([request])
        let recognized = (request.results ?? []).compactMap { observation -> LocalOCRRegion? in
            let candidates = observation.topCandidates(3)
            guard let primary = candidates.first else { return nil }
            let vision = observation.boundingBox
            let cropRectangle = CGRect(
                x: vision.minX,
                y: 1 - vision.maxY,
                width: vision.width,
                height: vision.height
            )
            let pageRectangle = CGRect(
                x: region.minX + cropRectangle.minX * region.width,
                y: region.minY + cropRectangle.minY * region.height,
                width: cropRectangle.width * region.width,
                height: cropRectangle.height * region.height
            )
            return LocalOCRRegion(
                kind: .text,
                text: primary.string,
                confidence: Double(primary.confidence),
                alternatives: candidates.dropFirst().map(\.string),
                rectangles: [normalized(pageRectangle, in: pageSize)]
            )
        }
        return LocalOCRResponse(
            engine: .appleVision,
            engineVersion: "Vision/iPadOS-\(ProcessInfo.processInfo.operatingSystemVersionString)",
            recognitionVersion: request.revision,
            regions: recognized,
            warnings: recognized.isEmpty ? ["No readable handwriting was detected."] : []
        )
    }

    private static func normalized(_ rectangle: CGRect, in pageSize: CGSize) -> AnnotationRectangle {
        AnnotationRectangle(
            x: min(max(rectangle.minX / max(pageSize.width, 1), 0), 1),
            y: min(max(rectangle.minY / max(pageSize.height, 1), 0), 1),
            width: min(max(rectangle.width / max(pageSize.width, 1), 0.000_001), 1),
            height: min(max(rectangle.height / max(pageSize.height, 1), 0.000_001), 1)
        )
    }
}
