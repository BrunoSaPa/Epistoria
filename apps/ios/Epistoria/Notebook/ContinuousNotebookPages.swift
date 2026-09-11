import EpistoriaCore
import SwiftUI

enum ContinuousNotebookPageSelection {
    static let pageGap: CGFloat = 16
    static let outerPadding: CGFloat = 8

    static func pageWidth(viewportWidth: CGFloat) -> CGFloat {
        guard viewportWidth.isFinite else { return 1 }
        return max(1, viewportWidth - 2 * outerPadding)
    }
    static func readingPosition(pageIds: [UUID], heights: [CGFloat], offset: CGFloat) -> NoteReadingPosition? {
        guard offset.isFinite, pageIds.count == heights.count else { return nil }
        var top = outerPadding
        for (index, height) in heights.enumerated() {
            guard height.isFinite, height > 0 else { return nil }
            if offset < top + height + pageGap || index == heights.count - 1 {
                return NoteReadingPosition(pageId: pageIds[index], fraction: Double((offset - top) / height))
            }
            top += height + pageGap
        }
        return nil
    }

    static func offset(for position: NoteReadingPosition, pageIds: [UUID], heights: [CGFloat]) -> CGFloat? {
        guard pageIds.count == heights.count, let index = pageIds.firstIndex(of: position.pageId),
              position.fraction.isFinite, heights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return max(0, outerPadding + heights.prefix(index).reduce(0) { $0 + $1 + pageGap }
            + heights[index] * CGFloat(min(max(position.fraction, 0), 1)))
    }

    static func nearestPage(
        heights: [CGFloat],
        offset: CGFloat,
        viewportHeight: CGFloat
    ) -> Int? {
        guard offset.isFinite, viewportHeight.isFinite, viewportHeight > 0,
              !heights.isEmpty, heights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let centerY = offset + viewportHeight / 2
        var top = outerPadding
        for (index, height) in heights.enumerated() {
            if centerY < top + height + pageGap / 2 { return index }
            top += height + pageGap
        }
        return heights.count - 1
    }
}

/// Presents fixed paper as one continuous document. Page canvases remain independent persistence
/// units, while one outer scroll view owns finger, pointer, and momentum navigation.
struct ContinuousNotebookPages<PageContent: View>: View {
    let pageConfigurations: [NoteCanvasConfiguration]
    let pageIds: [UUID]
    let initialReadingPosition: NoteReadingPosition?
    let onReadingPositionChanged: (NoteReadingPosition) -> Void
    let onReadingPaused: () -> Void
    @Binding var currentPageIndex: Int
    @Binding var requestedPageIndex: Int?
    @Binding var requestedReadingPosition: NoteReadingPosition?
    let onPageVisible: (Int) -> Void
    @ViewBuilder let pageContent: (Int, NoteCanvasConfiguration) -> PageContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition()
    @State private var restoredInitialPosition = false
    @State private var hasNavigated = false

    var body: some View {
        GeometryReader { viewport in
            let heights = pageConfigurations.map {
                ContinuousNotebookPageSelection.pageWidth(viewportWidth: viewport.size.width)
                    * CGFloat($0.pageHeight ?? 842) / CGFloat($0.pageWidth ?? 595)
            }
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    LazyVStack(spacing: ContinuousNotebookPageSelection.pageGap) {
                        ForEach(Array(pageConfigurations.enumerated()), id: \.offset) { pageIndex, configuration in
                            let pageWidth = ContinuousNotebookPageSelection.pageWidth(viewportWidth: viewport.size.width)
                            let ratio = CGFloat(configuration.pageHeight ?? 842)
                                / CGFloat(configuration.pageWidth ?? 595)
                            let pageHeight = pageWidth * ratio
                            pageContent(pageIndex, configuration)
                                .frame(width: pageWidth, height: pageHeight)
                                .background(configuration.paperColor.swiftUIColor)
                                .overlay {
                                    Rectangle()
                                        .stroke(EpistoriaDesign.border, lineWidth: 0.5)
                                        .allowsHitTesting(false)
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    Text("\(pageIndex + 1)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(EpistoriaDesign.mutedInk)
                                        .padding(8)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                                .id(pageIndex)
                                .onAppear { onPageVisible(pageIndex) }
                                .accessibilityLabel("Notebook page \(pageIndex + 1)")
                                .accessibilityIdentifier("note.page.\(pageIndex + 1)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ContinuousNotebookPageSelection.outerPadding)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGSize.self) { geometry in
                    geometry.contentSize
                } action: { _, size in
                    guard !hasNavigated, size.height > 0, let initialReadingPosition,
                          let offset = ContinuousNotebookPageSelection.offset(for: initialReadingPosition, pageIds: pageIds, heights: heights) else { return }
                    scrollPosition.scrollTo(y: offset)
                }
                .onScrollGeometryChange(for: CGRect.self) { geometry in
                    CGRect(x: 0, y: geometry.contentOffset.y + geometry.contentInsets.top,
                           width: geometry.containerSize.width, height: geometry.containerSize.height)
                } action: { _, visible in
                    if let index = ContinuousNotebookPageSelection.nearestPage(
                        heights: heights, offset: visible.minY, viewportHeight: visible.height
                    ) { currentPageIndex = index }
                    guard restoredInitialPosition,
                          let position = ContinuousNotebookPageSelection.readingPosition(pageIds: pageIds, heights: heights, offset: visible.minY) else { return }
                    onReadingPositionChanged(position)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting { hasNavigated = true }
                    if phase == .idle { onReadingPaused() }
                }
                .onChange(of: viewport.size) { _, _ in
                    // Opening an editor collapses the app sidebar. Resolve against the final
                    // page width, but never override a scroll or explicit navigation by the owner.
                    guard !hasNavigated, let initialReadingPosition,
                          let offset = ContinuousNotebookPageSelection.offset(for: initialReadingPosition, pageIds: pageIds, heights: heights) else { return }
                    scrollPosition.scrollTo(y: offset)
                }
                .task {
                    guard !restoredInitialPosition else { return }
                    if let initialReadingPosition,
                       let offset = ContinuousNotebookPageSelection.offset(for: initialReadingPosition, pageIds: pageIds, heights: heights) {
                        scrollPosition.scrollTo(y: offset)
                    } else if let target = requestedPageIndex {
                        reader.scrollTo(target, anchor: .center)
                        requestedPageIndex = nil
                    }
                    restoredInitialPosition = true
                }
                .onChange(of: requestedPageIndex) { _, target in
                    guard let target else { return }
                    hasNavigated = true
                    if reduceMotion {
                        reader.scrollTo(target, anchor: .center)
                    } else {
                        withAnimation(.snappy(duration: 0.32, extraBounce: 0)) {
                            reader.scrollTo(target, anchor: .center)
                        }
                    }
                    DispatchQueue.main.async { requestedPageIndex = nil }
                }
                .onChange(of: requestedReadingPosition) { _, target in
                    guard let target,
                          let offset = ContinuousNotebookPageSelection.offset(for: target, pageIds: pageIds, heights: heights) else { return }
                    hasNavigated = true
                    scrollPosition.scrollTo(y: offset)
                    requestedReadingPosition = nil
                }
            }
        }
        .background(EpistoriaDesign.sidebar)
    }
}
