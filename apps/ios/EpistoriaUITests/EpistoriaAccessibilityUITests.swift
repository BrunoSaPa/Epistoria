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
            XCTAssertFalse(delete.isEnabled)
            // A real notebook remains protected until a readable archive is generated or
            // independently verified. This test must not alter the Simulator notebook.
        }
    }

    @MainActor
    func testEphemeralInitializationCanExportAndDeleteLocalNotebook() throws {
        let app = ephemeralApplication(additionalArguments: ["-reset-onboarding"])
        app.launch()

        let reset = app.buttons["onboarding.development.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 12))
        reset.tap()

        let createArchive = app.buttons["development.reset.create-readable"]
        XCTAssertTrue(createArchive.waitForExistence(timeout: 5))
        createArchive.tap()
        XCTAssertTrue(
            app.buttons["development.reset.share-readable"].waitForExistence(timeout: 20)
        )

        let saved = app.switches["development.reset.confirm-saved"]
        XCTAssertTrue(saved.exists)
        saved.tap()
        if (saved.value as? String) == "0" {
            saved.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(saved.value as? String, "1")

        let confirmation = app.textFields["development.reset.confirmation"]
        for _ in 0 ..< 3 where !confirmation.exists {
            app.swipeUp()
        }
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        confirmation.typeText("DELETE")
        XCTAssertEqual(confirmation.value as? String, "DELETE")
        let delete = app.buttons["development.reset.delete"]
        let enabled = expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: delete
        )
        wait(for: [enabled], timeout: 5)
        if app.keyboards.buttons["return"].exists {
            app.keyboards.buttons["return"].tap()
        }
        XCTAssertTrue(delete.isHittable)
        delete.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if delete.waitForExistence(timeout: 2), delete.isEnabled {
            delete.tap()
        }

        XCTAssertTrue(app.buttons["onboarding.create"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.open"].exists)
    }

    @MainActor
    func testEphemeralNotebookSmokeJourney() throws {
        let title = "UI smoke \(UUID().uuidString.prefix(8))"
        let app = ephemeralApplication()
        app.launch()

        let notebookNavigation = app.staticTexts["navigation.notebook"]
        XCTAssertTrue(notebookNavigation.waitForExistence(timeout: 12))
        notebookNavigation.tap()
        XCTAssertTrue(app.buttons["notebook.new"].waitForExistence(timeout: 5))
        app.buttons["notebook.new"].tap()
        XCTAssertTrue(app.buttons["Note"].waitForExistence(timeout: 3))
        app.buttons["Note"].tap()

        let titleField = app.textFields["notebook.new-note.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))
        titleField.tap()
        titleField.typeText(title)
        let create = app.buttons["notebook.new-note.create"]
        XCTAssertTrue(create.isEnabled)
        create.tap()

        XCTAssertTrue(app.textFields["note.title"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["note.page.1"].exists)

        let pages = app.buttons["note.tool.pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 3))
        pages.tap()
        let addPage = app.buttons["note.page-manager.add"]
        XCTAssertTrue(addPage.waitForExistence(timeout: 3))
        addPage.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["note.page-manager.page.2"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["Done"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["note.page.2"].waitForExistence(timeout: 5)
        )

        let more = app.buttons["note.tool.more"]
        more.tap()
        let exportPDF = app.descendants(matching: .any)["note.more.export-pdf"].firstMatch
        XCTAssertTrue(exportPDF.waitForExistence(timeout: 3))
        exportPDF.tap()

        let createPDF = app.buttons["note.export-pdf.create"]
        XCTAssertTrue(createPDF.waitForExistence(timeout: 5))
        createPDF.tap()
        XCTAssertTrue(app.buttons["note.export-pdf.share"].waitForExistence(timeout: 15))
        app.buttons["Done"].tap()

        more.tap()
        let photos = app.descendants(matching: .any)["note.more.image.photos"].firstMatch
        for _ in 0 ..< 3 where !photos.exists {
            app.swipeUp()
        }
        XCTAssertTrue(photos.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["note.more.image.files"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["note.more.image.paste"].firstMatch.exists)

        app.terminate()
        app.launch()
        let searchNavigation = app.staticTexts["navigation.search"]
        XCTAssertTrue(searchNavigation.waitForExistence(timeout: 12))
        searchNavigation.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 8))

        app.staticTexts["navigation.notebook"].tap()
        let note = app.staticTexts[title]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.swipeLeft()
        XCTAssertTrue(app.buttons["Trash"].waitForExistence(timeout: 3))
        app.buttons["Trash"].tap()
        XCTAssertTrue(app.buttons["Move to Trash"].waitForExistence(timeout: 3))
        app.buttons["Move to Trash"].tap()
        XCTAssertFalse(app.staticTexts[title].waitForExistence(timeout: 3))

        app.buttons["navigation.settings"].tap()
        let trashSettings = app.descendants(matching: .any)["settings.trash"]
        XCTAssertTrue(trashSettings.waitForExistence(timeout: 5))
        trashSettings.tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        let restore = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "trash.restore.")
        ).firstMatch
        XCTAssertTrue(restore.exists)
        restore.tap()
        XCTAssertFalse(app.staticTexts[title].waitForExistence(timeout: 3))
    }

    @MainActor
    private func ephemeralApplication(
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-ephemeral"] + additionalArguments
        app.launchEnvironment["EPISTORIA_UI_TEST_RUN_ID"] = UUID().uuidString
        return app
    }
}
