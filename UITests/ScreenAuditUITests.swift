import XCTest

/// System accessibility audit (contrast, hit regions, clipping, labels, traits) for every main screen, in light and
/// dark appearance and at an accessibility text size. Dynamic Type is excluded: system bars and large-control text do
/// not scale in iOS itself, so every system button would be flagged; large text is checked on screenshots instead.
@MainActor final class ScreenAuditUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = true }

    private let glassButtons = ["Pause", "Stop", "Fade out", "Cancel", "Save", "Done"]

    private func audit(_ screen: String?, dark: Bool = false, bigText: Bool = false) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "YES"]
        if let screen { app.launchArguments += ["-demoScreen", screen] }
        if dark { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
        if bigText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] }
        app.launch()
        // Seeding and sheet presentation take several seconds; auditing mid-animation reports phantom clipping and contrast.
        let ready = screen == "boardedit" ? app.navigationBars["Edit board"] : app.buttons["220 Hz"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "screen never appeared")
        sleep(3)
        var issues: [String] = []
        try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.all.subtracting(.dynamicType)) { issue in
            // Accepted: "nearly passed" (a warning, not a failure), e.g. grouped-list captions.
            if issue.compactDescription == "Contrast nearly passed" { return true }
            // System glass buttons: the audit samples through the material; use the measured contrast instead (see Contrast.swift).
            if issue.compactDescription.hasPrefix("Contrast"), let el = issue.element, self.glassButtons.contains(el.label),
               let c = Contrast.measure(app, frame: el.frame) {
                if c >= 4.5 { return true }
                issues.append("measured contrast \(String(format: "%.1f", c)) | \(el.label)"); return true
            }
            issues.append("\(issue.auditType.rawValue) | \(issue.compactDescription) | \(issue.element?.label ?? "-") | \(issue.element?.elementType.rawValue ?? 0) \(issue.element?.frame ?? .zero)")
            return true
        }
        XCTAssertTrue(issues.isEmpty, "\(screen ?? "board") dark=\(dark) big=\(bigText)\n" + issues.joined(separator: "\n"))
    }

    func testBoardLight() throws { try audit(nil) }
    func testBoardDark() throws { try audit(nil, dark: true) }
    func testBoardBigText() throws { try audit(nil, bigText: true) }
    func testEditorLight() throws { try audit("editor") }
    func testEditorDark() throws { try audit("editor", dark: true) }
    func testEditorBigText() throws { try audit("editor", bigText: true) }
    func testSuggestionsLight() throws { try audit("suggestions") }
    func testSuggestionsDark() throws { try audit("suggestions", dark: true) }
    func testSettingsLight() throws { try audit("settings") }
    func testBoardEditLight() throws { try audit("boardedit") }
    func testBoardEditDark() throws { try audit("boardedit", dark: true) }
    func testDefaultsLight() throws { try audit("defaults") }
    func testDefaultsDark() throws { try audit("defaults", dark: true) }
    func testDefaultsBigText() throws { try audit("defaults", bigText: true) }
}
