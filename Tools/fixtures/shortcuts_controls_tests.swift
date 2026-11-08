import XCTest
import AppIntentsTesting

// Runs real intents across the system boundary. The probe only seeds real models
// and observes playback/defaults; it does not implement or replace any intent.
@MainActor
final class ShortcutsControlsTests: XCTestCase {
    let definitions = IntentDefinitions(bundleIdentifier: "com.iteconomy.instacastplus")
    var directory: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["IC_PROBE_DIRECTORY"]!) }

    func probe(_ action: String = "state", seconds: Double = 0) async throws -> [String: Any] {
        let id = UUID().uuidString
        let command: [String: Any] = ["id": id, "action": action, "seconds": seconds]
        try JSONSerialization.data(withJSONObject: command).write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("reply.json")),
               let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any], reply["id"] as? String == id {
                XCTAssertNil(reply["error"], "\(reply)")
                print("PROBE \(action): \(String(data: data, encoding: .utf8)!)")
                return try XCTUnwrap(reply["state"] as? [String: Any])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "Probe did not reply", code: 1)
    }

    func remaining() async throws -> Double {
        let result = try await definitions.intents["ICGetSleepTimerRemainingTimeIntent"].makeIntent().run()
        return try result.value
    }

    func testControlsThroughSystemIntents() async throws {
        let app = XCUIApplication(bundleIdentifier: definitions.bundleIdentifier)
        app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = ProcessInfo.processInfo.environment["IC_PROBE_LIBRARY"]!
        app.launch()
        _ = try await probe("seed")

        let empty = try await definitions.intents["ICGetCurrentEpisodeIntent"].makeIntent().run()
        let noEpisode: AnyTransientAppEntity? = try empty.value
        XCTAssertNil(noEpisode)
        let initialRemaining = try await remaining()
        XCTAssertEqual(initialRemaining, 0)

        let lists = definitions.entities["ICListEntity"]
        let found = try await lists.entities(matching: "Shortcuts Test")
        XCTAssertEqual(found.count, 1)
        let resolved = try await lists.entities(identifiers: ["shortcuts.list"])
        XCTAssertEqual(resolved, found)
        let missing = try await lists.entities(identifiers: ["shortcuts.deleted"])
        XCTAssertTrue(missing.isEmpty)
        try await definitions.intents["ICPlayListIntent"].makeIntent(list: lists.makeReference(identifier: "shortcuts.list")).run()
        var state = try await probe()
        for _ in 0..<100 where state["ready"] as? Bool != true {
            try await Task.sleep(for: .milliseconds(100))
            state = try await probe()
        }
        XCTAssertEqual(state["episode"] as? String, "shortcuts-fixture-1", "Must use list order, not newest-first")
        XCTAssertEqual(state["sourceList"] as? String, "shortcuts.list", "Continuous playback must retain its list")
        XCTAssertEqual(state["ready"] as? Bool, true)
        XCTAssertEqual(state["paused"] as? Bool, false)
        try await definitions.intents["ICPauseIntent"].makeIntent().run()
        _ = try await probe("seek", seconds: 42)
        for _ in 0..<100 {
            state = try await probe()
            if abs((state["time"] as? Double ?? 0) - 42) < 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let current = try await definitions.intents["ICGetCurrentEpisodeIntent"].makeIntent().run()
        let title: String = try current.value.title
        let podcast: String = try current.value.podcast
        let position: Double = try current.value.position
        XCTAssertEqual(title, "Fixture Episode 1")
        XCTAssertEqual(podcast, "Shortcuts Fixture Podcast")
        XCTAssertEqual(position, 42, accuracy: 1)

        try await definitions.intents["ICSetSleepTimerIntent"].makeIntent(minutes: 2).run()
        let pausedRemaining = try await remaining()
        XCTAssertEqual(pausedRemaining, 120, accuracy: 0.1)
        let automatic = definitions.intents["ICSetAutomaticSleepTimerIntent"]
        for _ in 0..<2 { try await automatic.makeIntent(enabled: true).run() }
        state = try await probe()
        XCTAssertEqual(state["automatic"] as? Bool, true)
        XCTAssertEqual(state["smart"] as? Bool, false, "Automatic and smart are different settings")
        let unchangedRemaining = try await remaining()
        XCTAssertEqual(unchangedRemaining, pausedRemaining, accuracy: 0.1)
        try await definitions.intents["ICPlayIntent"].makeIntent().run()
        try await Task.sleep(for: .seconds(2))
        let countingRemaining = try await remaining()
        XCTAssertGreaterThan(countingRemaining, 110)
        XCTAssertLessThan(countingRemaining, 120)
        try await automatic.makeIntent(enabled: false).run()
        state = try await probe()
        XCTAssertEqual(state["automatic"] as? Bool, false)
        let manualRemaining = try await remaining()
        XCTAssertGreaterThan(manualRemaining, 100, "Disabling automatic start must preserve the current timer")
        try await definitions.intents["ICCancelSleepTimerIntent"].makeIntent().run()
        let cancelledRemaining = try await remaining()
        XCTAssertEqual(cancelledRemaining, 0)
        try await automatic.makeIntent(enabled: true).run()
        let automaticRemaining = try await remaining()
        XCTAssertGreaterThan(automaticRemaining, 290)
        XCTAssertLessThanOrEqual(automaticRemaining, 300)

        try await definitions.intents["ICPauseIntent"].makeIntent().run()
        app.terminate()
        app.launch()
        state = try await probe()
        XCTAssertEqual(state["automatic"] as? Bool, true, "The setting must survive an app restart")
        try await automatic.makeIntent(enabled: false).run()
        try await definitions.intents["ICCancelSleepTimerIntent"].makeIntent().run()
        try await definitions.intents["ICPlayListIntent"].makeIntent(list: lists.makeReference(identifier: "shortcuts.list")).run()
        try await definitions.intents["ICNextEpisodeIntent"].makeIntent().run()
        state = try await probe()
        XCTAssertEqual(state["episode"] as? String, "shortcuts-fixture-2")
        do {
            try await definitions.intents["ICPlayListIntent"].makeIntent(list: lists.makeReference(identifier: "shortcuts.empty")).run()
            XCTFail("An empty list must fail rather than report playback success")
        } catch {
            print("EXPECTED EMPTY LIST ERROR: \(error)")
        }
        try await definitions.intents["ICPauseIntent"].makeIntent().run()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "App after Shortcuts controls E2E"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
