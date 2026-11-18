import XCTest

final class NativeScroll: XCTestCase {
    func testRefreshDuringFingerScroll() {
        let app = XCUIApplication(bundleIdentifier: "com.iteconomy.instacastplus")
        app.activate()
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let start = table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
