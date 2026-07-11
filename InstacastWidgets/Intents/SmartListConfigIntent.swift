import AppIntents
import WidgetKit

struct SmartListConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "List"
    static let description = IntentDescription("Choose which list to display.")

    @Parameter(title: "List")
    var list: ListEntity?

    // Only applies when a podcast is selected (lists carry their own filter). Default "all" so a
    // freshly added podcast widget always shows its latest episodes.
    @Parameter(title: "Filter", default: .all)
    var filter: SmartListPodcastFilter

    @Parameter(title: "Compact", default: true)
    var compact: Bool

    @Parameter(title: "Order", default: .columns)
    var order: SmartListOrder
}

/// Filter for a podcast source — mirrors the episode-list filters.
enum SmartListPodcastFilter: String, AppEnum {
    case all
    case unplayed
    case downloaded
    case started
    case favorites

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Filter"
    static let caseDisplayRepresentations: [SmartListPodcastFilter: DisplayRepresentation] = [
        .all: DisplayRepresentation(title: "All", image: .init(systemName: "tray.full")),
        .unplayed: DisplayRepresentation(title: "Unplayed", image: .init(systemName: "circle")),
        .downloaded: DisplayRepresentation(title: "Downloaded", image: .init(systemName: "arrow.down.circle.fill")),
        .started: DisplayRepresentation(title: "Started", image: .init(systemName: "pause.circle.fill")),
        .favorites: DisplayRepresentation(title: "Favorites", image: .init(systemName: "star.fill"))
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

    /// SF Symbol per list type / podcast, derived from the id — shown in the config picker.
    static func iconName(for id: String) -> String {
        if id.hasPrefix("feed:") || id.hasPrefix("feed.") { return "mic.fill" }
        switch id {
        case "default.unplayed":        return "circle"
        case "default.favorites":       return "star.fill"
        case "default.downloaded":      return "arrow.down.circle.fill"
        case "default.started",
             "default.partiallyplayed": return "pause.circle.fill"
        case "default.recentlyplayed":  return "clock.arrow.circlepath"
        case "default.mostrecent":      return "sparkles"
        case "default.video":           return "video.fill"
        default:                        return "list.bullet"
        }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: Self.iconName(for: id)))
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
