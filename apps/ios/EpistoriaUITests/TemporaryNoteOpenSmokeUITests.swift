import XCTest

final class TemporaryNoteOpenSmokeUITests: XCTestCase {
    @MainActor
    func testCreateAndOpenSyntheticNote() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing"]
        app.launch()

        let createNotebook = app.buttons["onboarding.create"]
        XCTAssertTrue(createNotebook.waitForExistence(timeout: 8))
        createNotebook.tap()

        let recorded = app.buttons["onboarding.recovery.recorded"]
        XCTAssertTrue(recorded.waitForExistence(timeout: 5))
        let recoveryWords = recoveryWordsByPosition(in: app)
        XCTAssertEqual(recoveryWords.count, 24)
        recorded.tap()

        let fields = app.textFields.allElementsBoundByIndex.filter {
            $0.identifier.hasPrefix("onboarding.recovery.word.")
        }
        XCTAssertEqual(fields.count, 3)
        for field in fields {
            let positionText = field.identifier.replacingOccurrences(
                of: "onboarding.recovery.word.",
                with: ""
            )
            let position = try XCTUnwrap(Int(positionText))
            field.tap()
            field.typeText(try XCTUnwrap(recoveryWords[position]))
        }

        let confirm = app.buttons["onboarding.recovery.confirm"]
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()

        let notebook = app.staticTexts["navigation.notebook"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 12))
        notebook.tap()

        let newNote = app.buttons["Create your first note"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 8))
        newNote.tap()
        let title = app.textFields["Note title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Synthetic canvas smoke test")
        app.buttons["Create"].tap()

        let canvas = app.descendants(matching: .any)["note.spatial-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 12))
        XCTAssertTrue(app.descendants(matching: .any)["note.tool.select"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["note.tool.pen"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["note.tool.text"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["note.tool.image"].exists)

        app.descendants(matching: .any)["note.canvas-settings"].tap()
        let grid = app.buttons["Grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 3))
        grid.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func recoveryWordsByPosition(in app: XCUIApplication) -> [Int: String] {
        var result: [Int: String] = [:]
        for element in app.descendants(matching: .any).allElementsBoundByIndex {
            let parts = element.label.split(separator: ",", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].hasPrefix("Word "),
                  let position = Int(parts[0].dropFirst("Word ".count))
            else { continue }
            result[position] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
