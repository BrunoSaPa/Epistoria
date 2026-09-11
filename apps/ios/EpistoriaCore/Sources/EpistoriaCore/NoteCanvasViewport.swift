import Foundation

/// Device-local infinite-canvas position in document coordinates, independent of window size.
public struct NoteCanvasViewport: Codable, Equatable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double
    public var recordedAt: Date

    public init(centerX: Double, centerY: Double, zoom: Double, recordedAt: Date = .now) {
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = zoom
        self.recordedAt = recordedAt
    }

    public var isValid: Bool {
        centerX.isFinite && centerY.isFinite && abs(centerX) <= 1_000_000_000
            && abs(centerY) <= 1_000_000_000 && zoom.isFinite && (0.25...4).contains(zoom)
            && recordedAt.timeIntervalSince1970.isFinite
    }
}
