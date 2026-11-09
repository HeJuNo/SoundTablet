import XCTest

/// System accessibility audit (contrast, hit regions, clipping, labels, traits) for every main screen, in light and
/// dark appearance and at an accessibility text size. Dynamic Type is excluded: system bars and large-control text do
/// not scale in iOS itself, so every system button would be flagged; large text is checked on screenshots instead.
@MainActor final class ScreenAuditUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = true }

    private func audit(_ screen: String?, dark: Bool = false, bigText: Bool = false) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "YES"]
        if let screen { app.launchArguments += ["-demoScreen", screen] }
        if dark { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
        if bigText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] }
        app.launch()
        sleep(3)  // let the demo screen and waveform settle
        var issues: [String] = []
        try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.all.subtracting(.dynamicType)) { issue in
            // Accepted: "nearly passed" (a warning, not a failure) on unlabeled system-drawn text such as grouped-list captions.
            if issue.compactDescription == "Contrast nearly passed", (issue.element?.label ?? "").isEmpty { return true }
            issues.append("\(issue.auditType.rawValue) | \(issue.compactDescription) | \(issue.element?.label ?? "-")")
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
    func testDefaultsLight() throws { try audit("defaults") }
    func testDefaultsDark() throws { try audit("defaults", dark: true) }
    func testDefaultsBigText() throws { try audit("defaults", bigText: true) }
}
