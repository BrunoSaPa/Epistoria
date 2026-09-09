import EpistoriaCore
import SwiftUI

struct NotePagePreviewInput: Equatable {
    let page: IdentifiedPayload<NotePagePayload>
    let blocks: [IdentifiedPayload<NoteBlockPayload>]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.page.id == rhs.page.id && lhs.page.payload == rhs.page.payload
            && lhs.blocks.elementsEqual(rhs.blocks) { $0.id == $1.id && $0.payload == $1.payload }
    }
}

/// Owned by one page-manager presentation, never persisted or synchronized.
@MainActor
final class NotePagePreviewCache {
    private final class Entry {
        let input: NotePagePreviewInput
        let image: UIImage
        init(input: NotePagePreviewInput, image: UIImage) { self.input = input; self.image = image }
    }
    private let entries = NSCache<NSUUID, Entry>()

    init() {
        entries.countLimit = 32
        entries.totalCostLimit = 12 * 1_024 * 1_024
    }

    func image(for input: NotePagePreviewInput) -> UIImage? {
        guard let entry = entries.object(forKey: input.page.id as NSUUID), entry.input == input else { return nil }
        return entry.image
    }

    func insert(_ image: UIImage, for input: NotePagePreviewInput) {
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        entries.setObject(Entry(input: input, image: image), forKey: input.page.id as NSUUID, cost: cost)
    }
}

struct NotePagePreview: View {
    let input: NotePagePreviewInput
    let service: NotePDFExportService?
    let cache: NotePagePreviewCache

    private enum LoadState {
        case loading
        case ready(UIImage)
        case unavailable
    }
    @State private var state: LoadState = .loading

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Rectangle().fill(input.page.payload.configuration.paperColor.swiftUIColor)
                switch state {
                case .loading: ProgressView().controlSize(.small)
                case .ready(let image): Image(uiImage: image).resizable().scaledToFit()
                case .unavailable:
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                }
            }
            .aspectRatio(CGFloat(input.page.payload.configuration.pageWidth ?? 595)
                / CGFloat(input.page.payload.configuration.pageHeight ?? 842), contentMode: .fit)
            .overlay { Rectangle().stroke(Color.black.opacity(0.18), lineWidth: 0.5) }
            .frame(width: 76, height: 100)
            .accessibilityHidden(true)
            if case .unavailable = state {
                Text("Preview unavailable").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 90)
            }
        }
        .task(id: input) {
            state = .loading
            if let image = cache.image(for: input) { state = .ready(image); return }
            do {
                guard let service else { state = .unavailable; return }
                try Task.checkCancellation()
                let image = try await service.pagePreview(page: input.page, blocks: input.blocks)
                try Task.checkCancellation()
                cache.insert(image, for: input)
                state = .ready(image)
            } catch is CancellationError {
                // Dismissal and row replacement must not publish a late preview.
            } catch {
                guard !Task.isCancelled else { return }
                state = .unavailable
            }
        }
    }
}
