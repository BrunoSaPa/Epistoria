import EpistoriaCore
import SwiftUI

private struct NotebookPageFramePreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

enum ContinuousNotebookPageSelection {
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
    @Binding var currentPageIndex: Int
    @Binding var requestedPageIndex: Int?
    let onPageVisible: (Int) -> Void
    @ViewBuilder let pageContent: (Int, NoteCanvasConfiguration) -> PageContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { viewport in
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
