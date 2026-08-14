import EpistoriaCore
import os
import PencilKit
import SwiftUI
import UIKit

enum SpatialNotebookMode: Equatable {
    case select
    case ink
    case lasso
}

struct SpatialNotebookItem: Identifiable {
    enum Content {
        case text(NSAttributedString)
        case image(UIImage, filename: String)
        case legacyDrawing(PKDrawing)
        case unsupported(String)
    }

    let id: UUID
    var placement: NoteCanvasPlacement
    var content: Content
}

struct SpatialNotebookFocus: Equatable {
    var blockId: UUID
    var highlightedText: String?
}

struct SpatialNotebookCanvas: UIViewRepresentable {
    let configuration: NoteCanvasConfiguration
    let items: [SpatialNotebookItem]
    let inkData: Data
    let inkBlockId: UUID?
    let mode: SpatialNotebookMode
    let selectedItemId: UUID?
    let lassoSelectedIds: Set<UUID>
    let focus: SpatialNotebookFocus?
    let editingItemId: UUID?
    let onSelect: (UUID?) -> Void
    let onViewportChanged: (CGPoint) -> Void
    let onPlacementChanged: (UUID, NoteCanvasPlacement) -> Void
    let onTextChanged: (UUID, NSAttributedString, NoteCanvasPlacement) -> Void
    let onTextEditingEnded: (UUID) -> Void
    let onInkChanged: (Data) -> Void
    let onLassoSelection: (LassoSelection) -> Void
    let isReadOnly: Bool

    func makeUIView(context: Context) -> SpatialNotebookHostView {
        let view = SpatialNotebookHostView()
        update(view)
        return view
    }

    func updateUIView(_ uiView: SpatialNotebookHostView, context: Context) {
        update(uiView)
    }

    private func update(_ view: SpatialNotebookHostView) {
        view.onSelect = onSelect
        view.onViewportChanged = onViewportChanged
        view.onPlacementChanged = onPlacementChanged
        view.onTextChanged = onTextChanged
        view.onTextEditingEnded = onTextEditingEnded
        view.onInkChanged = onInkChanged
        view.onLassoSelection = onLassoSelection
        view.apply(
            configuration: configuration,
            items: items,
            inkData: inkData,
            inkBlockId: inkBlockId,
            mode: mode,
            selectedItemId: selectedItemId,
            lassoSelectedIds: lassoSelectedIds,
            focus: focus,
            editingItemId: editingItemId,
            isReadOnly: isReadOnly
        )
    }
}

@MainActor
final class SpatialNotebookHostView: UIView, UIScrollViewDelegate, PKCanvasViewDelegate {
    var onSelect: ((UUID?) -> Void)?
    var onViewportChanged: ((CGPoint) -> Void)?
    var onPlacementChanged: ((UUID, NoteCanvasPlacement) -> Void)?
    var onTextChanged: ((UUID, NSAttributedString, NoteCanvasPlacement) -> Void)?
    var onTextEditingEnded: ((UUID) -> Void)?
    var onInkChanged: ((Data) -> Void)?
    var onLassoSelection: ((LassoSelection) -> Void)?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let paperView = NotebookPaperView()
    private let pencilCanvas = PKCanvasView()
    private let lassoView = LassoGestureView()
    private var toolPicker: PKToolPicker?
    private var itemViews: [UUID: CanvasItemView] = [:]
    private var itemsByID: [UUID: SpatialNotebookItem] = [:]
    private var configuration = NoteCanvasConfiguration()
    private var mode = SpatialNotebookMode.select
    private var selectedItemId: UUID?
    private var lassoSelectedIds: Set<UUID> = []
    private var inkBlockId: UUID?
    private var worldDrawing = PKDrawing()
    private var lastExternalInkData: Data?
    /// Maps world/document coordinates into the current finite UIKit window. The window is
    /// silently recentered after an infinite-canvas gesture settles, so world coordinates can
    /// continue in every direction without a giant backing surface.
    private var documentOrigin = CGPoint.zero
    private var infiniteWindowCenter = CGPoint.zero
    private var pencilFrame = CGRect.zero
    private var geometryNeedsInitialPosition = true
    private var isApplyingDrawing = false
    private var lastFocus: SpatialNotebookFocus?
    private var pendingFocus: SpatialNotebookFocus?
    private var lastEditingItemId: UUID?
    private var isReadOnly = false

    private static let infiniteExtent: CGFloat = 16_384
    private static let fixedPasteboardMargin: CGFloat = 320
    private static let minimumCanvasZoomScale: CGFloat = 0.25
    private static let maximumCanvasZoomScale: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .secondarySystemBackground
        accessibilityLabel = "Notebook canvas"

        scrollView.delegate = self
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = true
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .normal
        scrollView.delaysContentTouches = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        addSubview(scrollView)
        scrollView.addSubview(contentView)

        paperView.isUserInteractionEnabled = false
        contentView.addSubview(paperView)

        pencilCanvas.delegate = self
        pencilCanvas.backgroundColor = .clear
        pencilCanvas.isOpaque = false
        pencilCanvas.drawingPolicy = .pencilOnly
        pencilCanvas.isScrollEnabled = false
        pencilCanvas.bounces = false
        pencilCanvas.alwaysBounceVertical = false
        pencilCanvas.alwaysBounceHorizontal = false
        pencilCanvas.accessibilityLabel = "Apple Pencil drawing layer"
        contentView.addSubview(pencilCanvas)

        lassoView.isHidden = true
        lassoView.onSelectionRect = { [weak self] rect in
            self?.finishLasso(in: rect)
        }
        addSubview(lassoView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        lassoView.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        if geometryNeedsInitialPosition {
            // `setZoomScale` can synchronously trigger another layout pass. Mark the one-time
            // setup complete before changing zoom so UIKit cannot re-enter this branch.
            geometryNeedsInitialPosition = false
            configureGeometry(preserving: nil)
            positionInitialViewport()
            reportViewport()
        }
        applyPendingFocusIfPossible()
    }

    func apply(
        configuration: NoteCanvasConfiguration,
        items: [SpatialNotebookItem],
        inkData: Data,
        inkBlockId: UUID?,
        mode: SpatialNotebookMode,
        selectedItemId: UUID?,
        lassoSelectedIds: Set<UUID>,
        focus: SpatialNotebookFocus?,
        editingItemId: UUID?,
        isReadOnly: Bool
    ) {
        let geometryChanged = configuration != self.configuration
        let preservedCenter = geometryChanged && !geometryNeedsInitialPosition
            ? currentWorldCenter()
            : nil
        self.configuration = configuration
        self.mode = mode
        self.selectedItemId = selectedItemId
        self.lassoSelectedIds = lassoSelectedIds
        if inkBlockId != self.inkBlockId { lastExternalInkData = nil }
        self.inkBlockId = inkBlockId
        self.isReadOnly = isReadOnly
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        if geometryChanged, bounds.width > 0, bounds.height > 0 {
            configureGeometry(preserving: preservedCenter)
        } else if configuration.pageFormat != .infinite,
                  bounds.width > 0,
                  fixedGeometryNeedsExpansion()
        {
            configureGeometry(preserving: currentWorldCenter())
        }
        reconcileItems(items)
        applyInkData(inkData)
        applyInteractionMode()
        applySelection()

        if focus != lastFocus {
            lastFocus = focus
            pendingFocus = focus
        }
        applyPendingFocusIfPossible()
        if editingItemId != lastEditingItemId {
            lastEditingItemId = editingItemId
            if let editingItemId {
                select(editingItemId)
                itemViews[editingItemId]?.beginTextEditing()
            }
        }
    }

    private func configureGeometry(preserving worldCenter: CGPoint?) {
        let paperSize: CGSize
        if let width = configuration.pageWidth, let height = configuration.pageHeight {
            infiniteWindowCenter = .zero
            paperSize = CGSize(width: width, height: height)
            let worldBounds = fixedWorldBounds(pageSize: paperSize)
            let origin = CGPoint(
                x: Self.fixedPasteboardMargin - worldBounds.minX,
                y: Self.fixedPasteboardMargin - worldBounds.minY
            )
            let size = CGSize(
                width: worldBounds.width + Self.fixedPasteboardMargin * 2,
                height: worldBounds.height + Self.fixedPasteboardMargin * 2
            )
            contentView.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size
            documentOrigin = origin
            paperView.frame = CGRect(origin: documentOrigin, size: paperSize)
            pencilFrame = contentView.bounds
            pencilCanvas.frame = pencilFrame
            paperView.isInfinite = false
            paperView.worldOriginInView = .zero
            backgroundColor = .secondarySystemBackground
            contentView.backgroundColor = .secondarySystemBackground
        } else {
            let size = CGSize(width: Self.infiniteExtent, height: Self.infiniteExtent)
            contentView.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size
            documentOrigin = CGPoint(
                x: size.width / 2 - infiniteWindowCenter.x,
                y: size.height / 2 - infiniteWindowCenter.y
            )
            paperView.frame = CGRect(origin: .zero, size: size)
            pencilFrame = paperView.frame
            pencilCanvas.frame = pencilFrame
            paperView.isInfinite = true
            paperView.worldOriginInView = documentOrigin
            backgroundColor = .systemBackground
            contentView.backgroundColor = .systemBackground
        }
        paperView.paperStyle = configuration.paperStyle
        paperView.setNeedsDisplay()
        reconcileItems(Array(itemsByID.values))
        applyWorldDrawing()
        paperView.layer.zPosition = -20_000
        pencilCanvas.layer.zPosition = 20_000

        if let worldCenter {
            centerViewport(on: worldCenter, animated: false)
        }
    }

    private func positionInitialViewport() {
        guard hasUsableViewportGeometry else { return }
        configureZoomLimits()

        if let width = configuration.pageWidth, let height = configuration.pageHeight {
            let available = CGSize(
                width: max(bounds.width - 48, 1),
                height: max(bounds.height - 48, 1)
            )
            let fit = min(available.width / width, available.height / height)
            let targetScale = min(
                max(fit, Self.minimumCanvasZoomScale),
                min(Self.maximumCanvasZoomScale, 1.35)
            )
            guard targetScale.isFinite, targetScale > 0 else { return }
            scrollView.setZoomScale(targetScale, animated: false)
            centerViewport(on: CGPoint(x: width / 2, y: height / 2), animated: false)
        } else {
            scrollView.setZoomScale(1, animated: false)
            centerViewport(on: .zero, animated: false)
        }
    }

    private var hasUsableViewportGeometry: Bool {
        bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width > 0
            && bounds.height > 0
            && contentView.bounds.width.isFinite
            && contentView.bounds.height.isFinite
            && contentView.bounds.width > 0
            && contentView.bounds.height > 0
    }

    private func configureZoomLimits() {
        guard hasUsableViewportGeometry else { return }
        if !scrollView.zoomScale.isFinite || scrollView.zoomScale <= 0 {
            scrollView.setZoomScale(1, animated: false)
        }
        scrollView.maximumZoomScale = Self.maximumCanvasZoomScale
        scrollView.minimumZoomScale = Self.minimumCanvasZoomScale
    }

    private func reconcileItems(_ items: [SpatialNotebookItem]) {
        let incoming = Set(items.map(\.id))
        for (id, view) in itemViews where !incoming.contains(id) {
            view.removeFromSuperview()
            itemViews[id] = nil
        }

        for item in items.sorted(by: itemSort) {
            let view: CanvasItemView
            if let existing = itemViews[item.id] {
                view = existing
            } else {
                view = CanvasItemView(id: item.id)
                view.onSelect = { [weak self] id in self?.select(id) }
                view.onPlacementChanged = { [weak self] id, placement in
                    self?.itemsByID[id]?.placement = placement
                    self?.onPlacementChanged?(id, placement)
                }
                view.onTextChanged = { [weak self] id, text, placement in
                    self?.itemsByID[id]?.placement = placement
                    self?.onTextChanged?(id, text, placement)
                }
                view.onTextEditingEnded = { [weak self] id in
                    self?.onTextEditingEnded?(id)
                }
                view.onTextEditingStateChanged = { [weak self] isEditing in
                    guard let self else { return }
                    self.scrollView.panGestureRecognizer.isEnabled = !isEditing
                    self.scrollView.pinchGestureRecognizer?.isEnabled = !isEditing
                }
                contentView.addSubview(view)
                scrollView.panGestureRecognizer.require(toFail: view.dragGestureRecognizer)
                scrollView.pinchGestureRecognizer?.require(toFail: view.resizeGestureRecognizer)
                itemViews[item.id] = view
            }
            view.apply(
                item: item,
                documentOrigin: documentOrigin,
                interactionEnabled: mode == .select,
                selected: selectedItemId == item.id || lassoSelectedIds.contains(item.id)
            )
            view.layer.zPosition = CGFloat(item.placement.zIndex)
            contentView.bringSubviewToFront(view)
        }
        applyInteractionMode()
        paperView.layer.zPosition = -20_000
        pencilCanvas.layer.zPosition = 20_000
    }

    private func itemSort(_ lhs: SpatialNotebookItem, _ rhs: SpatialNotebookItem) -> Bool {
        if lhs.placement.zIndex != rhs.placement.zIndex {
            return lhs.placement.zIndex < rhs.placement.zIndex
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func fixedWorldBounds(pageSize: CGSize) -> CGRect {
        var bounds = CGRect(origin: .zero, size: pageSize)
        for item in itemsByID.values {
            bounds = bounds.union(
                CGRect(
                    x: item.placement.x,
                    y: item.placement.y,
                    width: max(item.placement.width, 1),
                    height: max(item.placement.height, 1)
                )
            )
        }
        if !worldDrawing.bounds.isNull, !worldDrawing.bounds.isInfinite {
            bounds = bounds.union(worldDrawing.bounds)
        }
        return bounds.integral
    }

    private func fixedGeometryNeedsExpansion() -> Bool {
        guard let width = configuration.pageWidth, let height = configuration.pageHeight else {
            return false
        }
        let required = fixedWorldBounds(pageSize: CGSize(width: width, height: height))
        let visibleWorld = contentView.bounds
            .insetBy(dx: Self.fixedPasteboardMargin / 2, dy: Self.fixedPasteboardMargin / 2)
            .offsetBy(dx: -documentOrigin.x, dy: -documentOrigin.y)
        return !visibleWorld.contains(required)
    }

    private func applyInkData(_ data: Data) {
        guard lastExternalInkData != data else { return }
        lastExternalInkData = data
        let decoded = data.isEmpty ? PKDrawing() : (try? PKDrawing(data: data)) ?? PKDrawing()
        guard decoded != worldDrawing else { return }
        worldDrawing = decoded
        applyWorldDrawing()
    }

    private func applyWorldDrawing() {
        let translation = CGAffineTransform(
            translationX: documentOrigin.x - pencilFrame.minX,
            y: documentOrigin.y - pencilFrame.minY
        )
        let displayed = worldDrawing.transformed(using: translation)
        guard pencilCanvas.drawing != displayed else { return }
        isApplyingDrawing = true
        pencilCanvas.drawing = displayed
        isApplyingDrawing = false
    }

    private func applyInteractionMode() {
        let drawing = mode == .ink && !isReadOnly
        if mode != .select { contentView.endEditing(true) }
        pencilCanvas.isUserInteractionEnabled = drawing
        itemViews.values.forEach { $0.setInteractionEnabled(mode == .select && !isReadOnly) }
        lassoView.isHidden = mode != .lasso
        scrollView.isScrollEnabled = mode != .lasso

        if drawing {
            if toolPicker == nil {
                let picker = PKToolPicker()
                picker.addObserver(pencilCanvas)
                toolPicker = picker
            }
            if let toolPicker {
                toolPicker.setVisible(true, forFirstResponder: pencilCanvas)
            }
            pencilCanvas.becomeFirstResponder()
        } else {
            if let toolPicker {
                toolPicker.setVisible(false, forFirstResponder: pencilCanvas)
            }
            if pencilCanvas.isFirstResponder { pencilCanvas.resignFirstResponder() }
        }
    }

    private func applySelection() {
        for (id, view) in itemViews {
            view.setSelected(id == selectedItemId || lassoSelectedIds.contains(id))
        }
    }

    private func select(_ id: UUID?) {
        selectedItemId = id
        applySelection()
        onSelect?(id)
    }

    private func applyPendingFocusIfPossible() {
        guard hasUsableViewportGeometry,
              let focus = pendingFocus,
              let item = itemsByID[focus.blockId]
        else { return }
        pendingFocus = nil
        let point = CGPoint(
            x: item.placement.x + item.placement.width / 2,
            y: item.placement.y + item.placement.height / 2
        )
        centerViewport(on: point, animated: UIAccessibility.isReduceMotionEnabled == false)
        select(focus.blockId)
        if let value = focus.highlightedText {
            itemViews[focus.blockId]?.highlight(value)
        }
    }

    private func finishLasso(in viewportRect: CGRect) {
        let contentRect = contentView.convert(viewportRect, from: self)
        let worldRect = contentRect.offsetBy(dx: -documentOrigin.x, dy: -documentOrigin.y)
        var selected: [UUID] = []
        var drawingImages: [UUID: Data] = [:]

        for item in itemsByID.values {
            let itemRect = CGRect(
                x: item.placement.x,
                y: item.placement.y,
                width: item.placement.width,
                height: item.placement.height
            )
            guard itemRect.intersects(worldRect) else { continue }
            selected.append(item.id)
            if case let .legacyDrawing(drawing) = item.content {
                let intersection = itemRect.intersection(worldRect)
                let local = intersection.offsetBy(dx: -itemRect.minX, dy: -itemRect.minY)
                if let image = cropDrawing(drawing, to: local) {
                    drawingImages[item.id] = image
                }
            } else if case let .image(image, _) = item.content {
                let intersection = itemRect.intersection(worldRect)
                let local = intersection.offsetBy(dx: -itemRect.minX, dy: -itemRect.minY)
                if let encoded = selectionPNG(
                    from: image,
                    itemSize: itemRect.size,
                    cropRect: local
                )
                {
                    drawingImages[item.id] = encoded
                }
            }
        }
        if let inkBlockId, let image = cropDrawing(worldDrawing, to: worldRect) {
            selected.append(inkBlockId)
            drawingImages[inkBlockId] = image
        }
        lassoView.reset()
        onLassoSelection?(
            LassoSelection(
                selectedBlockIds: Array(Set(selected)),
                drawingImagesByBlockId: drawingImages
            )
        )
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleViewport() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settleViewport() }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        settleViewport()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplyingDrawing else { return }
        let inverse = CGAffineTransform(
            translationX: -(documentOrigin.x - pencilFrame.minX),
            y: -(documentOrigin.y - pencilFrame.minY)
        )
        worldDrawing = canvasView.drawing.transformed(using: inverse)
        onInkChanged?(worldDrawing.dataRepresentation())
    }

    private func currentWorldCenter() -> CGPoint {
        let viewportCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let contentPoint = contentView.convert(viewportCenter, from: self)
        return CGPoint(
            x: contentPoint.x - documentOrigin.x,
            y: contentPoint.y - documentOrigin.y
        )
    }

    private func reportViewport() {
        onViewportChanged?(currentWorldCenter())
    }

    private func settleViewport() {
        guard configuration.pageFormat == .infinite else {
            reportViewport()
            return
        }
        let worldCenter = currentWorldCenter()
        infiniteWindowCenter = worldCenter
        documentOrigin = CGPoint(
            x: Self.infiniteExtent / 2 - worldCenter.x,
            y: Self.infiniteExtent / 2 - worldCenter.y
        )
        paperView.worldOriginInView = documentOrigin
        paperView.setNeedsDisplay()
        reconcileItems(Array(itemsByID.values))
        applyWorldDrawing()
        let scale = max(scrollView.zoomScale, 0.01)
        let target = CGPoint(
            x: Self.infiniteExtent / 2 * scale - bounds.width / 2,
            y: Self.infiniteExtent / 2 * scale - bounds.height / 2
        )
        UIView.performWithoutAnimation {
            scrollView.setContentOffset(target, animated: false)
        }
        onViewportChanged?(worldCenter)
    }

    private func centerViewport(on worldPoint: CGPoint, animated: Bool) {
        guard hasUsableViewportGeometry else { return }
        let scale = scrollView.zoomScale
        guard scale.isFinite, scale > 0 else { return }

        let needsInfiniteRecenter = configuration.pageFormat == .infinite
            && (
                abs(worldPoint.x - infiniteWindowCenter.x) > Self.infiniteExtent / 3
                    || abs(worldPoint.y - infiniteWindowCenter.y) > Self.infiniteExtent / 3
            )
        if needsInfiniteRecenter {
            infiniteWindowCenter = worldPoint
            documentOrigin = CGPoint(
                x: Self.infiniteExtent / 2 - worldPoint.x,
                y: Self.infiniteExtent / 2 - worldPoint.y
            )
            paperView.worldOriginInView = documentOrigin
            paperView.setNeedsDisplay()
            reconcileItems(Array(itemsByID.values))
            applyWorldDrawing()
        }
        let contentPoint = CGPoint(
            x: documentOrigin.x + worldPoint.x,
            y: documentOrigin.y + worldPoint.y
        )
        let targetOffset = CGPoint(
            x: contentPoint.x * scale - scrollView.bounds.width / 2,
            y: contentPoint.y * scale - scrollView.bounds.height / 2
        )
        guard targetOffset.x.isFinite, targetOffset.y.isFinite else { return }
        scrollView.setContentOffset(targetOffset, animated: animated)
    }

#if DEBUG
    var viewportZoomScaleForTesting: CGFloat { scrollView.zoomScale }
    var viewportWorldCenterForTesting: CGPoint { currentWorldCenter() }
    var hasPendingFocusForTesting: Bool { pendingFocus != nil }
#endif

    private func selectionPNG(
        from image: UIImage,
        itemSize: CGSize,
        cropRect: CGRect
    ) -> Data? {
        guard itemSize.width > 0, itemSize.height > 0, !cropRect.isEmpty else { return nil }
        var maximumDimension: CGFloat = 1_600
        for _ in 0 ..< 5 {
            let selectionScale = min(
                1,
                maximumDimension / max(cropRect.width, cropRect.height)
            )
            let size = CGSize(
                width: max(1, cropRect.width * selectionScale),
                height: max(1, cropRect.height * selectionScale)
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                let imageRatio = image.size.width / max(image.size.height, 0.01)
                let itemRatio = itemSize.width / max(itemSize.height, 0.01)
                let fitted: CGRect
                if imageRatio > itemRatio {
                    let height = itemSize.width / imageRatio
                    fitted = CGRect(
                        x: 0,
                        y: (itemSize.height - height) / 2,
                        width: itemSize.width,
                        height: height
                    )
                } else {
                    let width = itemSize.height * imageRatio
                    fitted = CGRect(
                        x: (itemSize.width - width) / 2,
                        y: 0,
                        width: width,
                        height: itemSize.height
                    )
                }
                let output = fitted
                    .offsetBy(dx: -cropRect.minX, dy: -cropRect.minY)
                    .applying(CGAffineTransform(scaleX: selectionScale, y: selectionScale))
                image.draw(in: output)
            }
            if let data = rendered.pngData(), data.count <= 2_000_000 { return data }
            maximumDimension *= 0.68
        }
        return nil
    }
}

@MainActor
final class NotebookPaperView: UIView {
    private struct DrawingState: @unchecked Sendable {
        var paperStyle = NotePaperStyle.plain
        var worldOriginInView = CGPoint.zero
        var lineColor = CGColor(gray: 0.5, alpha: 0.22)
    }

    private let drawingState = OSAllocatedUnfairLock(initialState: DrawingState())

    var paperStyle = NotePaperStyle.plain {
        didSet {
            let value = paperStyle
            drawingState.withLock { $0.paperStyle = value }
        }
    }
    var isInfinite = false
    var worldOriginInView = CGPoint.zero {
        didSet {
            let value = worldOriginInView
            drawingState.withLock { $0.worldOriginInView = value }
        }
    }

    override class var layerClass: AnyClass { CATiledLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        backgroundColor = .systemBackground
        layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        layer.borderWidth = 0.5
        updateDrawingColor()
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitAccessibilityContrast.self,
        ]) { (view: NotebookPaperView, _: UITraitCollection) in
            view.updateDrawingColor()
            view.setNeedsDisplay()
        }
        if let tiled = layer as? CATiledLayer {
            tiled.tileSize = CGSize(width: 512, height: 512)
            tiled.levelsOfDetail = 1
            tiled.levelsOfDetailBias = 3
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateDrawingColor() {
        let resolved = UIColor.separator
            .withAlphaComponent(0.22)
            .resolvedColor(with: traitCollection)
            .cgColor
        drawingState.withLock { $0.lineColor = resolved }
    }

    /// `CATiledLayer` invokes this callback on its image-provider queue. It must not inherit the
    /// view's main-actor isolation or read UIKit view state from that background renderer.
    nonisolated override func draw(_ rect: CGRect) {
        let state = drawingState.withLock { $0 }
        guard state.paperStyle != .plain,
              let context = UIGraphicsGetCurrentContext()
        else { return }
        context.setStrokeColor(state.lineColor)
        context.setFillColor(state.lineColor)
        context.setLineWidth(0.5)

        switch state.paperStyle {
        case .plain:
            break
        case .ruled:
            alignedValues(
                in: rect.minY ... rect.maxY,
                spacing: 28,
                offset: state.worldOriginInView.y + 14
            )
                .forEach { y in
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.strokePath()
        case .grid:
            alignedValues(in: rect.minX ... rect.maxX, spacing: 28, offset: state.worldOriginInView.x)
                .forEach { x in
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            alignedValues(in: rect.minY ... rect.maxY, spacing: 28, offset: state.worldOriginInView.y)
                .forEach { y in
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.strokePath()
        case .dotted:
            alignedValues(
                in: rect.minX ... rect.maxX,
                spacing: 24,
                offset: state.worldOriginInView.x + 12
            )
                .forEach { x in
                alignedValues(
                    in: rect.minY ... rect.maxY,
                    spacing: 24,
                    offset: state.worldOriginInView.y + 12
                )
                    .forEach { y in
                    context.fillEllipse(in: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4))
                }
            }
        }
    }

    nonisolated private func alignedValues(
        in range: ClosedRange<CGFloat>,
        spacing: CGFloat,
        offset: CGFloat
    ) -> StrideThrough<CGFloat> {
        let first = floor((range.lowerBound - offset) / spacing) * spacing + offset
        return stride(from: first, through: range.upperBound, by: spacing)
    }
}

@MainActor
private final class CanvasTextView: UITextView {
    var onCommand: ((CanvasTextCommand) -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(title: "Bold", action: #selector(bold), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "Italic", action: #selector(italic), input: "i", modifierFlags: .command),
            UIKeyCommand(title: "Underline", action: #selector(underline), input: "u", modifierFlags: .command),
            UIKeyCommand(title: "Bulleted List", action: #selector(bullets), input: "8", modifierFlags: [.command, .shift]),
        ]
    }

    @objc private func bold() { onCommand?(.bold) }
    @objc private func italic() { onCommand?(.italic) }
    @objc private func underline() { onCommand?(.underline) }
    @objc private func bullets() { onCommand?(.bullets) }
}

private enum CanvasTextCommand {
    case heading
    case bold
    case italic
    case underline
    case bullets
}

@MainActor
private final class CanvasItemView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    let id: UUID
    var onSelect: ((UUID) -> Void)?
    var onPlacementChanged: ((UUID, NoteCanvasPlacement) -> Void)?
    var onTextChanged: ((UUID, NSAttributedString, NoteCanvasPlacement) -> Void)?
    var onTextEditingEnded: ((UUID) -> Void)?
    var onTextEditingStateChanged: ((Bool) -> Void)?

    private let textView = CanvasTextView()
    private let imageView = UIImageView()
    private let placeholderLabel = UILabel()
    private var item: SpatialNotebookItem?
    private var documentOrigin = CGPoint.zero
    private var modelPlacement = NoteCanvasPlacement(x: 0, y: 0, width: 100, height: 100)
    private var interactionEnabled = false
    private var isApplyingText = false
    private var selected = false
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    private lazy var rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))

    var dragGestureRecognizer: UIPanGestureRecognizer { pan }
    var resizeGestureRecognizer: UIPinchGestureRecognizer { pinch }

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        isOpaque = false
        layer.cornerRadius = 4
        layer.masksToBounds = true

        textView.delegate = self
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.accessibilityLabel = "Canvas text"
        textView.onCommand = { [weak self] command in self?.perform(command) }
        textView.inputAccessoryView = makeFormattingToolbar()
        addSubview(textView)

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)

        placeholderLabel.numberOfLines = 0
        placeholderLabel.textAlignment = .center
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.font = .preferredFont(forTextStyle: .caption1)
        addSubview(placeholderLabel)

        pan.delegate = self
        pinch.delegate = self
        rotation.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
        addGestureRecognizer(rotation)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        imageView.frame = bounds
        placeholderLabel.frame = bounds.insetBy(dx: 12, dy: 12)
    }

    func apply(
        item: SpatialNotebookItem,
        documentOrigin: CGPoint,
        interactionEnabled: Bool,
        selected: Bool
    ) {
        self.item = item
        self.documentOrigin = documentOrigin
        modelPlacement = safe(item.placement)
        if !textView.isFirstResponder { applyModelGeometry() }

        textView.isHidden = true
        imageView.isHidden = true
        placeholderLabel.isHidden = true
        switch item.content {
        case let .text(value):
            textView.isHidden = false
            if !textView.isFirstResponder, !textView.attributedText.isEqual(to: value) {
                isApplyingText = true
                textView.attributedText = value
                isApplyingText = false
            }
        case let .image(image, filename):
            imageView.isHidden = false
            imageView.image = image
            accessibilityLabel = "Image, \(filename)"
        case let .legacyDrawing(drawing):
            imageView.isHidden = false
            let renderRect = CGRect(origin: .zero, size: modelSize)
            imageView.image = drawing.image(from: renderRect, scale: 2)
            accessibilityLabel = "Handwritten drawing"
        case let .unsupported(label):
            placeholderLabel.isHidden = false
            placeholderLabel.text = label
            accessibilityLabel = label
        }
        setInteractionEnabled(interactionEnabled)
        setSelected(selected)
    }

    func setInteractionEnabled(_ enabled: Bool) {
        interactionEnabled = enabled
        isUserInteractionEnabled = enabled
        pan.isEnabled = enabled && !textView.isFirstResponder
        pinch.isEnabled = enabled && selected && !textView.isFirstResponder
        rotation.isEnabled = enabled && selected && !textView.isFirstResponder
        textView.isEditable = enabled && textView.isFirstResponder
        textView.isSelectable = enabled && textView.isFirstResponder
    }

    func setSelected(_ value: Bool) {
        selected = value
        layer.borderWidth = value ? 1.5 : 0
        layer.borderColor = UIColor.label.withAlphaComponent(0.55).cgColor
        backgroundColor = value ? UIColor.secondarySystemFill.withAlphaComponent(0.35) : .clear
        pinch.isEnabled = interactionEnabled && value && !textView.isFirstResponder
        rotation.isEnabled = interactionEnabled && value && !textView.isFirstResponder
    }

    func beginTextEditing() {
        guard case .text = item?.content else { return }
        textView.isEditable = true
        textView.isSelectable = true
        pan.isEnabled = false
        pinch.isEnabled = false
        rotation.isEnabled = false
        onTextEditingStateChanged?(true)
        textView.becomeFirstResponder()
    }

    func highlight(_ value: String) {
        guard !value.isEmpty, !textView.isHidden else { return }
        let range = (textView.text as NSString).range(of: value, options: .caseInsensitive)
        guard range.location != NSNotFound else { return }
        textView.isSelectable = true
        textView.selectedRange = range
        UIAccessibility.post(notification: .announcement, argument: "Matched text selected")
    }

    @objc private func handleTap() {
        guard interactionEnabled else { return }
        if selected, !textView.isHidden {
            beginTextEditing()
        } else {
            onSelect?(id)
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard interactionEnabled, let superview else { return }
        let translation = recognizer.translation(in: superview)
        center = CGPoint(x: center.x + translation.x, y: center.y + translation.y)
        recognizer.setTranslation(.zero, in: superview)
        modelPlacement.x = Double(center.x - documentOrigin.x - bounds.width / 2)
        modelPlacement.y = Double(center.y - documentOrigin.y - bounds.height / 2)
        if recognizer.state == .began { onSelect?(id) }
        if recognizer.state == .ended || recognizer.state == .cancelled {
            onPlacementChanged?(id, modelPlacement)
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard interactionEnabled, selected else { return }
        let scale = recognizer.scale
        let width = min(max(bounds.width * scale, 80), 2_400)
        let height = min(max(bounds.height * scale, 56), 2_400)
        bounds.size = CGSize(width: width, height: height)
        modelPlacement.width = Double(width)
        modelPlacement.height = Double(height)
        modelPlacement.x = Double(center.x - documentOrigin.x - width / 2)
        modelPlacement.y = Double(center.y - documentOrigin.y - height / 2)
        recognizer.scale = 1
        if recognizer.state == .ended || recognizer.state == .cancelled {
            onPlacementChanged?(id, modelPlacement)
        }
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard interactionEnabled, selected else { return }
        modelPlacement.rotationRadians += Double(recognizer.rotation)
        transform = CGAffineTransform(rotationAngle: modelPlacement.rotationRadians)
        recognizer.rotation = 0
        if recognizer.state == .ended || recognizer.state == .cancelled {
            onPlacementChanged?(id, modelPlacement)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer === pinch && otherGestureRecognizer === rotation)
            || (gestureRecognizer === rotation && otherGestureRecognizer === pinch)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isApplyingText else { return }
        let fitted = textView.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        if fitted.height > bounds.height {
            let height = min(max(fitted.height, 56), 1_200)
            modelPlacement.height = Double(height)
            applyModelGeometry()
        }
        onTextChanged?(
            id,
            NSAttributedString(attributedString: textView.attributedText),
            modelPlacement
        )
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        textView.isEditable = false
        textView.isSelectable = false
        pan.isEnabled = interactionEnabled
        pinch.isEnabled = interactionEnabled && selected
        rotation.isEnabled = interactionEnabled && selected
        onTextEditingStateChanged?(false)
        onTextEditingEnded?(id)
    }

    private var modelSize: CGSize {
        CGSize(width: modelPlacement.width, height: modelPlacement.height)
    }

    private func applyModelGeometry() {
        bounds = CGRect(origin: .zero, size: modelSize)
        center = CGPoint(
            x: documentOrigin.x + modelPlacement.x + modelPlacement.width / 2,
            y: documentOrigin.y + modelPlacement.y + modelPlacement.height / 2
        )
        transform = CGAffineTransform(rotationAngle: modelPlacement.rotationRadians)
    }

    private func safe(_ value: NoteCanvasPlacement) -> NoteCanvasPlacement {
        NoteCanvasPlacement(
            x: value.x.isFinite ? min(max(value.x, -100_000), 100_000) : 0,
            y: value.y.isFinite ? min(max(value.y, -100_000), 100_000) : 0,
            width: value.width.isFinite ? min(max(value.width, 80), 2_400) : 320,
            height: value.height.isFinite ? min(max(value.height, 56), 2_400) : 160,
            rotationRadians: value.rotationRadians.isFinite ? value.rotationRadians : 0,
            zIndex: min(max(value.zIndex, -10_000), 10_000)
        )
    }

    private func makeFormattingToolbar() -> UIToolbar {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        func item(_ title: String, _ action: Selector, label: String) -> UIBarButtonItem {
            let item = UIBarButtonItem(title: title, style: .plain, target: self, action: action)
            item.accessibilityLabel = label
            return item
        }
        toolbar.items = [
            item("Aa", #selector(heading), label: "Heading"),
            item("B", #selector(bold), label: "Bold"),
            item("I", #selector(italic), label: "Italic"),
            item("U", #selector(underline), label: "Underline"),
            UIBarButtonItem(
                image: UIImage(systemName: "list.bullet"),
                style: .plain,
                target: self,
                action: #selector(bullets)
            ),
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(done)),
        ]
        toolbar.items?[4].accessibilityLabel = "Bulleted list"
        return toolbar
    }

    @objc private func heading() { perform(.heading) }
    @objc private func bold() { perform(.bold) }
    @objc private func italic() { perform(.italic) }
    @objc private func underline() { perform(.underline) }
    @objc private func bullets() { perform(.bullets) }
    @objc private func done() { textView.resignFirstResponder() }

    private func perform(_ command: CanvasTextCommand) {
        switch command {
        case .heading:
            applyFont(.preferredFont(forTextStyle: .title3))
        case .bold:
            toggleTrait(.traitBold)
        case .italic:
            toggleTrait(.traitItalic)
        case .underline:
            toggleUnderline()
        case .bullets:
            toggleBullets()
        }
    }

    private func applyFont(_ font: UIFont) {
        let range = textView.selectedRange
        if range.length == 0 {
            textView.typingAttributes[.font] = font
        } else {
            let value = NSMutableAttributedString(attributedString: textView.attributedText)
            value.addAttribute(.font, value: font, range: range)
            replaceText(value, selection: range)
        }
    }

    private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        let range = textView.selectedRange
        if range.length == 0 {
            let font = textView.typingAttributes[.font] as? UIFont
                ?? .preferredFont(forTextStyle: .body)
            textView.typingAttributes[.font] = toggled(font, trait: trait)
            return
        }
        let value = NSMutableAttributedString(attributedString: textView.attributedText)
        value.enumerateAttribute(.font, in: range) { current, subrange, _ in
            let font = current as? UIFont ?? .preferredFont(forTextStyle: .body)
            value.addAttribute(.font, value: toggled(font, trait: trait), range: subrange)
        }
        replaceText(value, selection: range)
    }

    private func toggled(_ font: UIFont, trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        var traits = font.fontDescriptor.symbolicTraits
        if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private func toggleUnderline() {
        let range = textView.selectedRange
        if range.length == 0 {
            let active = (textView.typingAttributes[.underlineStyle] as? Int ?? 0) != 0
            textView.typingAttributes[.underlineStyle] = active ? 0 : NSUnderlineStyle.single.rawValue
            return
        }
        let value = NSMutableAttributedString(attributedString: textView.attributedText)
        let active = range.location < value.length
            && (value.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        value.addAttribute(
            .underlineStyle,
            value: active ? 0 : NSUnderlineStyle.single.rawValue,
            range: range
        )
        replaceText(value, selection: range)
    }

    private func toggleBullets() {
        let source = textView.text as NSString
        let range = source.paragraphRange(for: textView.selectedRange)
        let paragraph = source.substring(with: range)
        let lines = paragraph.components(separatedBy: "\n")
        let hasBullets = lines.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix("• ") }
        let transformed = lines.map { line in
            guard !line.isEmpty else { return line }
            return hasBullets ? String(line.dropFirst(2)) : "• \(line)"
        }.joined(separator: "\n")
        let value = NSMutableAttributedString(attributedString: textView.attributedText)
        value.replaceCharacters(in: range, with: transformed)
        replaceText(
            value,
            selection: NSRange(location: range.location, length: (transformed as NSString).length)
        )
    }

    private func replaceText(_ value: NSAttributedString, selection: NSRange) {
        textView.attributedText = value
        textView.selectedRange = selection
        textViewDidChange(textView)
    }
}
