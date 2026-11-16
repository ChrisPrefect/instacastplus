import XCTest

final class NativeScrollTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.iteconomy.instacastplus")

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func selectList(_ title: String) {
        let sidebar = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), app.debugDescription)
        sidebar.tap()
        let list = app.staticTexts[title].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), app.debugDescription)
        list.tap()
    }

    func testMarkSelectedStartedEpisodesAsUnplayed() {
        continueAfterFailure = false
        app.activate()
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if prompt.waitForExistence(timeout: 2) {
            prompt.buttons.firstMatch.tap()
        }
        let gotIt = app.buttons["Verstanden!"]
        if gotIt.waitForExistence(timeout: 4) { gotIt.tap() }

        selectList("angespielt")
        let first = app.staticTexts["Testfolge 1"]
        let second = app.staticTexts["Testfolge 2"]
        let control = app.staticTexts["Testfolge 3"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(second.exists)
        XCTAssertTrue(control.exists)
        capture("Started before marking")

        let edit = app.buttons["Bearbeiten"].firstMatch
        edit.tap()
        first.tap()
        second.tap()
        edit.tap()
        let unplayed = app.buttons["Als ungespielt markieren"].firstMatch
        XCTAssertTrue(unplayed.waitForExistence(timeout: 5), app.debugDescription)
        capture("Mark as unplayed action")
        unplayed.tap()

        let rowsRemoved = first.waitForNonExistence(timeout: 6)
        capture("Started after marking")
        XCTAssertTrue(rowsRemoved, "The first selected episode still appears in Started")
        XCTAssertFalse(second.exists, "The second selected episode still appears in Started")
        XCTAssertTrue(control.exists, "The unselected episode disappeared")

        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        if !app.navigationBars["angespielt"].exists {
            selectList("angespielt")
        }
        XCTAssertTrue(control.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(first.exists)
        XCTAssertFalse(second.exists)
        capture("Started after restart")

        selectList("ungespielt")
        XCTAssertTrue(first.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(second.exists)
        capture("Unplayed after restart")
    }
}
