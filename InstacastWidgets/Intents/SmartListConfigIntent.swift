import AppIntents
import WidgetKit

struct SmartListConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Episode List"
    static let description = IntentDescription("Choose which episode list to display.")

    @Parameter(title: "List")
    var list: ListEntity?

    @Parameter(title: "Tap Action", default: .play)
    var tapAction: EpisodeTapAction
}

// MARK: - Tap Action Enum

enum EpisodeTapAction: String, AppEnum, Sendable {
    case play = "play"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tap Action"

    static let caseDisplayRepresentations: [EpisodeTapAction: DisplayRepresentation] = [
        .play: DisplayRepresentation(title: "Play Episode")
    ]
}

// MARK: - List Entity

struct ListEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Episode List"

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
