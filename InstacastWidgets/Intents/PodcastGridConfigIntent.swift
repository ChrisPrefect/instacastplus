import AppIntents
import WidgetKit

/// Configuration intent for the Podcast Grid Widget.
/// Lets the user pick specific podcasts to display (up to the grid limit of the chosen widget size).
/// If no feeds are selected, the widget shows the top feeds sorted by rank.
struct PodcastGridConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Abonnierte Podcasts"
    static let description = IntentDescription("Wähle welche Podcasts im Raster angezeigt werden.")

    @Parameter(title: "Podcasts")
    var feeds: [FeedEntity]?
}

// MARK: - FeedEntity

struct FeedEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Podcast"
    static let defaultQuery = FeedEntityQuery()

    var id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

// MARK: - FeedEntityQuery

struct FeedEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [FeedEntity] {
        Self.loadFeeds().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [FeedEntity] {
        let feeds = Self.loadFeeds()
        if string.isEmpty { return feeds }
        return feeds.filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [FeedEntity] {
        Self.loadFeeds()
    }

    static func loadFeeds() -> [FeedEntity] {
        guard let wFeeds = SharedContainerReader.readFeeds() else { return [] }
        return wFeeds.sorted { $0.rank < $1.rank }.map { FeedEntity(id: $0.id, title: $0.title) }
    }
}
