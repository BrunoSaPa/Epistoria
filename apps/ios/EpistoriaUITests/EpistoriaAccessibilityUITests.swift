import XCTest

final class EpistoriaAccessibilityUITests: XCTestCase {
    @MainActor
    func testPDFPanelKeepsNotebookAvailableWhileReading() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = ephemeralApplication(additionalArguments: ["-ui-testing-pdf-panel"])
        app.launch()
        XCTAssertTrue(app.buttons["today.quick-note"].waitForExistence(timeout: 15))
        app.buttons["today.quick-note"].tap()
        let page = app.descendants(matching: .any).matching(identifier: "note.page.1").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        let original = page.frame
        app.buttons["note.tool.more"].tap()
        let open = app.buttons["note.more.open-source"]
        if !open.isHittable { app.swipeUp() }
        open.tap()
        let source = app.buttons["Panel test source"]
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        source.tap()
        XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 10))
        XCTAssertEqual(page.frame.width, original.width, accuracy: 2)
        XCTAssertTrue(app.buttons["note.tool.pen"].isHittable)
        app.buttons["Next source page"].tap()
        XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 5))
        app.buttons["note.tool.pen"].tap()
        let start = page.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.25))
        let end = page.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.35))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.staticTexts["Page 2 of 3"].exists)
        app.buttons["note.tool.text"].tap()
        let text = app.textViews.matching(identifier: "Canvas text").firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText("Reading alongside my source")
        XCTAssertTrue((text.value as? String)?.contains("Reading alongside my source") == true)
        app.buttons["note.tool.pen"].tap()
        XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "PDF beside writable notebook"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["note.source.close"].tap()
        XCTAssertFalse(app.buttons["note.source.close"].exists)
        XCTAssertEqual(page.frame.width, original.width, accuracy: 2)
        XCTAssertEqual(page.frame.minY, original.minY, accuracy: 2)
        XCTAssertTrue(app.buttons["note.tool.pen"].isHittable)
    }

    @MainActor
    func testPDFPickerEmptyStateAndCancelReturnToNote() throws {
        let app = ephemeralApplication()
        app.launch()
        XCTAssertTrue(app.buttons["today.quick-note"].waitForExistence(timeout: 12))
        app.buttons["today.quick-note"].tap()
        let page = app.descendants(matching: .any).matching(identifier: "note.page.1").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        let width = page.frame.width
        app.buttons["note.tool.more"].tap()
        let open = app.buttons["note.more.open-source"]
        if !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.staticTexts["No available PDF sources. Import a PDF in Library."].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertEqual(page.frame.width, width, accuracy: 2)
        XCTAssertTrue(app.buttons["note.tool.pen"].isHittable)
    }

    @MainActor
    func testFixedPageFitAndReturnKeepContinuousCanvas() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = ephemeralApplication()
        app.launch()
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["today.quick-note"].waitForExistence(timeout: 12))
        app.buttons["today.quick-note"].tap()
        let page = app.descendants(matching: .any).matching(identifier: "note.page.1").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        let originalWidth = page.frame.width
        app.buttons["note.tool.more"].tap()
        let fit = app.buttons["note.view.fit-page"]
        XCTAssertTrue(fit.waitForExistence(timeout: 5))
        fit.tap()
        let back = app.buttons["note.return-view"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertLessThan(page.frame.width, originalWidth)
        XCTAssertLessThan(page.frame.height, app.frame.height)
        XCTAssertGreaterThanOrEqual(page.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(page.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(page.frame.minY, app.frame.minY)
        XCTAssertLessThanOrEqual(page.frame.maxY, app.frame.maxY)
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "Fixed page fits landscape viewport"
        screen.lifetime = .keepAlways
        add(screen)
        back.tap()
        XCTAssertEqual(page.frame.width, originalWidth, accuracy: 2)
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertLessThan(page.frame.width, originalWidth)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertEqual(page.frame.width, originalWidth, accuracy: 2)
        app.typeKey("0", modifierFlags: .command)
        XCTAssertLessThan(page.frame.width, originalWidth)
        let fittedWidth = page.frame.width
        app.navigationBars.buttons["Today"].tap()
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.recent-note.")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(recent.waitForExistence(timeout: 12))
        recent.tap()
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertEqual(page.frame.width, fittedWidth, accuracy: 2)
    }

    @MainActor
    func testInfiniteCanvasFitAndReturnPreserveContentAndPosition() throws {
        let app = ephemeralApplication()
        app.launch()
        XCTAssertTrue(app.buttons["today.quick-note"].waitForExistence(timeout: 12))
        app.buttons["today.quick-note"].tap()
        XCTAssertTrue(app.buttons["note.canvas-settings"].waitForExistence(timeout: 10))
        app.buttons["note.canvas-settings"].tap()
        app.buttons["Infinite canvas"].tap()
        app.buttons["note.tool.text"].tap()
        let field = app.textViews.matching(identifier: "Canvas text").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Canvas fitting fixture")
        app.buttons["note.tool.select"].tap()
        let originalFrame = field.frame
        app.buttons["note.tool.more"].tap()
        let fit = app.buttons["note.view.fit-content"]
        XCTAssertTrue(fit.waitForExistence(timeout: 5))
        fit.tap()
        let back = app.buttons["note.return-view"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(field.frame.width, originalFrame.width)
        XCTAssertEqual(field.value as? String, "Canvas fitting fixture")
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Infinite canvas fitted content with Return"
        screen.lifetime = .keepAlways
        add(screen)
        back.tap()
        XCTAssertEqual(field.frame.midX, originalFrame.midX, accuracy: 1)
        XCTAssertEqual(field.frame.midY, originalFrame.midY, accuracy: 1)
        XCTAssertEqual(field.frame.width, originalFrame.width, accuracy: 1)
        XCTAssertEqual(field.value as? String, "Canvas fitting fixture")
        app.typeKey("0", modifierFlags: [.command, .shift])
        XCTAssertFalse(back.exists, "An empty selection must not add navigation history.")
        let options = app.buttons["note.selection.options"]
        if !options.exists { app.buttons["note.tool.select"].tap() }
        options.tap()
        if !app.buttons["Rectangle"].exists { app.buttons["Boundary"].tap() }
        app.buttons["Rectangle"].tap()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: originalFrame.minX - 8, dy: originalFrame.minY - 8))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: originalFrame.maxX + 8, dy: originalFrame.maxY + 8)))
        app.typeKey("0", modifierFlags: [.command, .shift])
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(field.frame.width, originalFrame.width)
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: back)
        waitForExpectations(timeout: 5)
        // The More popover is closed: keyboard commands must belong to the editor itself.
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(field.frame.width, originalFrame.width)
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: back)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(field.frame.width, originalFrame.width, accuracy: 1)
        XCTAssertEqual(field.value as? String, "Canvas fitting fixture")
    }

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
        let archiveReady = app.buttons["development.reset.share-readable"].waitForExistence(timeout: 20)
        let archiveScreen = XCTAttachment(screenshot: app.screenshot())
        archiveScreen.name = "Initialization archive result (isolated notebook)"
        archiveScreen.lifetime = .keepAlways
        add(archiveScreen)
        XCTAssertTrue(archiveReady)

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
    func testTodayPrioritizesWritingAndExposesLearning() throws {
        let app = ephemeralApplication()
        app.launch()
        let quickNote = app.buttons["today.quick-note"]
        XCTAssertTrue(quickNote.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["today.import-pdf"].exists)
        XCTAssertTrue(app.buttons["today.learn"].exists)
        XCTAssertFalse(app.buttons["Set up"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Today — notebook-first"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        quickNote.tap()
        XCTAssertTrue(app.textFields["note.title"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testOfflineFilesIsUsableWithoutAIOrComputeNode() throws {
        let app = ephemeralApplication()
        app.launch()
        XCTAssertTrue(app.buttons["navigation.settings"].waitForExistence(timeout: 12))
        app.buttons["navigation.settings"].tap()
        let offline = app.descendants(matching: .any)["settings.offlineFiles"].firstMatch
        XCTAssertTrue(offline.waitForExistence(timeout: 5))
        offline.tap()
        XCTAssertTrue(app.staticTexts["No original files in this notebook."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["offline.download"].isEnabled)
        XCTAssertFalse(app.buttons["offline.cancel"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Offline Files — no configuration required"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testTwoObjectSelectionDeletesAndRestoresTogether() throws {
        let app = ephemeralApplication()
        app.launch()
        XCTAssertTrue(app.buttons["today.quick-note"].waitForExistence(timeout: 12))
        app.buttons["today.quick-note"].tap()
        XCTAssertTrue(app.textFields["note.title"].waitForExistence(timeout: 10))
        let messages = ["First selected object", "Second selected object"]
        for message in messages {
            app.buttons["note.tool.text"].tap()
            let field = app.textViews.matching(identifier: "Canvas text")
                .matching(NSPredicate(format: "NOT (value IN %@)", messages)).firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(message)
            app.buttons["note.tool.select"].tap()
        }
        let textObjects = app.textViews.matching(identifier: "Canvas text")
        XCTAssertEqual(textObjects.count, 2)
        let bounds = textObjects.element(boundBy: 0).frame.union(textObjects.element(boundBy: 1).frame)
        let options = app.buttons["note.selection.options"]
        if !options.exists { app.buttons["note.tool.select"].tap() }
        XCTAssertTrue(options.waitForExistence(timeout: 3))
        options.tap()
        if !app.buttons["Rectangle"].exists { app.buttons["Boundary"].tap() }
        app.buttons["Rectangle"].tap()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: bounds.minX - 8, dy: bounds.minY - 8))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: bounds.maxX + 8, dy: bounds.maxY + 8)))
        options.tap()
        let deletion = app.buttons["note.selection.delete"]
        let duplicate = app.buttons["note.selection.duplicate"]
        let move = app.buttons["note.selection.move"]
        XCTAssertTrue(move.waitForExistence(timeout: 3))
        XCTAssertTrue(move.isEnabled)
        move.tap()
        let handle = app.otherElements["note.selection.move-handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        let beforeMove = textObjects.allElementsBoundByIndex.map(\.frame)
        let dragStart = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 0.1, thenDragTo: dragStart.withOffset(CGVector(dx: 40, dy: 30)))
        let undoMove = app.buttons["note.selection.undo-move"]
        XCTAssertTrue(undoMove.waitForExistence(timeout: 5))
        for index in 0..<2 {
            XCTAssertEqual(textObjects.element(boundBy: index).frame.midX, beforeMove[index].midX + 40, accuracy: 3)
            XCTAssertEqual(textObjects.element(boundBy: index).frame.midY, beforeMove[index].midY + 30, accuracy: 3)
        }
        undoMove.tap()
        expectation(for: NSPredicate(format: "label == %@", "Redo move"), evaluatedWith: undoMove)
        waitForExpectations(timeout: 5)
        for index in 0..<2 {
            XCTAssertEqual(textObjects.element(boundBy: index).frame.midX, beforeMove[index].midX, accuracy: 3)
            XCTAssertEqual(textObjects.element(boundBy: index).frame.midY, beforeMove[index].midY, accuracy: 3)
        }
        options.tap()
        XCTAssertTrue(duplicate.waitForExistence(timeout: 3))
        XCTAssertTrue(duplicate.isEnabled)
        duplicate.tap()
        let undoDuplicate = app.buttons["note.selection.undo-duplicate"]
        XCTAssertTrue(undoDuplicate.waitForExistence(timeout: 5))
        XCTAssertEqual(textObjects.count, 4)
        undoDuplicate.tap()
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: textObjects)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(Set(textObjects.allElementsBoundByIndex.compactMap { $0.value as? String }), Set(messages))
        origin.withOffset(CGVector(dx: bounds.minX - 8, dy: bounds.minY - 8))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: bounds.maxX + 8, dy: bounds.maxY + 8)))
        options.tap()
        XCTAssertTrue(deletion.waitForExistence(timeout: 3))
        XCTAssertTrue(deletion.isEnabled)
        XCTAssertTrue(deletion.label.contains("2 items"), deletion.label)
        let selectedScreen = XCTAttachment(screenshot: app.screenshot())
        selectedScreen.name = "Two objects selected for group Trash"
        selectedScreen.lifetime = .keepAlways
        add(selectedScreen)
        deletion.tap()
        let undo = app.buttons["note.selection.undo-delete"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertEqual(textObjects.count, 0)
        undo.tap()
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: textObjects)
        waitForExpectations(timeout: 5)
        let restored = textObjects.allElementsBoundByIndex.compactMap { $0.value as? String }
        XCTAssertEqual(Set(restored), Set(messages))
        XCTAssertFalse(undo.exists)
    }

    @MainActor
    func testOpenNoteTabsSwitchCloseAndSurviveRelaunch() throws {
        let app = ephemeralApplication()
        app.launch()
        let first = "First tab \(UUID().uuidString.prefix(6))"
        let second = "Second tab \(UUID().uuidString.prefix(6))"
        XCTAssertTrue(app.staticTexts["navigation.notebook"].waitForExistence(timeout: 12))
        app.staticTexts["navigation.notebook"].tap()
        for title in [first, second] {
            XCTAssertTrue(app.buttons["notebook.new"].waitForExistence(timeout: 5))
            app.buttons["notebook.new"].tap()
            app.buttons["Note"].tap()
            let field = app.textFields["notebook.new-note.title"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(title)
            app.buttons["notebook.new-note.create"].tap()
            XCTAssertTrue(app.textFields["note.title"].waitForExistence(timeout: 10))
            app.navigationBars.buttons["Notebook"].tap()
        }
        app.staticTexts[second].tap()
        XCTAssertTrue(app.buttons["note.tabs.list"].waitForExistence(timeout: 10))
        app.buttons["note.tabs.list"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "note.tabs.menu.", first)).firstMatch.tap()
        let activeTitle = app.textFields["note.title"]
        XCTAssertTrue(activeTitle.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", first), evaluatedWith: activeTitle)
        waitForExpectations(timeout: 10)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Top note tabs with left writing rail"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["note.tab.close"].tap()
        XCTAssertTrue(app.textFields["note.title"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", second), evaluatedWith: app.textFields["note.title"])
        waitForExpectations(timeout: 10)
        app.navigationBars.buttons["Notebook"].tap()
        XCTAssertTrue(app.staticTexts[first].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["navigation.notebook"].waitForExistence(timeout: 12))
        app.staticTexts["navigation.notebook"].tap()
        app.staticTexts[first].tap()
        XCTAssertTrue(app.buttons["note.tabs.list"].waitForExistence(timeout: 10))
        app.buttons["note.tabs.list"].tap()
        XCTAssertTrue(app.buttons[second].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "note.tabs.menu.", second)).firstMatch.tap()
        XCTAssertTrue(app.buttons["note.tabs.open"].waitForExistence(timeout: 10))
        app.buttons["note.tabs.open"].tap()
        XCTAssertTrue(app.navigationBars["Open note"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "note.tabs.pick.", first)).firstMatch.tap()
        expectation(for: NSPredicate(format: "value == %@", first), evaluatedWith: app.textFields["note.title"])
        waitForExpectations(timeout: 10)
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

        app.buttons["note.tool.pen"].tap()
        let quickOptions = app.buttons["note.quick.options"]
        XCTAssertTrue(quickOptions.waitForExistence(timeout: 5), app.buttons.debugDescription)
        let quickBlue = app.buttons["note.quick.color.BLUE"]
        if quickBlue.exists {
            quickBlue.tap()
            XCTAssertTrue(quickBlue.isSelected)
            app.buttons["note.quick.width"].tap()
            app.buttons["8 pt"].tap()
        } else {
            quickOptions.tap()
            XCTAssertTrue(app.staticTexts["Width"].waitForExistence(timeout: 3))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.15)).tap()
        }
        let railScreen = XCTAttachment(screenshot: app.screenshot())
        railScreen.name = "Left rail quick options and full-width page"
        railScreen.lifetime = .keepAlways
        add(railScreen)
        app.buttons["note.tool.select"].tap()
        app.buttons["note.tool.text"].tap()
        let canvasText = app.textViews["Canvas text"]
        XCTAssertTrue(canvasText.waitForExistence(timeout: 5))
        canvasText.tap()
        canvasText.typeText("Navigation target")
        app.buttons["note.tool.select"].tap()

        let objectFrame = canvasText.frame
        let selectionOptions = app.buttons["note.selection.options"]
        if !selectionOptions.exists { app.buttons["note.tool.select"].tap() }
        XCTAssertTrue(selectionOptions.waitForExistence(timeout: 3))
        selectionOptions.tap()
        if !app.buttons["Rectangle"].exists { app.buttons["Boundary"].tap() }
        app.buttons["Rectangle"].tap()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: objectFrame.minX - 8, dy: objectFrame.minY - 8))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: objectFrame.maxX + 8, dy: objectFrame.maxY + 8)))
        selectionOptions.tap()
        let deleteSelection = app.buttons["note.selection.delete"]
        XCTAssertTrue(deleteSelection.waitForExistence(timeout: 3))
        XCTAssertTrue(deleteSelection.isEnabled)
        deleteSelection.tap()
        let undoGroup = app.buttons["note.selection.undo-delete"]
        XCTAssertTrue(undoGroup.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["Canvas text"].exists)
        undoGroup.tap()
        XCTAssertTrue(app.textViews["Canvas text"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["Canvas text"].value as? String, "Navigation target")
        app.buttons["note.tool.select"].tap()

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

        pages.tap()
        XCTAssertTrue(app.descendants(matching: .any)["note.page-manager.page.2"].waitForExistence(timeout: 5))
        let secondPage = app.buttons["note.page-manager.page.2"]
        secondPage.press(forDuration: 1)
        app.buttons["Bookmark"].tap()
        secondPage.press(forDuration: 1)
        app.buttons["Edit page title"].tap()
        let pageTitle = app.alerts["Page title"].textFields.firstMatch
        XCTAssertTrue(pageTitle.waitForExistence(timeout: 3))
        pageTitle.typeText("Worked examples")
        app.alerts["Page title"].buttons["Save"].tap()
        app.segmentedControls.buttons["Bookmarked"].tap()
        XCTAssertTrue(secondPage.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["note.page-manager.page.1"].exists)
        XCTAssertTrue(app.staticTexts["Worked examples"].exists)
        secondPage.tap()
        XCTAssertTrue(app.descendants(matching: .any)["note.page.2"].waitForExistence(timeout: 5))
        pages.tap()
        XCTAssertTrue(app.staticTexts["Worked examples"].waitForExistence(timeout: 5))
        let pagesScreen = XCTAttachment(screenshot: app.screenshot())
        pagesScreen.name = "Page manager content previews"
        pagesScreen.lifetime = .keepAlways
        add(pagesScreen)
        app.buttons["Done"].tap()

        let more = app.buttons["note.tool.more"]
        more.tap()
        let find = app.buttons["note.more.find"]
        XCTAssertTrue(find.waitForExistence(timeout: 3))
        find.tap()
        let findField = app.searchFields.firstMatch
        XCTAssertTrue(findField.waitForExistence(timeout: 5))
        findField.tap()
        findField.typeText("missing phrase")
        XCTAssertTrue(app.descendants(matching: .any)["note.find.empty"].firstMatch.waitForExistence(timeout: 5))
        let findScreen = XCTAttachment(screenshot: app.screenshot())
        findScreen.name = "Find in Note empty result"
        findScreen.lifetime = .keepAlways
        add(findScreen)
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()

        more.tap()
        find.tap()
        XCTAssertTrue(findField.waitForExistence(timeout: 5))
        findField.tap()
        findField.typeText("Navigation target")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Navigation target")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let returnView = app.buttons["note.return-view"]
        XCTAssertTrue(returnView.waitForExistence(timeout: 5))
        returnView.tap()
        pages.tap()
        XCTAssertTrue(app.buttons["note.page-manager.page.2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["note.page-manager.page.2"].label.contains("Current page"))
        app.buttons["Done"].tap()
        XCTAssertTrue(pages.waitForExistence(timeout: 3))

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

        app.buttons["Page and paper"].tap()
        XCTAssertTrue(app.buttons["note.page-manager.page.2"].waitForExistence(timeout: 5))
        app.buttons["note.page-manager.page.2"].tap()
        app.navigationBars.buttons["Notebook"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))

        let previewRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "notebook.note.", title)).firstMatch
        expectation(for: NSPredicate(format: "value == %@", "Content preview available"), evaluatedWith: previewRow)
        waitForExpectations(timeout: 10)
        let listPreviewScreen = XCTAttachment(screenshot: app.screenshot())
        listPreviewScreen.name = "Notebook list saved-content preview"
        listPreviewScreen.lifetime = .keepAlways
        add(listPreviewScreen)

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
        note.tap()
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        pages.tap()
        let restoredPage = app.buttons["note.page-manager.page.2"]
        XCTAssertTrue(restoredPage.waitForExistence(timeout: 5))
        XCTAssertTrue(restoredPage.label.contains("Current page"))
        app.buttons["Done"].tap()
        app.navigationBars.buttons["Notebook"].tap()
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
    func testDrawAndHoldLineOffersReviewWithoutBlockingInk() throws {
        let app = ephemeralApplication(additionalArguments: ["-notebook.holdShapes", "YES"])
        app.launch()
        let notebook = app.staticTexts["navigation.notebook"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 12))
        notebook.tap()
        app.buttons["notebook.new"].tap()
        app.buttons["Note"].tap()
        let title = app.textFields["notebook.new-note.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap(); title.typeText("Synthetic held line")
        app.buttons["notebook.new-note.create"].tap()
        XCTAssertTrue(app.textFields["note.title"].waitForExistence(timeout: 8))
        let pen = app.buttons["note.tool.pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 3))
        pen.tap()
        let canvas = app.otherElements["note.page.1"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
        let keep = app.buttons["Keep ink"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Held line review"
        attachment.lifetime = .keepAlways
        add(attachment)
        keep.tap()
        XCTAssertFalse(keep.exists)
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
