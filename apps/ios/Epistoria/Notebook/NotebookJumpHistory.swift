import EpistoriaCore
import Foundation

/// Navigation-only snapshots for the current editor, never notebook content or undo history.
struct NotebookJumpHistory {
    enum Location: Equatable {
        case page(NoteReadingPosition)
        case canvas(NoteCanvasViewport)
    }
    private(set) var locations: [Location] = []
    var isEmpty: Bool { locations.isEmpty }

    mutating func record(_ location: Location) {
        locations.append(location)
        if locations.count > 20 { locations.removeFirst(locations.count - 20) }
    }

    mutating func previous(pageIds: Set<UUID>, infinite: Bool) -> Location? {
        while let location = locations.popLast() {
            switch location {
            case let .page(position) where !infinite && pageIds.contains(position.pageId): return location
            case let .canvas(viewport) where infinite && viewport.isValid: return location
            default: continue
            }
        }
        return nil
    }
}
