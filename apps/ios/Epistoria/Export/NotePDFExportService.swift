import EpistoriaCore
import ImageIO
import PencilKit
import UIKit

struct NotePDFExportResult: Identifiable {
    let id = UUID()
    let fileURL: URL
    let title: String
    let pageCount: Int
    let byteCount: Int64
}

enum NotePDFExportError: LocalizedError {
    case notebookUnavailable
    case invalidPageGeometry
    case imageUnavailable(String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .notebookUnavailable:
            "The unlocked notebook is not available for PDF export."
        case .invalidPageGeometry:
            "This note does not have printable page geometry."
        case let .imageUnavailable(filename):
            "Epistoria could not read \(filename) for the PDF. The encrypted original was not changed."
        case .writeFailed:
            "Epistoria could not create the readable PDF."
        }
    }
}

/// Renders one unlocked note as a readable PDF without changing its source records or assets.
/// Fixed paper maps one notebook sheet to one PDF page. Infinite paper maps its used world bounds
/// to one bounded custom PDF page.
@MainActor
final class NotePDFExportService {
    private struct PagePlan {
        var pageIndex: Int
        var worldRect: CGRect
        var outputSize: CGSize
        var worldScale: CGFloat
    }

    private let store: EpistoriaStore
    private let assetManager: AssetManager
    private let outputDirectory: URL
    private let fileManager: FileManager

    init(
        store: EpistoriaStore,
        assetManager: AssetManager,
        outputDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.assetManager = assetManager
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
    }

    func export(noteId: UUID) async throws -> NotePDFExportResult {
        try Task.checkCancellation()
        try Self.removeAllTemporaryPDFs()
        async let loadedNote = store.payload(NotePayload.self, id: noteId)
        async let loadedBlocks = store.list(NoteBlockPayload.self, parentId: noteId)
        async let loadedEvidence = store.list(EvidencePayload.self)
        async let loadedSources = store.list(SourcePayload.self)
        async let loadedVersions = store.list(SourceVersionPayload.self)
        let (note, allBlocks, evidence, sources, versions) = try await (
            loadedNote, loadedBlocks, loadedEvidence, loadedSources, loadedVersions
        )
        try Task.checkCancellation()
        let blocks = allBlocks
            .filter { !$0.payload.tombstone }
            .sorted { $0.payload.orderKey < $1.payload.orderKey }
        let configuration = note.payload.canvas ?? NoteCanvasConfiguration()
        let plans = try pagePlans(configuration: configuration, blocks: blocks)
        let images = try await loadImages(for: blocks)
        let evidenceCards = evidenceCards(
            for: blocks,
            evidence: evidence,
            sources: sources,
            versions: versions
        )
        try Task.checkCancellation()

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let stem = safeFilename(note.payload.title)
        let suffix = String(noteId.uuidString.prefix(8)).lowercased()
        let finalURL = outputDirectory.appendingPathComponent(
            "Epistoria-Note-\(stem)-\(suffix).pdf"
        )
        let partialURL = outputDirectory.appendingPathComponent(
            "Epistoria-Note-\(UUID().uuidString).partial"
        )
        var completed = false
        defer {
            if !completed, fileManager.fileExists(atPath: partialURL.path) {
                try? fileManager.removeItem(at: partialURL)
            }
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: note.payload.title,
            kCGPDFContextCreator as String: "Epistoria",
            kCGPDFContextAuthor as String: "Epistoria notebook owner",
        ]
        guard let firstPlan = plans.first else { throw NotePDFExportError.invalidPageGeometry }
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: firstPlan.outputSize),
            format: format
        )
        do {
            try renderer.writePDF(to: partialURL) { rendererContext in
                for plan in plans {
                    rendererContext.beginPage(
                        withBounds: CGRect(origin: .zero, size: plan.outputSize),
                        pageInfo: [:]
                    )
                    draw(
                        plan: plan,
                        configuration: configuration,
                        blocks: blocks,
                        images: images,
                        evidenceCards: evidenceCards,
                        context: rendererContext.cgContext
                    )
                }
            }
            try Task.checkCancellation()
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: partialURL.path
            )
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: partialURL, to: finalURL)
            completed = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NotePDFExportError.writeFailed
        }

        // Do not turn a successful atomic publish into a failed export only because optional
        // filesystem metadata was unavailable. The shareable PDF already exists at this point.
        let byteCount = Int64(
            (try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        return NotePDFExportResult(
            fileURL: finalURL,
            title: note.payload.title,
            pageCount: plans.count,
            byteCount: byteCount
        )
    }

    nonisolated static func removeTemporaryPDF(_ url: URL) throws {
        let fileManager = FileManager.default
        guard url.isFileURL,
              url.deletingLastPathComponent().standardizedFileURL
                == fileManager.temporaryDirectory.standardizedFileURL,
              url.pathExtension.lowercased() == "pdf",
              url.lastPathComponent.hasPrefix("Epistoria-Note-")
        else { return }
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    nonisolated static func removeAllTemporaryPDFs() throws {
        let fileManager = FileManager.default
        for url in try fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) where url.lastPathComponent.hasPrefix("Epistoria-Note-")
            && ["pdf", "partial"].contains(url.pathExtension.lowercased())
        {
            try fileManager.removeItem(at: url)
        }
    }

    private func pagePlans(
        configuration: NoteCanvasConfiguration,
        blocks: [IdentifiedPayload<NoteBlockPayload>]
    ) throws -> [PagePlan] {
        if let width = configuration.pageWidth, let height = configuration.pageHeight {
            guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                throw NotePDFExportError.invalidPageGeometry
            }
            return (0 ..< configuration.effectivePageCount).map {
                PagePlan(
                    pageIndex: $0,
                    worldRect: CGRect(x: 0, y: 0, width: width, height: height),
                    outputSize: CGSize(width: width, height: height),
                    worldScale: 1
                )
            }
        }

        var bounds = CGRect.null
        for block in blocks {
            if block.payload.canvasRole == .inkLayer,
               let data = block.payload.drawingData,
               let drawing = try? PKDrawing(data: data),
               !drawing.bounds.isNull
            {
                bounds = bounds.union(drawing.bounds)
            } else if let placement = block.payload.canvasPlacement {
                bounds = bounds.union(placement.rect)
            }
        }
        if bounds.isNull || bounds.isEmpty {
            bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        } else {
            bounds = bounds.insetBy(dx: -36, dy: -36)
        }
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw NotePDFExportError.invalidPageGeometry
        }
        let maximumPDFDimension: CGFloat = 14_400
        let scale = min(1, maximumPDFDimension / max(bounds.width, bounds.height))
        return [
            PagePlan(
                pageIndex: 0,
                worldRect: bounds,
                outputSize: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                worldScale: scale
            ),
        ]
    }

    private func loadImages(
        for blocks: [IdentifiedPayload<NoteBlockPayload>]
    ) async throws -> [UUID: UIImage] {
        var result: [UUID: UIImage] = [:]
        for block in blocks where block.payload.blockType == .image {
            try Task.checkCancellation()
            guard let assetId = block.payload.assetId else { continue }
            let data = try await assetManager.decryptedData(assetId: assetId)
            let maximumDimension = max(
                512,
                min(max(block.payload.canvasPlacement?.width ?? 1_200,
                        block.payload.canvasPlacement?.height ?? 1_200) * 2, 4_096)
            )
            guard let image = downsampledImage(data, maximumDimension: maximumDimension) else {
                throw NotePDFExportError.imageUnavailable(block.payload.plainText)
            }
            result[block.id] = image
        }
        return result
    }

    private func draw(
        plan: PagePlan,
        configuration: NoteCanvasConfiguration,
        blocks: [IdentifiedPayload<NoteBlockPayload>],
        images: [UUID: UIImage],
        evidenceCards: [UUID: NSAttributedString],
        context: CGContext
    ) {
        let outputBounds = CGRect(origin: .zero, size: plan.outputSize)
        context.setFillColor(configuration.paperColor.uiColor.cgColor)
        context.fill(outputBounds)
        drawPaper(configuration, in: outputBounds, scale: plan.worldScale, context: context)

        context.saveGState()
        context.clip(to: outputBounds)
        context.scaleBy(x: plan.worldScale, y: plan.worldScale)
        context.translateBy(x: -plan.worldRect.minX, y: -plan.worldRect.minY)

        let pageBlocks = blocks.filter {
            $0.payload.canvasRole != .inkLayer && pageIndex(for: $0.payload, configuration: configuration) == plan.pageIndex
        }
        let arranged = pageBlocks.enumerated().sorted { lhs, rhs in
            let left = lhs.element.payload.canvasPlacement?.zIndex ?? lhs.offset
            let right = rhs.element.payload.canvasPlacement?.zIndex ?? rhs.offset
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        for (legacyIndex, block) in arranged {
            let placement = block.payload.canvasPlacement
                ?? legacyPlacement(for: block.payload, index: legacyIndex, pageWidth: plan.worldRect.width)
            draw(
                block: block,
                placement: placement,
                image: images[block.id],
                evidenceCard: evidenceCards[block.id],
                context: context
            )
        }

        for block in blocks where block.payload.canvasRole == .inkLayer
            && pageIndex(for: block.payload, configuration: configuration) == plan.pageIndex
        {
            guard let data = block.payload.drawingData,
                  let drawing = try? PKDrawing(data: data),
                  !drawing.bounds.isNull
            else { continue }
            let rasterScale = max(0.25, min(2, 4_096 / max(plan.worldRect.width, plan.worldRect.height)))
            drawing.image(from: plan.worldRect, scale: rasterScale).draw(in: plan.worldRect)
        }
        context.restoreGState()
    }

    private func draw(
        block: IdentifiedPayload<NoteBlockPayload>,
        placement: NoteCanvasPlacement,
        image: UIImage?,
        evidenceCard: NSAttributedString?,
        context: CGContext
    ) {
        let rect = placement.rect
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: placement.rotationRadians)
        let localRect = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)

        switch block.payload.blockType {
        case .text, .equation:
            decodeRichText(block.payload).draw(
                with: localRect.insetBy(dx: 8, dy: 8),
                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                context: nil
            )
        case .image:
            image?.draw(in: aspectFitRect(imageSize: image?.size ?? .zero, destination: localRect))
        case .handwriting:
            if let data = block.payload.drawingData,
               let drawing = try? PKDrawing(data: data),
               !drawing.bounds.isNull
            {
                drawing.image(from: drawing.bounds, scale: 2).draw(in: localRect)
            }
        case .shape:
            if let shape = block.payload.canvasShape {
                let path = NotebookShapePath.make(
                    kind: shape.kind,
                    in: localRect,
                    lineWidth: CGFloat(shape.lineWidth)
                )
                context.addPath(path)
                context.setStrokeColor(shape.strokeColor.uiColor.cgColor)
                context.setLineWidth(CGFloat(shape.lineWidth))
                context.setLineCap(.round)
                context.setLineJoin(.round)
                if let fill = shape.fillColor {
                    context.setFillColor(fill.uiColor.withAlphaComponent(0.18).cgColor)
                    context.drawPath(using: .fillStroke)
                } else {
                    context.strokePath()
                }
            }
        case .callout where block.payload.evidenceId != nil:
            context.setFillColor(UIColor.systemBackground.cgColor)
            context.fill(localRect)
            context.setStrokeColor(UIColor.label.withAlphaComponent(0.2).cgColor)
            context.setLineWidth(0.5)
            context.stroke(localRect)
            (evidenceCard ?? NSAttributedString(string: block.payload.plainText)).draw(
                with: localRect.insetBy(dx: 10, dy: 10),
                options: .usesLineFragmentOrigin,
                context: nil
            )
        default:
            let fallback = block.payload.plainText.isEmpty
                ? "Preserved \(block.payload.blockType.rawValue.lowercased()) item"
                : block.payload.plainText
            NSAttributedString(
                string: fallback,
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.label,
                ]
            ).draw(with: localRect.insetBy(dx: 8, dy: 8), options: .usesLineFragmentOrigin, context: nil)
        }
        context.restoreGState()
    }

    private func evidenceCards(
        for blocks: [IdentifiedPayload<NoteBlockPayload>],
        evidence: [IdentifiedPayload<EvidencePayload>],
        sources: [IdentifiedPayload<SourcePayload>],
        versions: [IdentifiedPayload<SourceVersionPayload>]
    ) -> [UUID: NSAttributedString] {
        let evidenceById = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0.payload) })
        let sourceById = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.payload) })
        let versionById = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, $0.payload) })
        var result: [UUID: NSAttributedString] = [:]
        for block in blocks {
            guard let evidenceId = block.payload.evidenceId,
                  let item = evidenceById[evidenceId]
            else { continue }
            let source = sourceById[item.sourceId]?.title ?? "Source"
            let version = versionById[item.sourceVersionId]?.versionNumber
            let location: String
            switch item.locator.kind {
            case .pdf: location = item.locator.page.map { "Page \($0)" } ?? "PDF"
            case .slide: location = item.locator.slide.map { "Slide \($0)" } ?? "Slide"
            case .media:
                let start = evidenceMediaTimeLabel(item.locator.startSeconds ?? 0)
                if let end = item.locator.endSeconds, end > (item.locator.startSeconds ?? 0) {
                    location = "\(start)–\(evidenceMediaTimeLabel(end))"
                } else {
                    location = start
                }
            default: location = "Saved excerpt"
            }
            let citation = "\(source) · \(location) · \(version.map { "Version \($0)" } ?? "Saved version")"
            let text = NSMutableAttributedString(
                string: item.excerpt.isEmpty ? (item.note ?? "Evidence") : item.excerpt,
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.label,
                ]
            )
            text.append(NSAttributedString(
                string: "\n\n\(citation)",
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            ))
            result[block.id] = text
        }
        return result
    }

    private func evidenceMediaTimeLabel(_ value: Double) -> String {
        let seconds = max(Int(value.isFinite ? value.rounded(.down) : 0), 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    private func drawPaper(
        _ configuration: NoteCanvasConfiguration,
        in rect: CGRect,
        scale: CGFloat,
        context: CGContext
    ) {
        guard configuration.paperStyle != .plain else { return }
        context.saveGState()
        context.setStrokeColor(configuration.paperColor.lineColor.cgColor)
        context.setFillColor(configuration.paperColor.lineColor.cgColor)
        context.setLineWidth(0.5)
        let spacing = CGFloat(configuration.paperSpacing) * scale
        switch configuration.paperStyle {
        case .plain:
            break
        case .ruled:
            for y in stride(from: spacing / 2, through: rect.maxY, by: spacing) {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.strokePath()
        case .grid:
            for x in stride(from: rect.minX, through: rect.maxX, by: spacing) {
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for y in stride(from: rect.minY, through: rect.maxY, by: spacing) {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.strokePath()
        case .dotted:
            for x in stride(from: spacing / 2, through: rect.maxX, by: spacing) {
                for y in stride(from: spacing / 2, through: rect.maxY, by: spacing) {
                    context.fillEllipse(in: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4))
                }
            }
        case .isometric:
            for y in stride(from: rect.minY, through: rect.maxY, by: spacing) {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            let diagonalSpan = rect.width + rect.height * 0.58
            for offset in stride(from: -rect.height * 0.58, through: diagonalSpan, by: spacing) {
                context.move(to: CGPoint(x: offset + rect.minY * 0.58, y: rect.minY))
                context.addLine(to: CGPoint(x: offset + rect.maxY * 0.58, y: rect.maxY))
                context.move(to: CGPoint(x: offset - rect.minY * 0.58, y: rect.minY))
                context.addLine(to: CGPoint(x: offset - rect.maxY * 0.58, y: rect.maxY))
            }
            context.strokePath()
        }
        context.restoreGState()
    }

    private func pageIndex(
        for payload: NoteBlockPayload,
        configuration: NoteCanvasConfiguration
    ) -> Int {
        configuration.pageFormat == .infinite ? 0 : max(payload.canvasPageIndex ?? 0, 0)
    }

    private func legacyPlacement(
        for payload: NoteBlockPayload,
        index: Int,
        pageWidth: CGFloat
    ) -> NoteCanvasPlacement {
        let width = min(max(Double(pageWidth) - 96, 260), 640)
        let height: Double
        switch payload.blockType {
        case .text: height = 180
        case .handwriting: height = 320
        case .image: height = 260
        case .equation: height = 100
        case .shape: height = 160
        default: height = 140
        }
        return NoteCanvasPlacement(
            x: 48,
            y: 72 + Double(index) * (height + 24),
            width: width,
            height: height,
            zIndex: index
        )
    }

    private func decodeRichText(_ payload: NoteBlockPayload) -> NSAttributedString {
        if let rtf = payload.richTextRtf,
           let value = try? NSAttributedString(
               data: rtf,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           )
        {
            return value
        }
        let font = payload.blockType == .equation
            ? UIFont.systemFont(ofSize: 34, weight: .regular)
            : UIFont.preferredFont(forTextStyle: .body)
        return NSAttributedString(
            string: payload.plainText,
            attributes: [.font: font, .foregroundColor: UIColor.label]
        )
    }

    private func downsampledImage(_ data: Data, maximumDimension: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maximumDimension), 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func aspectFitRect(imageSize: CGSize, destination: CGRect) -> CGRect {
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

    private func safeFilename(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = title.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .prefix(8)
            .joined(separator: "-")
        return collapsed.isEmpty ? "Untitled" : String(collapsed.prefix(80))
    }
}

private extension NoteCanvasPlacement {
    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
