//
//  ICSharePlayCoordinator.swift
//  Instacast
//
//  Owns the SharePlay session and bridges coordinated podcast playback to Objective-C.
//

import AVFoundation
@preconcurrency import Combine
import CoreTransferable
import Foundation
import GroupActivities
import ObjectiveC
import UIKit

struct ICPodcastListeningActivity: GroupActivity, Transferable, Sendable {
    static let activityIdentifier = "com.iteconomy.instacastplus.listen-together"

    let episodeIdentifier: String
    let feedURL: URL
    let episodeGUID: String?
    let episodeTitle: String
    let podcastTitle: String
    let fallbackURL: URL
    let ownerToken: String
    let playbackFinished: Bool

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.type = .listenTogether
        metadata.title = episodeTitle
        metadata.subtitle = podcastTitle
        metadata.fallbackURL = fallbackURL
        return metadata
    }
}

@MainActor
@objcMembers
final class ICSharePlayCoordinator: NSObject, AVPlayerPlaybackCoordinatorDelegate {
    @objc(sharedCoordinator)
    static let shared = ICSharePlayCoordinator()

    static let activityDidChangeNotification = Notification.Name("ICSharePlayActivityDidChangeNotification")
    static let episodeIdentifierUserInfoKey = "episodeIdentifier"
    static let feedURLUserInfoKey = "feedURL"
    static let episodeGUIDUserInfoKey = "episodeGUID"
    static let episodeTitleUserInfoKey = "episodeTitle"
    static let podcastTitleUserInfoKey = "podcastTitle"
    static let fallbackURLUserInfoKey = "fallbackURL"
    static let ownerTokenUserInfoKey = "ownerToken"
    static let playbackFinishedUserInfoKey = "playbackFinished"
    static let locallyOriginatedUserInfoKey = "locallyOriginated"

    private var sessionObservationTask: Task<Void, Never>?
    private var activityObservationTask: Task<Void, Never>?
    private var stateObservationTask: Task<Void, Never>?
    private var activeSession: GroupSession<ICPodcastListeningActivity>?
    private var pendingLocalActivity: ICPodcastListeningActivity?
    private var pendingAppliedActivity: ICPodcastListeningActivity?
    private var lastDeliveredOwnerToken: String?
    private var ownedActivityTokens = Set<String>()
    private weak var attachedPlayer: AVPlayer?
    private var attachedEpisodeIdentifier: String?
    private weak var coordinatedPlayer: AVPlayer?
    private var coordinatedSessionIdentifier: UUID?

    private override init() {
        super.init()
    }

    deinit {
        sessionObservationTask?.cancel()
        activityObservationTask?.cancel()
        stateObservationTask?.cancel()
    }

    @objc(startObservingSessions)
    func startObservingSessions() {
        guard sessionObservationTask == nil else { return }

        sessionObservationTask = Task { @MainActor [weak self] in
            for await session in ICPodcastListeningActivity.sessions() {
                guard !Task.isCancelled else { return }
                self?.accept(session)
            }
        }
    }

    @objc(activityItemProviderForEpisodeIdentifier:feedURL:episodeGUID:episodeTitle:podcastTitle:fallbackURL:)
    func activityItemProvider(
        episodeIdentifier: String,
        feedURL: URL,
        episodeGUID: String?,
        episodeTitle: String,
        podcastTitle: String,
        fallbackURL: URL
    ) -> NSItemProvider {
        let activity = makeActivity(
            episodeIdentifier: episodeIdentifier,
            feedURL: feedURL,
            episodeGUID: episodeGUID,
            episodeTitle: episodeTitle,
            podcastTitle: podcastTitle,
            fallbackURL: fallbackURL
        )
        ownedActivityTokens.insert(activity.ownerToken)

        let provider = NSItemProvider(object: fallbackURL as NSURL)
        provider.registerGroupActivity(activity)
        return provider
    }

    @objc(attachPlayer:episodeIdentifier:)
    func attach(player: AVPlayer, episodeIdentifier: String) {
        attachedPlayer = player
        attachedEpisodeIdentifier = episodeIdentifier

        if let playerItem = player.currentItem {
            objc_setAssociatedObject(
                playerItem,
                identifierAssociationKey,
                episodeIdentifier as NSString,
                .OBJC_ASSOCIATION_COPY
            )
        }
        player.playbackCoordinator.delegate = self
        coordinateAttachedPlayerIfPossible()
    }

    @objc(publishLocalEpisodeIdentifier:feedURL:episodeGUID:episodeTitle:podcastTitle:fallbackURL:)
    func publishLocalEpisode(
        episodeIdentifier: String,
        feedURL: URL,
        episodeGUID: String?,
        episodeTitle: String,
        podcastTitle: String,
        fallbackURL: URL
    ) {
        guard let session = activeSession else { return }

        if pendingAppliedActivity?.episodeIdentifier == episodeIdentifier {
            return
        }
        if session.activity.episodeIdentifier == episodeIdentifier,
           !session.activity.playbackFinished {
            return
        }

        let activity = makeActivity(
            episodeIdentifier: episodeIdentifier,
            feedURL: feedURL,
            episodeGUID: episodeGUID,
            episodeTitle: episodeTitle,
            podcastTitle: podcastTitle,
            fallbackURL: fallbackURL
        )
        ownedActivityTokens.insert(activity.ownerToken)

        if case .joined = session.state {
            session.activity = activity
        } else {
            pendingLocalActivity = activity
        }
    }

    @objc(publishPlaybackFinishedForEpisodeIdentifier:)
    func publishPlaybackFinished(episodeIdentifier: String) {
        guard let session = activeSession,
              session.activity.episodeIdentifier == episodeIdentifier,
              !session.activity.playbackFinished,
              ownedActivityTokens.contains(session.activity.ownerToken) else {
            return
        }

        let currentActivity = session.activity
        let activity = makeActivity(
            episodeIdentifier: currentActivity.episodeIdentifier,
            feedURL: currentActivity.feedURL,
            episodeGUID: currentActivity.episodeGUID,
            episodeTitle: currentActivity.episodeTitle,
            podcastTitle: currentActivity.podcastTitle,
            fallbackURL: currentActivity.fallbackURL,
            playbackFinished: true
        )
        ownedActivityTokens.insert(activity.ownerToken)

        if case .joined = session.state {
            session.activity = activity
        } else {
            pendingLocalActivity = activity
        }
    }

    @objc(acknowledgeAppliedActivityOwnerToken:)
    func acknowledgeAppliedActivity(ownerToken: String) {
        guard pendingAppliedActivity?.ownerToken == ownerToken else { return }
        pendingAppliedActivity = nil
    }

    @objc(redeliverPendingAppliedActivity)
    func redeliverPendingAppliedActivity() {
        guard let pendingAppliedActivity else { return }
        postActivityChange(pendingAppliedActivity)
    }

    @objc(isCurrentActivityOwnerToken:)
    func isCurrentActivity(ownerToken: String) -> Bool {
        activeSession?.activity.ownerToken == ownerToken
    }

    @objc(hasActiveSession)
    func hasActiveSession() -> Bool {
        activeSession != nil
    }

    @objc(canAdvanceAutomatically)
    func canAdvanceAutomatically() -> Bool {
        guard let session = activeSession else { return true }
        return ownedActivityTokens.contains(session.activity.ownerToken)
    }

    @objc(leaveSessionForLocalPlayback)
    func leaveSessionForLocalPlayback() {
        guard let session = activeSession else { return }
        session.leave()
        clearActiveSession(sessionIdentifier: session.id)
    }

    nonisolated func playbackCoordinator(
        _ coordinator: AVPlayerPlaybackCoordinator,
        identifierFor playerItem: AVPlayerItem
    ) -> String {
        (objc_getAssociatedObject(playerItem, identifierAssociationKey) as! NSString) as String
    }

    private nonisolated var identifierAssociationKey: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
    }

    private func makeActivity(
        episodeIdentifier: String,
        feedURL: URL,
        episodeGUID: String?,
        episodeTitle: String,
        podcastTitle: String,
        fallbackURL: URL,
        playbackFinished: Bool = false
    ) -> ICPodcastListeningActivity {
        ICPodcastListeningActivity(
            episodeIdentifier: episodeIdentifier,
            feedURL: feedURL,
            episodeGUID: episodeGUID,
            episodeTitle: episodeTitle,
            podcastTitle: podcastTitle,
            fallbackURL: fallbackURL,
            ownerToken: UUID().uuidString,
            playbackFinished: playbackFinished
        )
    }

    private func accept(_ session: GroupSession<ICPodcastListeningActivity>) {
        if let activeSession, activeSession.id != session.id {
            activeSession.leave()
        }

        activityObservationTask?.cancel()
        stateObservationTask?.cancel()
        activeSession = session
        pendingLocalActivity = nil
        pendingAppliedActivity = nil
        lastDeliveredOwnerToken = nil
        coordinatedPlayer = nil
        coordinatedSessionIdentifier = nil

        activityObservationTask = Task { @MainActor [weak self] in
            for await activity in session.$activity.values {
                guard !Task.isCancelled else { return }
                self?.handleActivity(activity, sessionIdentifier: session.id)
            }
        }
        stateObservationTask = Task { @MainActor [weak self] in
            for await state in session.$state.values {
                guard !Task.isCancelled else { return }
                self?.handleState(state, sessionIdentifier: session.id)
            }
        }

        session.join()
        coordinateAttachedPlayerIfPossible()
    }

    private func handleActivity(
        _ activity: ICPodcastListeningActivity,
        sessionIdentifier: UUID
    ) {
        guard activeSession?.id == sessionIdentifier else { return }
        guard lastDeliveredOwnerToken != activity.ownerToken else { return }

        lastDeliveredOwnerToken = activity.ownerToken
        pendingAppliedActivity = activity
        postActivityChange(activity)
    }

    private func postActivityChange(_ activity: ICPodcastListeningActivity) {
        let locallyOriginated = ownedActivityTokens.contains(activity.ownerToken)

        var userInfo: [String: Any] = [
            Self.episodeIdentifierUserInfoKey: activity.episodeIdentifier,
            Self.feedURLUserInfoKey: activity.feedURL,
            Self.episodeTitleUserInfoKey: activity.episodeTitle,
            Self.podcastTitleUserInfoKey: activity.podcastTitle,
            Self.fallbackURLUserInfoKey: activity.fallbackURL,
            Self.ownerTokenUserInfoKey: activity.ownerToken,
            Self.playbackFinishedUserInfoKey: activity.playbackFinished,
            Self.locallyOriginatedUserInfoKey: locallyOriginated,
        ]
        if let episodeGUID = activity.episodeGUID {
            userInfo[Self.episodeGUIDUserInfoKey] = episodeGUID
        }

        NotificationCenter.default.post(
            name: Self.activityDidChangeNotification,
            object: self,
            userInfo: userInfo
        )
    }

    private func handleState(
        _ state: GroupSession<ICPodcastListeningActivity>.State,
        sessionIdentifier: UUID
    ) {
        guard let session = activeSession, session.id == sessionIdentifier else { return }

        if case .joined = state {
            if let pendingLocalActivity {
                self.pendingLocalActivity = nil
                session.activity = pendingLocalActivity
            }
            coordinateAttachedPlayerIfPossible()
            return
        }

        if case .invalidated = state {
            clearActiveSession(sessionIdentifier: sessionIdentifier)
        }
    }

    private func coordinateAttachedPlayerIfPossible() {
        guard let player = attachedPlayer, let session = activeSession else { return }

        if coordinatedPlayer === player,
           coordinatedSessionIdentifier == session.id {
            return
        }

        if let episodeIdentifier = attachedEpisodeIdentifier,
           let playerItem = player.currentItem {
            objc_setAssociatedObject(
                playerItem,
                identifierAssociationKey,
                episodeIdentifier as NSString,
                .OBJC_ASSOCIATION_COPY
            )
        }
        player.playbackCoordinator.delegate = self
        player.playbackCoordinator.pauseSnapsToMediaTimeOfOriginator = true
        player.playbackCoordinator.coordinateWithSession(session)
        coordinatedPlayer = player
        coordinatedSessionIdentifier = session.id
    }

    private func clearActiveSession(sessionIdentifier: UUID) {
        guard activeSession?.id == sessionIdentifier else { return }

        activityObservationTask?.cancel()
        stateObservationTask?.cancel()
        activityObservationTask = nil
        stateObservationTask = nil
        activeSession = nil
        pendingLocalActivity = nil
        pendingAppliedActivity = nil
        lastDeliveredOwnerToken = nil
        ownedActivityTokens.removeAll()
        coordinatedPlayer = nil
        coordinatedSessionIdentifier = nil
    }
}
