@testable import Epistoria
import XCTest

@MainActor
final class WorkspacePresentationTests: XCTestCase {
    func testOnlyTheActiveEditorCanEndImmersivePresentation() {
        let presentation = EpistoriaWorkspacePresentation()
        let firstEditor = UUID()
        let secondEditor = UUID()

        presentation.beginImmersiveEditing(id: firstEditor)
        presentation.beginImmersiveEditing(id: secondEditor)
        presentation.endImmersiveEditing(id: firstEditor)

        XCTAssertTrue(presentation.isEditingImmersively)
        XCTAssertEqual(presentation.activeImmersiveEditorID, secondEditor)

        presentation.endImmersiveEditing(id: secondEditor)

        XCTAssertFalse(presentation.isEditingImmersively)
        XCTAssertNil(presentation.activeImmersiveEditorID)
    }

    func testResetAlwaysRestoresTheWorkspaceNavigation() {
        let presentation = EpistoriaWorkspacePresentation()
        presentation.beginImmersiveEditing(id: UUID())

        presentation.reset()

        XCTAssertFalse(presentation.isEditingImmersively)
        XCTAssertNil(presentation.activeImmersiveEditorID)
    }
}
