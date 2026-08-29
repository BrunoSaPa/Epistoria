import EpistoriaCore
import Foundation

struct SharedCaptureImportReport: Equatable, Sendable {
    var importedCount: Int
    var duplicateCount: Int
    var failedCount: Int
    var remainingPendingCount: Int
    var firstFailureDescription: String?
}

/// Drains the extension's encrypted device-local queue only after SQLCipher has unlocked.
/// Imported Sources use the capture UUID as an opaque idempotency identifier so a crash after the
/// database transaction but before queue cleanup cannot duplicate user content.
struct SharedCaptureImporter: Sendable {
    let inbox: SharedCaptureInbox
    private let loadCaptureKey: @Sendable () throws -> Data

    init(inbox: SharedCaptureInbox, keyStore: SharedCaptureKeyStore) {
        self.inbox = inbox
        loadCaptureKey = { try keyStore.loadOrCreate() }
    }

    init(inbox: SharedCaptureInbox, captureKey: Data) {
        self.inbox = inbox
        loadCaptureKey = { captureKey }
    }

    static func live() -> SharedCaptureImporter? {
        guard let inbox = SharedCaptureInbox.live() else { return nil }
        return SharedCaptureImporter(
            inbox: inbox,
            keyStore: SharedCaptureKeyStore.configured()
        )
    }

    func drain(store: EpistoriaStore, assetManager: AssetManager) async -> SharedCaptureImportReport {
        var report = SharedCaptureImportReport(
            importedCount: 0,
            duplicateCount: 0,
            failedCount: 0,
            remainingPendingCount: 0,
            firstFailureDescription: nil
        )
        do {
            let key = try loadCaptureKey()
            let pending = try inbox.identifiers(in: .pending)
            let existing = try await store.list(SourcePayload.self)
            var identifiers = Set(existing.flatMap(\.payload.identifiers))

            for id in pending {
                if Task.isCancelled { break }
                let captureIdentifier = Self.identifier(for: id)
                do {
                    if identifiers.contains(captureIdentifier) {
                        try inbox.remove(id: id, from: .pending)
                        report.duplicateCount += 1
                        continue
                    }
                    let item = try inbox.item(id: id, location: .pending, key: key)
                    try await importItem(
                        item,
                        captureIdentifier: captureIdentifier,
                        assetManager: assetManager
                    )
                    identifiers.insert(captureIdentifier)
                    try inbox.remove(id: id, from: .pending)
                    report.importedCount += 1
                } catch {
                    try? inbox.markFailed(id: id)
                    report.failedCount += 1
                    if report.firstFailureDescription == nil {
                        report.firstFailureDescription = error.localizedDescription
                    }
                }
            }
            report.remainingPendingCount = try inbox.identifiers(in: .pending).count
            report.failedCount = try inbox.identifiers(in: .failed).count
        } catch {
            report.firstFailureDescription = error.localizedDescription
            report.remainingPendingCount = (try? inbox.identifiers(in: .pending).count) ?? 0
            report.failedCount = (try? inbox.identifiers(in: .failed).count) ?? 0
        }
        return report
    }

    func retryFailed() throws {
        try inbox.retryFailed()
    }

    func discardFailed() throws {
        try inbox.removeAllFailed()
    }

    func counts() -> (pending: Int, failed: Int) {
        (
            (try? inbox.identifiers(in: .pending).count) ?? 0,
            (try? inbox.identifiers(in: .failed).count) ?? 0
        )
    }

    static func identifier(for id: UUID) -> String {
        "share-capture:\(id.uuidString.lowercased())"
    }

    private func importItem(
        _ item: SharedCaptureItem,
        captureIdentifier: String,
        assetManager: AssetManager
    ) async throws {
        switch item.kind {
        case .image, .file:
            let fallback = item.kind == .image ? "Shared image.png" : "Shared file"
            _ = try await assetManager.importSource(
                data: item.payload,
                filename: item.filename ?? fallback,
                identifiers: [captureIdentifier]
            )
        case .text:
            guard let text = String(data: item.payload, encoding: .utf8) else {
                throw SharedCaptureInboxError.invalidItem
            }
            _ = try await assetManager.importPastedText(
                text,
                title: item.title,
                identifiers: [captureIdentifier]
            )
        case .link:
            guard let string = String(data: item.payload, encoding: .utf8),
                  let url = URL(string: string)
            else { throw SharedCaptureInboxError.invalidItem }
            _ = try await assetManager.importURLReference(
                url,
                title: item.title,
                identifiers: [captureIdentifier]
            )
        }
    }
}
