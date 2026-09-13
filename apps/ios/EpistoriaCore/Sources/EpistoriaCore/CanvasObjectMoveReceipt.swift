import Foundation

/// Device-local undo data. Never synchronized or included in notebook exports.
public struct CanvasObjectMoveReceipt: Sendable {
    public let noteId: UUID
    public let before: [StoredEntity]
    public let after: [StoredEntity]
}
