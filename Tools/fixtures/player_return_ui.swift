import XCTest

final class PlayerReturnTests: XCTestCase {
    func testDismissStartup() {
        let app = XCUIApplication(bundleIdentifier: "com.iteconomy.instacastplus")
        app.activate()
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if prompt.waitForExistence(timeout: 2) { prompt.buttons.firstMatch.tap() }
        let gotIt = app.buttons["Verstanden!"]
        if gotIt.waitForExistence(timeout: 4) { gotIt.tap() }
        let firstPodcastHint = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "um Podcasts hinzuzufügen")).firstMatch
        if firstPodcastHint.waitForExistence(timeout: 2) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        }
        XCTAssertFalse(prompt.exists)
        XCTAssertFalse(gotIt.exists)
        XCTAssertFalse(firstPodcastHint.exists)
    }

    func testExpandedPlayPauseTouches() {
        let app = XCUIApplication(bundleIdentifier: "com.iteconomy.instacastplus")
        app.activate()
        let play = app.buttons["player-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let center = CGPoint(x: play.frame.midX, y: play.frame.midY)
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        for offset: CGFloat in [-48, 48] {
            let initial = play.label
            origin.withOffset(CGVector(dx: center.x, dy: center.y + offset)).tap()
            let changed = NSPredicate { _, _ in initial != play.label }
            expectation(for: changed, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }
}
