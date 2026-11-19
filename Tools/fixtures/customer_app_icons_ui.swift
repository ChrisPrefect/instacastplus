import XCTest

final class NativeScrollTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.iteconomy.instacastplus")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func capture(_ name: String, home: Bool = false) {
        let attachment = XCTAttachment(screenshot: home ? springboard.screenshot() : app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismissStartup() {
        for title in ["Don’t Allow", "Don't Allow", "Nicht erlauben"] {
            let button = springboard.alerts.buttons[title]
            if button.waitForExistence(timeout: 1) { button.tap(); break }
        }
        // First launch shows onboarding and then the changelog, both with this button.
        for _ in 0..<3 {
            let gotIt = app.buttons["Got it!"]
            if gotIt.waitForExistence(timeout: 3) { gotIt.tap() }
            else { break }
        }
        let hint = app.staticTexts["to add podcasts, search the podcast directory"]
        if hint.waitForExistence(timeout: 3) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func openAppearance() {
        if app.navigationBars["Appearance"].exists { return }
        let sidebar = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), app.debugDescription)
        sidebar.tap()
        let settings = app.descendants(matching: .any)["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        settings.tap()
        let appearance = app.staticTexts["Appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 8), app.debugDescription)
        appearance.tap()
    }

    private func icon(_ name: String) -> XCUIElement {
        for _ in 0..<8 {
            let icon = app.buttons[name].firstMatch
            if icon.exists && icon.isHittable { return icon }
            let collection = app.collectionViews.firstMatch
            if collection.exists && collection.isHittable { collection.swipeLeft() }
            else { app.tables.firstMatch.swipeUp() }
        }
        return app.buttons[name].firstMatch
    }

    func testCustomerIcons() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        dismissStartup()
        openAppearance()
        for name in ["Creme", "Espresso", "Glow"] {
            let choice = icon(name)
            XCTAssertTrue(choice.exists && choice.isHittable, app.debugDescription)
            capture(name + " preview")
            choice.tap()
            let confirmation = springboard.alerts.firstMatch
            XCTAssertTrue(confirmation.waitForExistence(timeout: 8), "No successful iOS icon confirmation for " + name)
            capture(name + " iOS confirmation")
            confirmation.buttons.firstMatch.tap()
            XCTAssertTrue(choice.isSelected, "UIApplication did not select " + name)
            XCUIDevice.shared.press(.home)
            let homeIcon = springboard.icons["InstacastPlus"].firstMatch
            for _ in 0..<3 {
                if homeIcon.exists && homeIcon.isHittable { break }
                springboard.swipeLeft()
            }
            XCTAssertTrue(homeIcon.exists && homeIcon.isHittable, springboard.debugDescription)
            capture(name + " Home Screen", home: true)
            app.terminate()
            app.launch()
            openAppearance()
            let restored = icon(name)
            XCTAssertTrue(restored.isSelected, "Icon selection did not survive relaunch: " + name)
            capture(name + " selected after relaunch")
        }
    }
}
