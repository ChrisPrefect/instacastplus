import AppIntents
import WidgetKit

struct SmartListConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "List"
    static let description = IntentDescription("Choose which list to display.")

    @Parameter(title: "List")
    var list: ListEntity?

    // Only applies when a podcast is selected (lists carry their own filter). Default "unplayed"
    // so a freshly added podcast widget shows useful data immediately.
    @Parameter(title: "Filter", default: .unplayed)
    var filter: SmartListPodcastFilter

    @Parameter(title: "Compact", default: true)
    var compact: Bool

    @Parameter(title: "Order", default: .columns)
    var order: SmartListOrder
}

/// Filter for a podcast source — mirrors the episode-list filters.
enum SmartListPodcastFilter: String, AppEnum {
    case unplayed
    case all
    case downloaded
    case started
    case favorites

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Filter"
    static let caseDisplayRepresentations: [SmartListPodcastFilter: DisplayRepresentation] = [
        .unplayed: "Unplayed",
        .all: "Latest",
        .downloaded: "Downloaded",
        .started: "Started",
        .favorites: "Favorites"
    ]
}

enum SmartListOrder: String, AppEnum {
    case columns
    case rows

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Order"
    static let caseDisplayRepresentations: [SmartListOrder: DisplayRepresentation] = [
        .columns: "Columns",
        .rows: "Rows"
    ]
}

// MARK: - List Entity

struct ListEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"

    static let defaultQuery = ListEntityQuery()

    var id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

// MARK: - List Entity Query

struct ListEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ListEntity] {
        let lists = Self.loadLists()
        return lists.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ListEntity] {
        let lists = Self.loadLists()
        if string.isEmpty { return lists }
        return lists.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [ListEntity] {
        Self.loadLists()
    }

    static func loadLists() -> [ListEntity] {
        guard let wLists = SharedContainerReader.readLists() else { return [] }
        return wLists.map { ListEntity(id: $0.id, name: $0.name) }
    }
}
