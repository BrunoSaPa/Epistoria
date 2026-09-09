import EpistoriaCore
import SwiftUI

private struct NotebookPageFramePreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

enum ContinuousNotebookPageSelection {
    static func readingPosition(pageIds: [UUID], heights: [CGFloat], offset: CGFloat) -> NoteReadingPosition? {
        guard offset.isFinite, pageIds.count == heights.count else { return nil }
        var top: CGFloat = 28
        for (index, height) in heights.enumerated() {
            guard height.isFinite, height > 0 else { return nil }
            if offset < top + height + 24 || index == heights.count - 1 {
                return NoteReadingPosition(pageId: pageIds[index], fraction: Double((offset - top) / height))
            }
            top += height + 24
        }
        return nil
    }

    static func offset(for position: NoteReadingPosition, pageIds: [UUID], heights: [CGFloat]) -> CGFloat? {
        guard pageIds.count == heights.count, let index = pageIds.firstIndex(of: position.pageId),
              position.fraction.isFinite, heights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return max(0, 28 + heights.prefix(index).reduce(0) { $0 + $1 + 24 }
            + heights[index] * CGFloat(min(max(position.fraction, 0), 1)))
    }

    static func nearestPage(
        in frames: [Int: CGRect],
        viewportHeight: CGFloat
    ) -> Int? {
        let centerY = viewportHeight / 2
        return frames.min {
            abs($0.value.midY - centerY) < abs($1.value.midY - centerY)
        }?.key
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
    let onPageVisible: (Int) -> Void
    @ViewBuilder let pageContent: (Int, NoteCanvasConfiguration) -> PageContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition()
    @State private var restoredInitialPosition = false

    var body: some View {
        GeometryReader { viewport in
            let heights = pageConfigurations.map {
                min(max(viewport.size.width - 56, 320), 920)
                    * CGFloat($0.pageHeight ?? 842) / CGFloat($0.pageWidth ?? 595)
            }
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 24) {
                        ForEach(Array(pageConfigurations.enumerated()), id: \.offset) { pageIndex, configuration in
                            let pageWidth = min(max(viewport.size.width - 56, 320), 920)
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
                                .background {
                                    GeometryReader { page in
                                        Color.clear.preference(
                                            key: NotebookPageFramePreferenceKey.self,
                                            value: [
                                                pageIndex: page.frame(
                                                    in: .named("epistoria-continuous-pages")
                                                ),
                                            ]
                                        )
                                    }
                                }
                                .id(pageIndex)
                                .onAppear { onPageVisible(pageIndex) }
                                .accessibilityLabel("Notebook page \(pageIndex + 1)")
                                .accessibilityIdentifier("note.page.\(pageIndex + 1)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
                .coordinateSpace(name: "epistoria-continuous-pages")
                .scrollDismissesKeyboard(.interactively)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, offset in
                    guard restoredInitialPosition,
                          let position = ContinuousNotebookPageSelection.readingPosition(pageIds: pageIds, heights: heights, offset: offset) else { return }
                    onReadingPositionChanged(position)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .idle { onReadingPaused() }
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
                .onPreferenceChange(NotebookPageFramePreferenceKey.self) { frames in
                    guard let nearest = ContinuousNotebookPageSelection.nearestPage(
                        in: frames,
                        viewportHeight: viewport.size.height
                    ),
                        nearest != currentPageIndex
                    else { return }
                    DispatchQueue.main.async { currentPageIndex = nearest }
                }
                .onChange(of: requestedPageIndex) { _, target in
                    guard let target else { return }
                    if reduceMotion {
                        reader.scrollTo(target, anchor: .center)
                    } else {
                        withAnimation(.snappy(duration: 0.32, extraBounce: 0)) {
                            reader.scrollTo(target, anchor: .center)
                        }
                    }
                    DispatchQueue.main.async { requestedPageIndex = nil }
                }
            }
        }
        .background(EpistoriaDesign.sidebar)
    }
}
