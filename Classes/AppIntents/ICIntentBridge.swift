//
//  ICIntentBridge.swift
//  Instacast
//
//  Central bridge between the Swift App Intents (Siri / Shortcuts / Apple
//  Intelligence) and the app's Objective-C singletons.
//
//  IMPORTANT: every access to Core Data (`DMANAGER.objectContext` is
//  `NSMainQueueConcurrencyType`), `PlaybackManager` and `AudioSession` MUST run
//  on the main thread. App Intent `perform()` and `EntityQuery` callbacks run on
//  a background executor, therefore this whole bridge is `@MainActor`. No
//  `NSManagedObject` ever leaves this actor — callers pass/receive only Sendable
//  value types (String ids, the small `IC*Info` DTOs, Bool, etc.).
//

import Foundation
import CoreData
import UIKit

// MARK: - Sendable DTOs (so managed objects never cross an actor boundary)

struct ICPodcastInfo: Sendable, Equatable, Identifiable {
    let id: String          // feed.sourceURL.absoluteString
    let uid: String?        // feed.uid (for deep-link open)
    let title: String
    let subtitle: String?
    let imageURL: String?
}

struct ICEpisodeInfo: Sendable, Equatable, Identifiable {
    let id: String          // episode.objectHash
    let feedURL: String
    let guid: String
    let title: String
    let podcast: String?
    let imageURL: String?
    let duration: Int       // seconds
}

struct ICListInfo: Sendable, Equatable, Identifiable {
    let id: String          // list.uid
    let name: String
    let count: Int
}

@MainActor
enum ICIntentBridge {

    /// `+[PlaybackManager playbackManager]` is imported by Swift as an initializer;
    /// `PlaybackManager()` returns the shared instance (it does not allocate a new one).
    private static var pm: PlaybackManager { PlaybackManager() }

    // MARK: - Transport

    /// Resume playback. If nothing is loaded, continue the most recently played episode.
    static func play() {
        if pm.playingEpisode != nil {
            if pm.isPaused { pm.play() }
        } else if let episode = mostRecentlyPlayedEpisode() {
            if let session = AudioSession.shared() {
                session.playEpisode(episode, queueUpCurrent: false, at: 0, autostart: true, preservingPlaybackSource: session.episode?.isEqual(episode) == true)
            }
        }
    }

    static func pause() {
        if !pm.isPaused { pm.pause() }
    }

    /// Toggle play/pause; if nothing is loaded, continue the most recently played episode.
    static func playPause() {
        if pm.playingEpisode != nil {
            pm.playPause()
        } else if let episode = mostRecentlyPlayedEpisode() {
            if let session = AudioSession.shared() {
                session.playEpisode(episode, queueUpCurrent: false, at: 0, autostart: true, preservingPlaybackSource: session.episode?.isEqual(episode) == true)
            }
        }
    }

    static func skipForward()  { pm.seekForward() }
    static func skipBackward() { pm.seekBackward() }

    /// Next episode — mirrors the widget behaviour (`nextPlayableEpisode`).
    static func nextEpisode() {
        if let session = AudioSession.shared(), let next = session.nextPlayableEpisode() {
            session.playEpisode(next, queueUpCurrent: false, at: 0, autostart: true, preservingPlaybackSource: true)
        }
    }

    /// Previous episode in the current playlist (wraps, handled inside ObjC).
    static func previousEpisode() { pm.previousTrack() }

    static func nextChapter()     { pm.nextChapter() }
    static func previousChapter() { pm.previousChapter() }

    // MARK: - Speed

    /// Set an arbitrary playback rate (0.5–3.0).
    static func setSpeed(_ rate: Double) {
        let clamped = min(max(rate, 0.5), 3.0)
        pm.playbackRate = Float(clamped)
    }

    /// Cycle to the next user-enabled speed preset (same logic as the player button / widget).
    static func cycleSpeed() {
        pm.speedControl = PlayerSpeedButton.nextEnabledSpeed(after: pm.speedControl)
    }

    /// The current playback rate as a multiplier (for spoken feedback).
    static func currentSpeed() -> Double {
        let rate = Double(pm.playbackRate)
        return rate > 0 ? rate : 1.0
    }

    // MARK: - Sleep timer

    static func setSleepTimer(minutes: Int) {
        let seconds = max(1, minutes) * 60
        AudioSession.shared()?.setTimerWithDuration(TimeInterval(seconds))
    }

    static func cancelSleepTimer() {
        AudioSession.shared()?.timerValue = PlaybackStopTimeNoValue
    }

    static var sleepTimerActive: Bool {
        (AudioSession.shared()?.timerRemainingTime ?? 0) > 0
    }

    // MARK: - Episode flags (current episode)

    @discardableResult
    static func markCurrentPlayed() -> String? {
        guard let episode = pm.playingEpisode else { return nil }
        let title = episode.title
        DatabaseManager.shared()?.mark(episode, asConsumed: true)
        DatabaseManager.shared()?.save()
        return title
    }

    /// Toggle the favorite/star flag of the current episode. Returns the new state, or nil if nothing playing.
    @discardableResult
    static func toggleStarCurrent() -> Bool? {
        guard let episode = pm.playingEpisode else { return nil }
        let newValue = !episode.starred
        DatabaseManager.shared()?.mark(episode, asStarred: newValue)
        DatabaseManager.shared()?.save()
        return newValue
    }

    /// Title of the currently playing episode (for spoken feedback), if any.
    static func nowPlayingTitle() -> String? {
        pm.playingEpisode?.title
    }

    // MARK: - Play by id (entity-parameterized intents)

    /// Play the newest unplayed (falling back to newest) episode of a subscribed podcast.
    @discardableResult
    static func playNewestEpisode(ofPodcastID id: String) -> ICEpisodeInfo? {
        guard let feed = feed(forID: id) else { return nil }
        guard let episode = newestUnplayedEpisode(of: feed) ?? newestEpisode(of: feed) else { return nil }
        AudioSession.shared()?.playEpisode(episode)
        return episodeInfo(from: episode)
    }

    @discardableResult
    static func playEpisode(withID id: String) -> ICEpisodeInfo? {
        guard let episode = DatabaseManager.shared()?.episode(withObjectHash: id) else { return nil }
        AudioSession.shared()?.playEpisode(episode)
        return episodeInfo(from: episode)
    }

    @discardableResult
    static func playList(withID id: String) -> ICEpisodeInfo? {
        guard let list = list(forID: id),
              let first = list.sortedEpisodes?.first as? CDEpisode else { return nil }
        AudioSession.shared()?.playEpisode(first)
        return episodeInfo(from: first)
    }

    /// Newest episode of a podcast (used by the "latest episode" intent).
    static func latestEpisode(ofPodcastID id: String) -> ICEpisodeInfo? {
        guard let feed = feed(forID: id), let episode = newestEpisode(of: feed) else { return nil }
        return episodeInfo(from: episode)
    }

    // MARK: - Subscriptions

    static func subscribe(url: URL) {
        guard let options = ICSubscribeOptions(rawValue: 0) else { return }
        SubscriptionManager.shared()?.subscribeFeed(with: url, options: options) { _, _ in }
    }

    static func refreshAll() {
        SubscriptionManager.shared()?.refreshAllFeedsForce(false)
    }

    // MARK: - Open (deep links handled by the scene's URL router)

    static func open(url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: - Listing (Sendable DTOs for entity queries)

    static func subscribedPodcasts() -> [ICPodcastInfo] {
        guard let context = DatabaseManager.shared()?.objectContext else { return [] }
        let request = NSFetchRequest<CDFeed>(entityName: "Feed")
        request.predicate = NSPredicate(format: "subscribed == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "rank", ascending: true)]
        let feeds = (try? context.fetch(request)) ?? []
        return feeds.compactMap { podcastInfo(from: $0) }
    }

    static func podcastInfos(forIDs ids: [String]) -> [ICPodcastInfo] {
        ids.compactMap { id in feed(forID: id).flatMap { podcastInfo(from: $0) } }
    }

    static func matchingPodcasts(_ query: String) -> [ICPodcastInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return subscribedPodcasts() }
        return subscribedPodcasts().filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    static func recentEpisodes(limit: Int = 40) -> [ICEpisodeInfo] {
        guard let context = DatabaseManager.shared()?.objectContext else { return [] }
        let request = NSFetchRequest<CDEpisode>(entityName: "Episode")
        request.predicate = NSPredicate(format: "feed.subscribed == YES AND archived == NO AND consumed == NO")
        request.sortDescriptors = [NSSortDescriptor(key: "pubDate", ascending: false)]
        request.fetchLimit = limit
        let episodes = (try? context.fetch(request)) ?? []
        return episodes.compactMap { episodeInfo(from: $0) }
    }

    static func episodeInfos(forIDs ids: [String]) -> [ICEpisodeInfo] {
        ids.compactMap { id in
            guard let episode = DatabaseManager.shared()?.episode(withObjectHash: id) else { return nil }
            return episodeInfo(from: episode)
        }
    }

    static func matchingEpisodes(_ query: String) -> [ICEpisodeInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recentEpisodes() }
        guard let context = DatabaseManager.shared()?.objectContext else { return [] }
        let request = NSFetchRequest<CDEpisode>(entityName: "Episode")
        request.predicate = NSPredicate(format: "feed.subscribed == YES AND archived == NO AND title CONTAINS[cd] %@", trimmed)
        request.sortDescriptors = [NSSortDescriptor(key: "pubDate", ascending: false)]
        request.fetchLimit = 40
        let episodes = (try? context.fetch(request)) ?? []
        return episodes.compactMap { episodeInfo(from: $0) }
    }

    static func allLists() -> [ICListInfo] {
        guard let lists = DatabaseManager.shared()?.lists as? [CDList] else { return [] }
        return lists.compactMap { listInfo(from: $0) }
    }

    static func listInfos(forIDs ids: [String]) -> [ICListInfo] {
        let all = allLists()
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    static func matchingLists(_ query: String) -> [ICListInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allLists() }
        return allLists().filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    // MARK: - Private helpers (managed objects stay here)

    private static func feed(forID id: String) -> CDFeed? {
        guard let url = URL(string: id) else { return nil }
        return DatabaseManager.shared()?.feed(withSourceURL: url)
    }

    private static func list(forID id: String) -> CDList? {
        guard let lists = DatabaseManager.shared()?.lists as? [CDList] else { return nil }
        return lists.first { $0.uid == id }
    }

    private static func mostRecentlyPlayedEpisode() -> CDEpisode? {
        guard let context = DatabaseManager.shared()?.objectContext else { return nil }
        let request = NSFetchRequest<CDEpisode>(entityName: "Episode")
        request.predicate = NSPredicate(format: "feed.subscribed == YES AND lastPlayed != nil")
        request.sortDescriptors = [NSSortDescriptor(key: "lastPlayed", ascending: false)]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private static func newestUnplayedEpisode(of feed: CDFeed) -> CDEpisode? {
        fetchFirstEpisode(predicate: NSPredicate(format: "feed == %@ AND consumed == NO AND archived == NO", feed))
    }

    private static func newestEpisode(of feed: CDFeed) -> CDEpisode? {
        fetchFirstEpisode(predicate: NSPredicate(format: "feed == %@ AND archived == NO", feed))
    }

    private static func fetchFirstEpisode(predicate: NSPredicate) -> CDEpisode? {
        guard let context = DatabaseManager.shared()?.objectContext else { return nil }
        let request = NSFetchRequest<CDEpisode>(entityName: "Episode")
        request.predicate = predicate
        request.sortDescriptors = [NSSortDescriptor(key: "pubDate", ascending: false)]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private static func podcastInfo(from feed: CDFeed) -> ICPodcastInfo? {
        guard let url = feed.sourceURL else { return nil }
        let title = feed.displayTitle ?? feed.title ?? ""
        return ICPodcastInfo(id: url.absoluteString,
                             uid: feed.uid,
                             title: title,
                             subtitle: feed.author,
                             imageURL: feed.imageURL?.absoluteString)
    }

    private static func episodeInfo(from episode: CDEpisode) -> ICEpisodeInfo? {
        guard let hash = episode.objectHash,
              let feedURL = episode.feed?.sourceURL?.absoluteString,
              let guid = episode.guid else { return nil }
        let image = episode.imageURL ?? episode.feed?.imageURL
        return ICEpisodeInfo(id: hash,
                             feedURL: feedURL,
                             guid: guid,
                             title: episode.title ?? "",
                             podcast: episode.feed?.displayTitle ?? episode.feed?.title,
                             imageURL: image?.absoluteString,
                             duration: Int(episode.duration))
    }

    private static func listInfo(from list: CDList) -> ICListInfo? {
        guard let uid = list.uid else { return nil }
        return ICListInfo(id: uid, name: list.name ?? "", count: Int(list.numberOfEpisodes))
    }
}
