import AppIntents
import WidgetKit

struct SmartListConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "List"
    static let description = IntentDescription("Choose which list to display.")

    @Parameter(title: "List")
    var list: ListEntity?

    @Parameter(title: "Compact", default: true)
    var compact: Bool
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
        let lists = Self.loadLists()
        print("[Widget] ListEntityQuery.suggestedEntities: \(lists.count) lists")
        return lists
    }

    func defaultResult() async -> ListEntity? {
        let first = Self.loadLists().first
        print("[Widget] ListEntityQuery.defaultResult: \(first?.name ?? "nil")")
        return first
    }

    static func loadLists() -> [ListEntity] {
        guard let wLists = SharedContainerReader.readLists() else {
            print("[Widget] ListEntityQuery.loadLists: readLists() returned nil")
            return []
        }
        print("[Widget] ListEntityQuery.loadLists: \(wLists.count) lists found")
        return wLists.map { ListEntity(id: $0.id, name: $0.name) }
    }
}
