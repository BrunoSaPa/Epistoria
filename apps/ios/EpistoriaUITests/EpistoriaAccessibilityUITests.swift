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

        XCTAssertTrue(app.buttons["onboarding.create"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.restore"].exists)
        try app.performAccessibilityAudit()
    }
}
