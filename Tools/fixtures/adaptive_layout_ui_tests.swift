import XCTest

// Native simulator gestures complement the production-handler geometry probe.
// The command directory is supplied by the test runner through the fixture copy.
final class NativeScrollTests: XCTestCase {
    func testAdaptiveLayout() throws {
        let directory = URL(fileURLWithPath: "ADAPTIVE_LAYOUT_COMMAND_DIRECTORY")
        let app = XCUIApplication(bundleIdentifier: "com.iteconomy.instacastplus")
        let spring = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.activate()
        // Fresh test simulators have no notification decision. Decline only
        // this app's prompt; no customer permissions or data are modified.
        for title in ["Nicht erlauben", "Don’t Allow", "Don't Allow"] {
            let button = spring.alerts.buttons[title].firstMatch
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }
        let understood = app.buttons["Verstanden!"].firstMatch
        if understood.waitForExistence(timeout: 3) { understood.tap() }
        try Data("ready".utf8).write(to: directory.appendingPathComponent("native-ready"))
        let deadline = Date().addingTimeInterval(1800)
        var lastID = ""
        while Date() < deadline {
            let commandURL = directory.appendingPathComponent("native-command.json")
            guard let data = try? Data(contentsOf: commandURL),
                  let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = command["id"] as? String, id != lastID else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            lastID = id
            let action = command["action"] as? String ?? "status"
            var controlChecks: [[String: Any]] = []
            if action == "finish" { return }
            if action == "verifyControls", let labels = command["labels"] as? [String] {
                var targets: [XCUIElement] = []
                for label in labels {
                    let matches = app.buttons.matching(identifier: label)
                    XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
                    // Adaptive navigation also exposes the original offscreen
                    // bar item; require its actual onscreen counterpart.
                    let visible = matches.allElementsBoundByIndex.filter { $0.isHittable }
                    XCTAssertEqual(visible.count, 1, "Expected one reachable control: \(label)")
                    guard let target = visible.first else { continue }
                    for other in targets {
                        XCTAssertFalse(target.frame.intersects(other.frame), "Overlapping controls: \(label) / \(other.label)")
                    }
                    targets.append(target)
                    controlChecks.append(["label": label, "hittable": target.isHittable,
                        "frame": [target.frame.minX, target.frame.minY, target.frame.width, target.frame.height]])
                }
            }
            if action == "activate" { app.activate() }
            if action == "orientation" {
                switch command["value"] as? String {
                case "landscapeLeft": XCUIDevice.shared.orientation = .landscapeLeft
                case "landscapeRight": XCUIDevice.shared.orientation = .landscapeRight
                default: XCUIDevice.shared.orientation = .portrait
                }
            }
            if action == "tap", let label = command["label"] as? String {
                let target = app.buttons[label].firstMatch
                XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
                target.tap()
            }
            if action == "systemTap", let label = command["label"] as? String {
                let target = spring.buttons[label].firstMatch
                XCTAssertTrue(target.waitForExistence(timeout: 10), spring.debugDescription)
                target.tap()
            }
            if action == "systemHold", let label = command["label"] as? String {
                let target = spring.buttons[label].firstMatch
                XCTAssertTrue(target.waitForExistence(timeout: 10), spring.debugDescription)
                target.press(forDuration: 1.2)
            }
            if action == "coordinate", let values = command["point"] as? [Double] {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: values[0], dy: values[1])).tap()
            }
            if action == "drag", let from = command["from"] as? [Double], let to = command["to"] as? [Double] {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: from[0], dy: from[1]))
                    .press(forDuration: 0.2, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: to[0], dy: to[1])))
            }
            if action == "home" { XCUIDevice.shared.press(.home) }
            if action == "systemSwipe" {
                if command["direction"] as? String == "right" { spring.swipeRight() }
                else { spring.swipeLeft() }
            }
            let screenshot = XCUIScreen.main.screenshot()
            try screenshot.pngRepresentation.write(to: directory.appendingPathComponent("native-screen.png"), options: .atomic)
            let reply: [String: Any] = ["id": id, "app": app.debugDescription, "system": spring.debugDescription,
                "frame": [app.frame.minX, app.frame.minY, app.frame.width, app.frame.height], "controlChecks": controlChecks]
            try JSONSerialization.data(withJSONObject: reply).write(to: directory.appendingPathComponent("native-reply.json"), options: .atomic)
        }
    }
}
