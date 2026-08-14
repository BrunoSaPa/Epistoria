import XCTest

final class EpistoriaAccessibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingHasNamedRecoveryActionsAndPassesAutomatedAudit() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-reset-onboarding"]
        app.launch()

        XCTAssertTrue(
            app.buttons["onboarding.create"].waitForExistence(timeout: 5)
                || app.buttons["onboarding.open"].waitForExistence(timeout: 1)
        )
        XCTAssertTrue(app.buttons["onboarding.restore"].exists)
        try app.performAccessibilityAudit()
    }

    @MainActor
    func testDebugOnboardingKeepsOneNotebookAndProtectsLocalReset() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-reset-onboarding"]
        app.launch()

        XCTAssertTrue(
            app.buttons["onboarding.create"].waitForExistence(timeout: 5)
                || app.buttons["onboarding.open"].waitForExistence(timeout: 1)
        )
        XCTAssertFalse(app.buttons["Create another notebook"].exists)

        let reset = app.buttons["onboarding.development.reset"]
        if reset.exists {
            reset.tap()
            let confirmation = app.textFields["development.reset.confirmation"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
            let delete = app.buttons["development.reset.delete"]
            XCTAssertFalse(delete.isEnabled)
            confirmation.tap()
            confirmation.typeText("DELETE")
            XCTAssertTrue(delete.isEnabled)
            // UI verification must not tap Delete or alter the existing Simulator notebook.
        }
    }
}
