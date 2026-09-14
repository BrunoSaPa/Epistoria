@testable import Epistoria
import EpistoriaCore
import Foundation
import Testing

@MainActor
struct NotebookPDFPanelTests {
    @Test func usesOnlyTheFrozenVersionsOriginalAsset() throws {
        let sourceId = UUID()
        let assetId = UUID()
        let evidence = EvidencePayload(sourceId: sourceId, sourceVersionId: UUID(), kind: .excerpt,
            locator: SourceLocator(kind: .pdf, page: 2), excerpt: "Saved excerpt")
        var version = SourceVersionPayload(sourceId: sourceId, versionNumber: 1, originalAssetId: assetId)
        #expect(try NotebookPDFPanel.originalAsset(for: NotebookPDFTarget(id: UUID(), evidence: evidence), version: version) == assetId)
        version.originalAssetId = nil
        #expect(throws: StoreError.self) {
            try NotebookPDFPanel.originalAsset(for: NotebookPDFTarget(id: UUID(), evidence: evidence), version: version)
        }
    }

    @Test func refusesARevisionFromAnotherSource() {
        let evidence = EvidencePayload(sourceId: UUID(), sourceVersionId: UUID(), kind: .excerpt,
            locator: SourceLocator(kind: .pdf, page: 1), excerpt: "Saved excerpt")
        let version = SourceVersionPayload(sourceId: UUID(), versionNumber: 1, originalAssetId: UUID())
        #expect(throws: SourceModelError.sourceVersionMismatch) {
            try NotebookPDFPanel.originalAsset(for: NotebookPDFTarget(id: UUID(), evidence: evidence), version: version)
        }
    }

    @Test func refusesMissingPDFPage() {
        let sourceId = UUID()
        let evidence = EvidencePayload(sourceId: sourceId, sourceVersionId: UUID(), kind: .excerpt,
            locator: SourceLocator(kind: .pdf), excerpt: "Saved excerpt")
        let version = SourceVersionPayload(sourceId: sourceId, versionNumber: 1, originalAssetId: UUID())
        #expect(throws: SourceModelError.invalidLocator) {
            try NotebookPDFPanel.originalAsset(for: NotebookPDFTarget(id: UUID(), evidence: evidence), version: version)
        }
    }
}
