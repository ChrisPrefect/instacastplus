//
//  ICContentIntents.swift
//  Instacast
//
//  Podcast and episode App Entities for current Shortcuts/Siri releases. The
//  iOS 27 AppSchema-specific mapping is tracked in CLAUDE.md and must wait for
//  the matching SDK.
//

import AppIntents
import Foundation

// MARK: - Podcast Entity

struct ICPodcastEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast")
    static let defaultQuery = ICPodcastEntityQuery()

    let id: String
    let title: String
    let subtitle: String?
    let imageURL: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource("\(title)"),
            subtitle: subtitle.map { LocalizedStringResource("\($0)") }
        )
    }

    init(id: String, title: String, subtitle: String?, imageURL: String?) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
    }

    init(_ info: ICPodcastInfo) {
        self.init(id: info.id, title: info.title, subtitle: info.subtitle, imageURL: info.imageURL)
    }
}

struct ICPodcastEntityQuery: EntityStringQuery {
    func entities(for identifiers: [ICPodcastEntity.ID]) async throws -> [ICPodcastEntity] {
        await ICIntentBridge.podcastInfos(forIDs: identifiers).map(ICPodcastEntity.init)
    }

    func entities(matching string: String) async throws -> [ICPodcastEntity] {
        await ICIntentBridge.matchingPodcasts(string).map(ICPodcastEntity.init)
    }

    func suggestedEntities() async throws -> [ICPodcastEntity] {
        await ICIntentBridge.subscribedPodcasts().map(ICPodcastEntity.init)
    }
}

// MARK: - Episode Entity

struct ICEpisodeEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode")
    static let defaultQuery = ICEpisodeEntityQuery()

    let id: String
    let title: String
    let podcast: String?
    let imageURL: String?
    let duration: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource("\(title)"),
            subtitle: podcast.map { LocalizedStringResource("\($0)") }
        )
    }

    init(id: String, title: String, podcast: String?, imageURL: String?, duration: Int) {
        self.id = id
        self.title = title
        self.podcast = podcast
        self.imageURL = imageURL
        self.duration = duration
    }

    init(_ info: ICEpisodeInfo) {
        self.init(id: info.id, title: info.title, podcast: info.podcast, imageURL: info.imageURL, duration: info.duration)
    }
}

struct ICEpisodeEntityQuery: EntityStringQuery {
    func entities(for identifiers: [ICEpisodeEntity.ID]) async throws -> [ICEpisodeEntity] {
        await ICIntentBridge.episodeInfos(forIDs: identifiers).map(ICEpisodeEntity.init)
    }

    func entities(matching string: String) async throws -> [ICEpisodeEntity] {
        await ICIntentBridge.matchingEpisodes(string).map(ICEpisodeEntity.init)
    }

    func suggestedEntities() async throws -> [ICEpisodeEntity] {
        await ICIntentBridge.recentEpisodes().map(ICEpisodeEntity.init)
    }
}

// MARK: - Playback Intents

struct ICPlayPodcastIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Podcast"
    static let description = IntentDescription("Play the newest unplayed episode of a podcast.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Podcast")
    var podcast: ICPodcastEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$podcast)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let episode = await ICIntentBridge.playNewestEpisode(ofPodcastID: podcast.id)
        if let episode {
            return .result(dialog: ICLocalizedIntentDialog("Playing “%@”.", episode.title))
        }
        return .result(dialog: ICLocalizedIntentDialog("No playable episode found."))
    }
}

struct ICPlayEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Episode"
    static let description = IntentDescription("Play a specific episode.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Episode")
    var episode: ICEpisodeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$episode)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let played = await ICIntentBridge.playEpisode(withID: episode.id)
        if let played {
            return .result(dialog: ICLocalizedIntentDialog("Playing “%@”.", played.title))
        }
        return .result(dialog: ICLocalizedIntentDialog("Episode not found."))
    }
}
