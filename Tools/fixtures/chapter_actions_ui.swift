import XCTest

final class ChapterActionsTests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.iteconomy.instacastplus")
    let directory = URL(fileURLWithPath: "__PROBE_DIRECTORY__")

    @discardableResult func command(_ action: String = "status", _ parameters: [String: Any] = [:]) throws -> [String: Any] {
        if action == "waitReady" {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                let state = try command()
                if state["ready"] as? Bool == true && state["loading"] as? Bool == false && state["rows"] as? Int == 8 && state["episodeHash"] as? String == state["targetEpisodeHash"] as? String { return state }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw NSError(domain: "PlaybackReadyTimeout", code: 1)
        }
        let id = UUID().uuidString
        var request = parameters
        request["id"] = id
        request["action"] = action
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("reply.json")),
               let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["id"] as? String == id {
                XCTAssertNil(reply["error"], "\(reply)")
                return reply["state"] as? [String: Any] ?? [:]
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(domain: "ProbeTimeout", code: 1)
    }
    func capture(_ name: String) throws {
        try command("capture", ["name": name])
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
    func chapter(_ title: String) -> XCUIElement { app.tables.staticTexts[title].firstMatch }
    func assertStrike(_ title: String, _ expected: Bool) throws {
        let state = try command()
        let strikes = state["strikes"] as? [String: Bool] ?? [:]
        XCTAssertEqual(strikes[title], expected, "\(state)")
    }
    func press(_ title: String) { chapter(title).press(forDuration: 0.8) }
    func testMenuContainsOnlyActions() throws {
        app.activate()
        press("Main")
        try capture("menu-without-extra-text")
        let menu = try command()
        XCTAssertEqual(menu["menuTitle"] as? String, "")
        XCTAssertEqual(menu["menuMessage"] as? String, "")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
    }
    func testChapterActions() throws {
        app.activate()
        XCTAssertTrue(chapter("Intro").waitForExistence(timeout: 10))
        press("Intro")
        try capture("initial-menu")
        let skip = app.buttons["Kapitel überspringen"]
        XCTAssertTrue(skip.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["Skip-Regel erstellen"].exists, app.debugDescription)
        guard skip.exists else { return }
        skip.tap()
        try assertStrike("Intro", true)
        try assertStrike("Main", false)
        try capture("episode-only-skipped")
        try command("seek", ["time": 10])
        try command("play")
        Thread.sleep(forTimeInterval: 3)
        let time = try command("pause")["playbackTime"] as? Double ?? -1
        XCTAssertGreaterThanOrEqual(time, 24, "Skipped chapter must advance to Main")
        press("Intro")
        XCTAssertFalse(app.buttons["Kapitel überspringen"].exists)
        try assertStrike("Intro", false)
        try command("seek", ["time": 10])
        try command("play")
        Thread.sleep(forTimeInterval: 3)
        let restoredTime = try command("pause")["playbackTime"] as? Double ?? -1
        XCTAssertLessThan(restoredTime, 24)
        try command("other")
        try command("waitReady")
        try assertStrike("Intro", false)
        press("Sponsor Special")
        app.buttons["Skip-Regel erstellen"].tap()
        let nameField = app.alerts.textFields.firstMatch
        let editorOpened = nameField.waitForExistence(timeout: 3)
        XCTAssertTrue(editorOpened, app.debugDescription)
        guard editorOpened else { return }
        XCTAssertEqual(nameField.value as? String, "Sponsor Special")
        XCTAssertEqual(try command()["rule"] as? String, "")
        try assertStrike("Sponsor Special", false)
        try capture("rule-editor-prefilled")
        let selection = try command()
        XCTAssertEqual(selection["editorSelectionStart"] as? Int, 0)
        XCTAssertEqual(selection["editorSelectionLength"] as? Int, "Sponsor Special".count)
        app.alerts.buttons["Abbrechen"].tap()
        XCTAssertEqual(try command()["rule"] as? String, "")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        press("Sponsor Special")
        app.buttons["Skip-Regel erstellen"].tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        XCTAssertEqual(nameField.value as? String, "Sponsor Special")
        // Typing replaces the preselected title before the user saves the rule.
        nameField.typeText("Sponsor")
        app.alerts.buttons["Hinzufügen"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        try assertStrike("Sponsor Special", true)
        try capture("rule-created")
        let rule = try command()["rule"] as? String ?? ""
        XCTAssertEqual(rule, "Sponsor")
        press("Sponsor Special")
        XCTAssertFalse(app.buttons["Kapitel überspringen"].exists)
        try assertStrike("Sponsor Special", false)
        try command("seek", ["time": 34])
        try command("play")
        Thread.sleep(forTimeInterval: 3)
        let exceptionTime = try command("pause")["playbackTime"] as? Double ?? -1
        XCTAssertGreaterThanOrEqual(exceptionTime, 36)
        XCTAssertLessThan(exceptionTime, 48)
        try command("first")
        try command("waitReady")
        try assertStrike("Intro", false)
        try assertStrike("Sponsor Special", true)
        try command("seek", ["time": 34])
        try command("play")
        Thread.sleep(forTimeInterval: 3)
        let ruleTime = try command("pause")["playbackTime"] as? Double ?? -1
        XCTAssertGreaterThanOrEqual(ruleTime, 48)
        // Same title at a different time is a different chapter in the same episode.
        press("Intro")
        app.buttons["Kapitel überspringen"].tap()
        try assertStrike("Intro", true)
        try command("showLast")
        let last = try command()["lastStrike"] as? Bool
        XCTAssertEqual(last, false)
        try command("showFirst")
        try capture("final-skipped")
    }
}
