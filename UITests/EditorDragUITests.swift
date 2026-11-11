import XCTest

/// The waveform editor's Start handle and playhead must follow a finger drag (they used to lose it to the scroll view).
@MainActor final class EditorDragUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func openEditor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "YES"]
        app.launch()
        let tile = app.buttons["220 Hz"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        sleep(2)
        tile.press(forDuration: 1.0)
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Playhead"].waitForExistence(timeout: 10), "editor did not open")
        for _ in 0..<3 where !app.descendants(matching: .any)["Playhead"].isHittable { app.swipeUp() }  // the lower part of the waveform starts below the screen
        return app
    }

    private func seconds(_ el: XCUIElement) -> Double {
        let parts = ((el.value as? String) ?? "0:00").split(separator: ":")
        return (Double(parts[0]) ?? 0) * 60 + (Double(parts[1]) ?? 0)
    }

    private func drag(_ el: XCUIElement, dx: CGFloat, dy: CGFloat = 0.12) {  // handles are grabbed at the top, the playhead at the bottom
        let from = el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: dx, dy: 0)))
    }

    func testPlayheadFollowsDrag() {
        let app = openEditor()
        let head = app.descendants(matching: .any)["Playhead"]
        XCTAssertEqual(seconds(head), 0, accuracy: 0.05)
        drag(head, dx: 120, dy: 0.9)
        let after = app.descendants(matching: .any)["Playhead"]
        let wave = app.descendants(matching: .any)["Start point"]
        XCTAssertGreaterThan(seconds(after), 0.3, "playhead did not move with the finger; head \(head.frame) after \(after.frame) start \(wave.frame) matches \(app.descendants(matching: .any).matching(identifier: "Playhead").count)")
    }

    func testStartHandleFollowsDragAndEndHandleToo() {
        let app = openEditor()
        let start = app.descendants(matching: .any)["Start point"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        drag(start, dx: 100)
        XCTAssertGreaterThan(seconds(app.descendants(matching: .any)["Start point"]), 0.3, "Start handle did not move")
        let end = app.descendants(matching: .any)["End point"]
        let endBefore = seconds(end)
        drag(end, dx: -60)
        XCTAssertLessThan(seconds(app.descendants(matching: .any)["End point"]), endBefore - 0.1, "End handle did not move")
    }
}
