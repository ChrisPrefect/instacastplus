// iOS 27 audio schemas. Existing entity types remain stable for saved shortcuts.
import AppIntents
import CoreSpotlight
import Foundation
import MediaIntents
import UIKit

@available(iOS 27.0, *)
@AppEntity(schema: .audio.podcastShow)
struct ICAudioPodcastEntity: IndexedEntity, URLRepresentableEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast")
    static let defaultQuery = ICAudioPodcastQuery()
    let id: String
    var title: String
    var showDescription: String?

    static var urlRepresentation: URLRepresentation {
        "https://instacast.ch/share/podcast?url=\(.id)"
    }

    var displayRepresentation: DisplayRepresentation { .init(title: "\(title)") }

    init(id: String, title: String, showDescription: String? = nil) {
        self.id = id
        self.title = title
        self.showDescription = showDescription
    }

    init(_ info: ICPodcastInfo) {
        self.init(id: info.id, title: info.title, showDescription: info.showDescription)
    }
}

@available(iOS 27.0, *)
struct ICAudioPodcastQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ICAudioPodcastEntity] {
        await ICIntentBridge.podcastInfos(forIDs: identifiers).map(ICAudioPodcastEntity.init)
    }

    func entities(matching string: String) async throws -> [ICAudioPodcastEntity] {
        await ICIntentBridge.matchingPodcasts(string).map(ICAudioPodcastEntity.init)
    }

    func suggestedEntities() async throws -> [ICAudioPodcastEntity] {
        await ICIntentBridge.subscribedPodcasts().map(ICAudioPodcastEntity.init)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.podcastEpisode)
struct ICAudioEpisodeEntity: IndexedEntity, URLRepresentableEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode")
    static let defaultQuery = ICAudioEpisodeQuery()
    let id: String
    var title: String
    var showName: String?
    var show: ICAudioPodcastEntity?
    var releaseDate: Date?
    var duration: Double?
    @Property(title: "Feed URL") var feedURL: String
    @Property(title: "Episode GUID") var guid: String

    static var urlRepresentation: URLRepresentation {
        "https://instacast.ch/share/episode?url=\(\.$feedURL)&guid=\(\.$guid)"
    }

    var displayRepresentation: DisplayRepresentation {
        .init(title: "\(title)", subtitle: showName.map { LocalizedStringResource("\($0)") })
    }

    init(_ info: ICEpisodeInfo) {
        id = info.id
        title = info.title
        showName = info.podcast
        show = info.podcast.map { ICAudioPodcastEntity(id: info.feedURL, title: $0) }
        releaseDate = info.releaseDate
        duration = info.duration > 0 ? Double(info.duration) : nil
        feedURL = info.feedURL
        guid = info.guid
    }
}

@available(iOS 27.0, *)
struct ICAudioEpisodeQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ICAudioEpisodeEntity] {
        await ICIntentBridge.episodeInfos(forIDs: identifiers).map(ICAudioEpisodeEntity.init)
    }

    func entities(matching string: String) async throws -> [ICAudioEpisodeEntity] {
        await ICIntentBridge.matchingEpisodes(string).map(ICAudioEpisodeEntity.init)
    }

    func suggestedEntities() async throws -> [ICAudioEpisodeEntity] {
        await ICIntentBridge.recentEpisodes().map(ICAudioEpisodeEntity.init)
    }
}

@available(iOS 27.0, *)
@UnionValue
enum ICAudioEntity {
    case podcast(ICAudioPodcastEntity)
    case episode(ICAudioEpisodeEntity)
}

@available(iOS 27.0, *)
struct ICAudioSearchQuery: IntentValueQuery {
    func values(for input: AudioSearch) async throws -> [ICAudioEntity] {
        switch input.criteria {
        case .searchQuery(let query):
            let podcasts = await ICIntentBridge.matchingPodcasts(query).map { ICAudioEntity.podcast(ICAudioPodcastEntity($0)) }
            let episodes = await ICIntentBridge.matchingEpisodes(query).map { ICAudioEntity.episode(ICAudioEpisodeEntity($0)) }
            return podcasts + episodes
        case .unspecified:
            return await ICIntentBridge.recentEpisodes().map { .episode(ICAudioEpisodeEntity($0)) }
        case .url(let urls):
            return await ICIntentBridge.audioEntities(for: urls)
        @unknown default:
            return []
        }
    }
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum ICAudioPlaybackAttributes: String {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playback Mode")
    case shuffle
    case `repeat`
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "Shuffle", .repeat: "Repeat"
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum ICAudioQueueLocation: String {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Audio Queue")
    case next
    case tail
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "Play Next", .tail: "Play Last"
    ]
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct ICAudioWarmupResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation { .init(title: "Audio Queue") }
    init() {}
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct ICPlayAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Audio"
    var audioEntity: ICAudioEntity
    @Parameter(default: []) var playbackAttributes: Set<ICAudioPlaybackAttributes>
    var queueLocation: ICAudioQueueLocation?
    var warmupAudioQueueResult: ICAudioWarmupResult?

    func perform() async throws -> some IntentResult {
        guard playbackAttributes.isEmpty else { throw ICAudioIntentError.unsupportedPlaybackMode }
        try await ICIntentBridge.playAudio(audioEntity, queueLocation: queueLocation)
        return .result()
    }
}

@available(iOS 27.0, *)
enum ICAudioIntentError: Error, CustomLocalizedStringResourceConvertible {
    case episodeUnavailable
    case unsupportedPlaybackMode

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .episodeUnavailable: "No playable episode found."
        case .unsupportedPlaybackMode: "Shuffle and repeat are not supported for podcasts."
        }
    }
}

// Identifiers only: annotating/reusing a view never fetches Core Data or loads artwork.
@MainActor
@objc(ICAudioViewAnnotationBridge)
final class ICAudioViewAnnotationBridge: NSObject {
    @objc(annotatePodcastView:identifier:)
    static func annotatePodcast(view: UIView?, identifier: String?) {
        if #available(iOS 27.0, *) {
            view?.appEntityIdentifier = identifier.map {
                EntityIdentifier(for: ICAudioPodcastEntity.self, identifier: $0)
            }
        }
    }

    @objc(annotateEpisodeView:identifier:)
    static func annotateEpisode(view: UIView?, identifier: String?) {
        if #available(iOS 27.0, *) {
            view?.appEntityIdentifier = identifier.map {
                EntityIdentifier(for: ICAudioEpisodeEntity.self, identifier: $0)
            }
        }
    }
}
