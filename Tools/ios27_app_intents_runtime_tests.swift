import XCTest
import AppIntentsTesting

// Run against the installed Debug app on an isolated iOS 27 simulator.
// This tests the actual cross-process query bridge, including an empty library.
final class AudioSchemaRuntimeTests: XCTestCase {
    @MainActor
    func testAudioQueriesThroughAppIntents() async throws {
        let app = XCUIApplication(bundleIdentifier: "com.iteconomy.instacastplus")
        app.launch()
        let definitions = IntentDefinitions(bundleIdentifier: "com.iteconomy.instacastplus")
        for name in ["ICAudioPodcastEntity", "ICAudioEpisodeEntity"] {
            let missing = try await definitions.entities[name].entities(matching: "__instacast_nonexistent_927b84__")
            XCTAssertTrue(missing.isEmpty)
            let suggestions = try await definitions.entities[name].suggestedEntities()
            for entity in suggestions {
                let title: String = try entity.title
                XCTAssertFalse(title.isEmpty)
            }
            print("AppIntentsTesting \(name): \(suggestions.count) suggestions")
        }
    }
}
