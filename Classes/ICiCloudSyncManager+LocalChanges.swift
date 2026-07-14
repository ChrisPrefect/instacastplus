//
//  ICiCloudSyncManager+LocalChanges.swift
//  Instacast
//
//  Local change observation (UserDefaults, Core Data) and stub-feed hydration.
//

@preconcurrency import CloudKit
import CoreData
import CryptoKit
import Foundation
import UIKit

@available(iOS 17.0, *)
extension ICiCloudSyncManager {

    nonisolated static func localOutboxCaptureAccountRecordName(
        defaults: UserDefaults,
        verifiedAccountRecordName: String?
    ) -> String? {
        if let verifiedAccountRecordName, !verifiedAccountRecordName.isEmpty {
            return verifiedAccountRecordName
        }
        if defaults.bool(forKey: localOutboxHasVerifiedAccountKey)
            || defaults.bool(forKey: localOutboxAwaitingAccountSwitchKey) {
            return defaults.string(forKey: localOutboxPendingScopeKey)
        }
        return localOutboxUnboundAccountRecordName
    }

    func currentPendingLocalOutboxScope() -> String? {
        defaults.string(forKey: Self.localOutboxPendingScopeKey)
    }

    @discardableResult
    func ensurePendingLocalOutboxScope() -> String {
        if let scope = currentPendingLocalOutboxScope(), !scope.isEmpty {
            return scope
        }
        return rotatePendingLocalOutboxScope()
    }

    @discardableResult
    func rotatePendingLocalOutboxScope() -> String {
        let scope = "\(Self.localOutboxPendingAccountRecordName):\(UUID().uuidString)"
        defaults.set(scope, forKey: Self.localOutboxPendingScopeKey)
        return scope
    }

    // `nonisolated` so the runtime doesn't assert the main-queue executor at entry if the
    // notification is ever delivered off the main thread (which would crash a MainActor
    // method). Off-main UserDefaults changes aren't user-driven settings edits, so we ignore
    // them. We only arm a debounced content check — see checkAndQueueSettingsChange.
    @objc nonisolated func defaultsDidChange(_ notification: Notification) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard isStarted, settingsSyncEnabled || subscriptionsSyncEnabled, !isApplyingRemoteChange, !isWritingSyncMetadata else { return }
            scheduleSettingsChangeCheck()
        }
    }

    // MUST stay `nonisolated`: background context merges deliver this notification on the
    // saving queue. Main-context user edits are journaled synchronously so the outbox row and
    // the edited episode/feed are committed (or rolled back) by the same Core Data save.
    @objc nonisolated func coreDataDidChange(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let capturesEpisodes = defaults.bool(forKey: Self.episodesSyncHasParticipatedKey)
        let capturesSubscriptions = defaults.bool(forKey: Self.subscriptionsSyncHasParticipatedKey)
        guard capturesEpisodes || capturesSubscriptions else { return }
        let verifiedAccountRecordName = syncEngineCallbackGate.verifiedAccountRecordNameForLocalCapture()
        guard let accountRecordName = Self.localOutboxCaptureAccountRecordName(
            defaults: defaults,
            verifiedAccountRecordName: verifiedAccountRecordName
        ) else { return }

        let insertedIDs = Self.syncRelevantInsertedObjectIDs(in: notification)
        let updatedIDs = Self.syncRelevantUpdatedObjectIDs(in: notification)
        let deletedIDs = Self.syncRelevantDeletedObjectIDs(in: notification)
        let deletedFeedURLs = Array(Set(Self.syncRelevantDeletedFeedURLs(in: notification)
            + Self.syncRelevantRedirectedFeedURLs(in: notification)))
        let deletedPropertyFeedURLs = Self.syncRelevantDeletedPropertyFeedURLs(in: notification)
        guard !insertedIDs.isEmpty || !updatedIDs.isEmpty || !deletedIDs.isEmpty
                || !deletedFeedURLs.isEmpty || !deletedPropertyFeedURLs.isEmpty else { return }

        if Thread.isMainThread {
            let notificationBox = CoreDataNotificationBox(notification)
            MainActor.assumeIsolated {
                guard isStarted, !isApplyingRemoteChange else { return }
                journalLocalOutboxChanges(notificationBox.notification,
                                          accountRecordName: accountRecordName,
                                          capturesEpisodes: capturesEpisodes,
                                          capturesSubscriptions: capturesSubscriptions,
                                          deletedFeedURLs: deletedFeedURLs,
                                          deletedPropertyFeedURLs: deletedPropertyFeedURLs)
            }
            return
        }

        Self.logSyncEvent("Core-Data-Änderung vom Hintergrund-Thread empfangen", metadata: [
            "insertedCount": insertedIDs.count,
            "updatedCount": updatedIDs.count,
            "deletedCount": deletedIDs.count,
            "deletedFeedURLCount": deletedFeedURLs.count,
            "deletedPropertyFeedURLCount": deletedPropertyFeedURLs.count,
        ])
        let changes = CoreDataChangeIDs(inserted: insertedIDs,
                                        updated: updatedIDs,
                                        deleted: deletedIDs,
                                        deletedFeedURLs: deletedFeedURLs,
                                        deletedPropertyFeedURLs: deletedPropertyFeedURLs,
                                        accountRecordName: accountRecordName,
                                        capturesEpisodes: capturesEpisodes,
                                        capturesSubscriptions: capturesSubscriptions)
        Task { @MainActor [weak self] in
            self?.processSyncObjectIDs(inserted: changes.inserted,
                                       updated: changes.updated,
                                       deleted: changes.deleted,
                                       deletedFeedURLs: changes.deletedFeedURLs,
                                       deletedPropertyFeedURLs: changes.deletedPropertyFeedURLs,
                                       accountRecordName: changes.accountRecordName,
                                       capturesEpisodes: changes.capturesEpisodes,
                                       capturesSubscriptions: changes.capturesSubscriptions)
        }
    }

    // The engine is fed only after the main context has actually committed the durable row.
    @objc nonisolated func coreDataDidSave(_ notification: Notification) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.episodesSyncHasParticipatedKey)
                || defaults.bool(forKey: Self.subscriptionsSyncHasParticipatedKey) else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard !isApplyingRemoteChange else { return }
                scheduleLocalOutboxDrain()
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self, !self.isApplyingRemoteChange else { return }
            self.scheduleLocalOutboxDrain()
        }
    }

    struct CoreDataChangeIDs: @unchecked Sendable {
        let inserted: [NSManagedObjectID]
        let updated: [NSManagedObjectID]
        let deleted: [NSManagedObjectID]
        let deletedFeedURLs: [String]
        let deletedPropertyFeedURLs: [String]
        let accountRecordName: String
        let capturesEpisodes: Bool
        let capturesSubscriptions: Bool
    }

    struct CoreDataNotificationBox: @unchecked Sendable {
        let notification: Notification

        init(_ notification: Notification) {
            self.notification = notification
        }
    }

    // Synced episode state is exactly played/favorite/position; synced feed fields are the ones
    // in the subscription payload, plus `subscribed`/`sourceURL_` for the delete path and
    // `properties` for property removal. Everything else — notably the fields a refresh always
    // rewrites — is irrelevant to the sync and gets dropped at the source.
    nonisolated static let syncRelevantEpisodeKeys: Set<String> = ["consumed", "starred", "position"]
    nonisolated static let syncRelevantFeedKeys: Set<String> = [
        "title", "rank", "parked", "username", "password", "subscribed", "sourceURL_", "properties",
    ]
    nonisolated static let syncRelevantEpisodeListKeys: Set<String> = [
        "uid", "name", "rank", "icon", "query", "audio", "video", "downloaded",
        "downloading", "notDownloaded", "unplayed", "unfinished", "played",
        "starred", "notStarred", "orderBy", "descending", "groupByPodcast",
        "continuousPlayback", "includedFeeds",
    ]

    // Of the freshly-inserted objects keep only the ones the sync cares about (new
    // subscriptions / feed settings). A feed refresh inserts hundreds of episodes plus their
    // chapters/media; those are brand-new and unheard, so they are never uploaded anyway.
    // `objectID.entity.name` is immutable model metadata and fires no fault.
    nonisolated static func syncRelevantInsertedObjectIDs(in notification: Notification) -> [NSManagedObjectID] {
        guard let objects = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> else { return [] }
        return objects.compactMap { object in
            switch object.objectID.entity.name {
            case "Feed":
                return object.objectID
            case "FeedProperty":
                return isInternalFeedProperty(object) ? nil : object.objectID
            case "EpisodeList":
                return object.objectID
            default:
                return nil
            }
        }
    }

    // Position changes are queued like any other episode edit: the player saves every
    // ~30s while playing and each tick uploads one small record right away, so other
    // devices stay current. This is deliberately NOT throttled — the historical
    // background cpu_resource kills attributed to it actually came from the widget
    // exporter doing full episode fetches on every save (fixed via SQL counts), the
    // upload itself costs a few milliseconds per tick.
    nonisolated static func syncRelevantUpdatedObjectIDs(in notification: Notification) -> [NSManagedObjectID] {
        guard let objects = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> else { return [] }
        var ids: [NSManagedObjectID] = []
        for object in objects {
            switch object.objectID.entity.name {
            case "Episode":
                let changedKeys = object.changedValuesForCurrentEvent().keys
                if changedKeys.contains(where: { syncRelevantEpisodeKeys.contains($0) }) {
                    ids.append(object.objectID)
                }
            case "Feed":
                let changedKeys = object.changedValuesForCurrentEvent().keys
                if changedKeys.contains(where: { syncRelevantFeedKeys.contains($0) }) {
                    ids.append(object.objectID)
                }
            case "FeedProperty":
                if !isInternalFeedProperty(object) {
                    ids.append(object.objectID)
                }
            case "EpisodeList":
                let changedKeys = object.changedValuesForCurrentEvent().keys
                if changedKeys.contains(where: { syncRelevantEpisodeListKeys.contains($0) }) {
                    ids.append(object.objectID)
                }
            default:
                break
            }
        }
        return ids
    }

    // Feed and feed-property deletions matter. Their values must be copied synchronously:
    // resolving a deleted object ID after the context save is too late.
    nonisolated static func syncRelevantDeletedObjectIDs(in notification: Notification) -> [NSManagedObjectID] {
        guard let objects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> else { return [] }
        return objects.compactMap {
            $0.objectID.entity.name == "Feed" || $0.objectID.entity.name == "FeedProperty" ? $0.objectID : nil
        }
    }

    nonisolated static func syncRelevantDeletedFeedURLs(in notification: Notification) -> [String] {
        guard let objects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> else { return [] }
        return objects.compactMap { object in
            if let feed = object as? CDFeed {
                return feed.sourceURL?.absoluteString ?? (feed.value(forKey: "sourceURL_") as? String)
            }
            return nil
        }
    }

    nonisolated static func syncRelevantRedirectedFeedURLs(in notification: Notification) -> [String] {
        guard let objects = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> else { return [] }
        return objects.compactMap { object in
            guard object.objectID.entity.name == "Feed",
                  object.changedValuesForCurrentEvent().keys.contains("sourceURL_"),
                  let oldURL = object.committedValues(forKeys: ["sourceURL_"])["sourceURL_"] as? String,
                  oldURL != (object.value(forKey: "sourceURL_") as? String) else { return nil }
            return oldURL
        }
    }

    nonisolated static func syncRelevantDeletedPropertyFeedURLs(in notification: Notification) -> [String] {
        guard let objects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> else { return [] }
        return objects.compactMap { object in
            guard let property = object as? CDFeedProperty,
                  let key = property.key, !internalFeedPropertyKeys.contains(key) else { return nil }
            return property.feed?.sourceURL?.absoluteString
        }
    }

    nonisolated static func isInternalFeedProperty(_ object: NSManagedObject) -> Bool {
        guard let key = (object as? CDFeedProperty)?.key else { return false }
        return internalFeedPropertyKeys.contains(key)
    }

    func processSyncObjectIDs(inserted: [NSManagedObjectID],
                              updated: [NSManagedObjectID],
                              deleted: [NSManagedObjectID],
                              deletedFeedURLs: [String] = [],
                              deletedPropertyFeedURLs: [String] = [],
                              accountRecordName: String? = nil,
                              capturesEpisodes: Bool? = nil,
                              capturesSubscriptions: Bool? = nil) {
        guard isStarted else { return }
        guard let context = databaseManager.objectContext else { return }
        let start = CFAbsoluteTimeGetCurrent()
        // Drop (and consume) IDs that were just mutated by a remote apply, so they are not
        // mistaken for local edits and echoed back up — see remoteAppliedObjectIDs. A plain
        // `isApplyingRemoteChange` guard here would be both leaky (this task usually runs
        // after the flag is reset) and overreaching (it would swallow genuine local edits
        // that happen to share a notification batch with an apply).
        let inserted = discardRemoteAppliedObjectIDs(inserted)
        let updated = discardRemoteAppliedObjectIDs(updated)
        let deleted = discardRemoteAppliedObjectIDs(deleted)
        guard !inserted.isEmpty || !updated.isEmpty || !deleted.isEmpty else { return }
        func resolve(_ ids: [NSManagedObjectID]) -> [NSManagedObject] {
            ids.compactMap { try? context.existingObject(with: $0) }
        }
        let currentCaptureScope = Self.localOutboxCaptureAccountRecordName(
            defaults: defaults,
            verifiedAccountRecordName: syncEngineCallbackGate.verifiedAccountRecordNameForLocalCapture()
        )
        let accountRecordName = accountRecordName ?? currentCaptureScope
        guard let accountRecordName, !accountRecordName.isEmpty,
              accountRecordName == currentCaptureScope else { return }
        journalLocalOutboxObjects(inserted: resolve(inserted),
                                  updated: resolve(updated),
                                  deletedFeedURLs: deletedFeedURLs,
                                  deletedPropertyFeedURLs: deletedPropertyFeedURLs,
                                  accountRecordName: accountRecordName,
                                  capturesEpisodes: capturesEpisodes ?? defaults.bool(forKey: Self.episodesSyncHasParticipatedKey),
                                  capturesSubscriptions: capturesSubscriptions ?? defaults.bool(forKey: Self.subscriptionsSyncHasParticipatedKey),
                                  changesAlreadyFiltered: true)
        // Watchdog: this runs on the main thread, so flag it if it ever gets expensive (e.g. a
        // refresh that updates many episodes) so a future hang can be localized from the log.
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        if elapsedMs >= 100 {
            logSyncEvent("Sync-Observer-Verarbeitung dauerte lange (Main-Thread)", metadata: [
                "ms": elapsedMs,
                "insertedCount": inserted.count,
                "updatedCount": updated.count,
                "deletedCount": deleted.count,
            ])
        }
    }

    // Removes IDs recorded by a remote apply from the given list; matched IDs are consumed
    // so the suppression applies to exactly one observer pass per applied mutation.
    func discardRemoteAppliedObjectIDs(_ ids: [NSManagedObjectID]) -> [NSManagedObjectID] {
        guard !remoteAppliedObjectIDs.isEmpty else { return ids }
        let remaining = ids.filter { !remoteAppliedObjectIDs.contains($0) }
        if remaining.count != ids.count {
            remoteAppliedObjectIDs.subtract(ids)
        }
        return remaining
    }

    struct LocalOutboxMutation {
        let recordName: String
        let category: String
        let operation: String
        let revision: String
        let changedAt: Date
        let payload: [String: Any]
    }

    func journalLocalOutboxChanges(_ notification: Notification,
                                   accountRecordName: String,
                                   capturesEpisodes: Bool,
                                   capturesSubscriptions: Bool,
                                   deletedFeedURLs: [String],
                                   deletedPropertyFeedURLs: [String]) {
        let inserted = (notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>) ?? []
        let updated = (notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>) ?? []
        let insertedIDs = Set(Self.syncRelevantInsertedObjectIDs(in: notification))
        let updatedIDs = Set(Self.syncRelevantUpdatedObjectIDs(in: notification))
        journalLocalOutboxObjects(inserted: inserted.filter { insertedIDs.contains($0.objectID) },
                                  updated: updated.filter { updatedIDs.contains($0.objectID) },
                                  deletedFeedURLs: deletedFeedURLs,
                                  deletedPropertyFeedURLs: deletedPropertyFeedURLs,
                                  accountRecordName: accountRecordName,
                                  capturesEpisodes: capturesEpisodes,
                                  capturesSubscriptions: capturesSubscriptions,
                                  changesAlreadyFiltered: false)
    }

    func journalLocalOutboxObjects(inserted: [NSManagedObject],
                                   updated: [NSManagedObject],
                                   deletedFeedURLs: [String],
                                   deletedPropertyFeedURLs: [String],
                                   accountRecordName: String,
                                   capturesEpisodes: Bool,
                                   capturesSubscriptions: Bool,
                                   changesAlreadyFiltered: Bool) {
        guard isStarted, !isApplyingRemoteChange,
              let context = databaseManager.objectContext else { return }

        // Main-context notifications are captured synchronously: the call-stack-scoped
        // isApplyingRemoteChange flag already identifies their origin. The ID set is only
        // for delayed/off-main merges; using stale IDs here could swallow a later user edit.
        let inserted = changesAlreadyFiltered ? discardRemoteAppliedObjects(inserted) : inserted
        let updated = changesAlreadyFiltered ? discardRemoteAppliedObjects(updated) : updated
        let now = Date()
        var mutations: [String: LocalOutboxMutation] = [:]
        var metadataWritesByRecordName: [String: ICCloudSyncItemMetadataWrite] = [:]
        var metadataIdentityWritesByRecordName: [String: ICCloudSyncItemMetadataWrite] = [:]
        var subscriptionFeedURLs: [String] = []
        var subscriptionHashes: [String: String] = [:]
        var subscriptionStates: [String: Bool] = [:]

        if capturesEpisodes {
            for object in inserted + updated {
                guard let episode = object as? CDEpisode,
                      let objectHash = episode.objectHash, !objectHash.isEmpty else { continue }
                if !changesAlreadyFiltered {
                    let keys = Set(object.changedValuesForCurrentEvent().keys)
                    guard !keys.isDisjoint(with: Self.syncRelevantEpisodeKeys) else { continue }
                }
                let payload: [String: Any] = [
                    "objectHash": objectHash,
                    "played": episode.consumed,
                    "position": Int(episode.position),
                    "starred": episode.starred,
                    "deviceID": deviceID,
                ]
                let recordName = episodeRecordID(forObjectHash: objectHash).recordName
                mutations[recordName] = LocalOutboxMutation(recordName: recordName,
                                                            category: Self.localOutboxEpisodeCategory,
                                                            operation: Self.localOutboxSaveOperation,
                                                            revision: UUID().uuidString,
                                                            changedAt: now,
                                                            payload: payload)
                metadataWritesByRecordName[recordName] = ICCloudSyncItemMetadataWrite(
                    category: Self.localOutboxEpisodeCategory,
                    recordName: recordName,
                    itemIdentifier: objectHash,
                    localModifiedAt: now,
                    localState: nil,
                    payloadHash: nil
                )
            }
        }

        if capturesSubscriptions {
            func saveMutation(for feed: CDFeed) {
                guard feed.subscribed,
                      let feedURL = feed.sourceURL?.absoluteString, !feedURL.isEmpty else { return }
                let recordName = Self.subscriptionRecordName(forFeedURL: feedURL)
                let tombstoneRecordName = Self.subscriptionTombstoneRecordName(forFeedURL: feedURL)
                let payload = Self.subscriptionPayload(for: feed, feedURL: feedURL, deviceID: deviceID)
                let revision = UUID().uuidString
                mutations[recordName] = LocalOutboxMutation(recordName: recordName,
                                                            category: Self.localOutboxSubscriptionCategory,
                                                            operation: Self.localOutboxSaveOperation,
                                                            revision: revision,
                                                            changedAt: now,
                                                            payload: payload)
                mutations[tombstoneRecordName] = LocalOutboxMutation(recordName: tombstoneRecordName,
                                                                     category: Self.localOutboxSubscriptionCategory,
                                                                     operation: Self.localOutboxDeleteOperation,
                                                                     revision: revision,
                                                                     changedAt: now,
                                                                     payload: payload)
                subscriptionFeedURLs.append(feedURL)
                subscriptionHashes[feedURL] = subscriptionPayloadHash(for: feed)
                subscriptionStates[feedURL] = true
            }

            func tombstoneMutation(for feedURL: String) {
                guard !feedURL.isEmpty else { return }
                let recordName = Self.subscriptionTombstoneRecordName(forFeedURL: feedURL)
                let activeRecordName = Self.subscriptionRecordName(forFeedURL: feedURL)
                let payload: [String: Any] = [
                    "feedURL": feedURL,
                    "deleted": true,
                    "deviceID": deviceID,
                ]
                let revision = UUID().uuidString
                mutations[recordName] = LocalOutboxMutation(recordName: recordName,
                                                            category: Self.localOutboxSubscriptionCategory,
                                                            operation: Self.localOutboxSaveOperation,
                                                            revision: revision,
                                                            changedAt: now,
                                                            payload: payload)
                mutations[activeRecordName] = LocalOutboxMutation(recordName: activeRecordName,
                                                                  category: Self.localOutboxSubscriptionCategory,
                                                                  operation: Self.localOutboxDeleteOperation,
                                                                  revision: revision,
                                                                  changedAt: now,
                                                                  payload: payload)
                subscriptionFeedURLs.append(feedURL)
                subscriptionStates[feedURL] = false
            }

            for object in inserted + updated {
                if let feed = object as? CDFeed {
                    if !changesAlreadyFiltered {
                        let keys = Set(object.changedValuesForCurrentEvent().keys)
                        guard !keys.isDisjoint(with: Self.syncRelevantFeedKeys) else { continue }
                        if let oldURL = object.committedValues(forKeys: ["sourceURL_"])["sourceURL_"] as? String,
                           oldURL != feed.sourceURL?.absoluteString {
                            tombstoneMutation(for: oldURL)
                        }
                    }
                    if feed.subscribed {
                        saveMutation(for: feed)
                    } else if let feedURL = feed.sourceURL?.absoluteString {
                        tombstoneMutation(for: feedURL)
                    }
                } else if let property = object as? CDFeedProperty,
                          let feed = property.feed,
                          let key = property.key,
                          !Self.internalFeedPropertyKeys.contains(key) {
                    saveMutation(for: feed)
                }
            }
            for feedURL in deletedPropertyFeedURLs {
                guard let url = URL(string: feedURL),
                      let feed = databaseManager.feed(withSourceURL: url) else { continue }
                saveMutation(for: feed)
            }
            for feedURL in deletedFeedURLs {
                tombstoneMutation(for: feedURL)
            }
        }

        for feedURL in Set(subscriptionFeedURLs) {
            guard let subscribed = subscriptionStates[feedURL] else { continue }
            let activeRecordName = Self.subscriptionRecordName(forFeedURL: feedURL)
            let tombstoneRecordName = Self.subscriptionTombstoneRecordName(forFeedURL: feedURL)
            metadataWritesByRecordName[activeRecordName] = ICCloudSyncItemMetadataWrite(
                category: Self.localOutboxSubscriptionCategory,
                recordName: activeRecordName,
                itemIdentifier: feedURL,
                localModifiedAt: now,
                localState: subscribed,
                payloadHash: subscribed ? subscriptionHashes[feedURL] : nil
            )
            metadataIdentityWritesByRecordName[tombstoneRecordName] = ICCloudSyncItemMetadataWrite(
                category: Self.localOutboxSubscriptionCategory,
                recordName: tombstoneRecordName,
                itemIdentifier: feedURL,
                localModifiedAt: nil,
                localState: nil,
                payloadHash: nil
            )
        }

        if subscriptionsSyncEnabled, (inserted + updated).contains(where: { $0 is CDEpisodeList }) {
            setSyncMetadata(now, forKey: Self.subscriptionListSettingsLocalModifiedDateKey)
            setSyncMetadata(Self.subscriptionListSettingsFingerprint(), forKey: Self.subscriptionListSettingsBaselineKey)
            addPendingSave(subscriptionListSettingsRecordID())
        }

        guard !mutations.isEmpty else { return }
        guard persistLocalOutboxMutations(mutations,
                                          accountRecordName: accountRecordName,
                                          metadataWrites: Array(metadataWritesByRecordName.values),
                                          metadataIdentityWrites: Array(metadataIdentityWritesByRecordName.values),
                                          context: context) else { return }
    }

    @discardableResult
    func persistLocalOutboxMutations(_ mutations: [String: LocalOutboxMutation],
                                     accountRecordName: String,
                                     metadataWrites: [ICCloudSyncItemMetadataWrite],
                                     metadataIdentityWrites: [ICCloudSyncItemMetadataWrite],
                                     context: NSManagedObjectContext) -> Bool {
        do {
            let recordNames = Set(metadataWrites.map(\.recordName)
                + metadataIdentityWrites.map(\.recordName))
            var metadataBatch = try Self.prepareSyncItemMetadataContextBatch(
                accountRecordName: accountRecordName,
                recordNames: recordNames,
                context: context
            )
            return persistLocalOutboxMutations(
                mutations,
                accountRecordName: accountRecordName,
                metadataWrites: metadataWrites,
                metadataIdentityWrites: metadataIdentityWrites,
                context: context,
                metadataBatch: &metadataBatch
            )
        } catch {
            setBlockingStatus(NSLocalizedString("Eine lokale iCloud-Änderung konnte nicht sicher gespeichert werden. Prüfe den freien Speicher und versuche es erneut.", comment: ""))
            logSyncEvent("Lokale iCloud-Metadaten konnten nicht vorbereitet werden", metadata: [
                "error": String(describing: error),
            ])
            return false
        }
    }

    @discardableResult
    func persistLocalOutboxMutations(_ mutations: [String: LocalOutboxMutation],
                                     accountRecordName: String,
                                     metadataWrites: [ICCloudSyncItemMetadataWrite],
                                     metadataIdentityWrites: [ICCloudSyncItemMetadataWrite],
                                     context: NSManagedObjectContext,
                                     metadataBatch: inout ICCloudSyncItemMetadataContextBatch) -> Bool {
        let recordNames = Array(mutations.keys)
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.localOutboxEntityName)
        request.predicate = NSPredicate(format: "accountRecordName == %@ AND recordName IN %@",
                                        accountRecordName, recordNames)
        let existingEntries: [NSManagedObject]
        do {
            existingEntries = try context.fetch(request)
        } catch {
            setBlockingStatus(NSLocalizedString("Eine lokale iCloud-Änderung konnte nicht sicher gespeichert werden. Prüfe den freien Speicher und versuche es erneut.", comment: ""))
            logSyncEvent("Lokale iCloud-Outbox konnte nicht gelesen werden", metadata: ["error": String(describing: error)])
            return false
        }
        var entriesByRecordName = Dictionary(uniqueKeysWithValues: existingEntries.compactMap { entry -> (String, NSManagedObject)? in
            guard let recordName = entry.value(forKey: "recordName") as? String else { return nil }
            return (recordName, entry)
        })
        var payloadDataByRecordName: [String: Data] = [:]
        for mutation in mutations.values {
            do {
                payloadDataByRecordName[mutation.recordName] = try PropertyListSerialization.data(
                    fromPropertyList: mutation.payload, format: .binary, options: 0)
            } catch {
                setBlockingStatus(NSLocalizedString("Eine lokale iCloud-Änderung konnte nicht sicher gespeichert werden. Prüfe den freien Speicher und versuche es erneut.", comment: ""))
                logSyncEvent("Lokaler iCloud-Outbox-Payload ist ungültig", metadata: [
                    "recordName": mutation.recordName,
                    "error": String(describing: error),
                ])
                return false
            }
        }

        do {
            try Self.upsertSyncItemMetadata(
                metadataWrites,
                metadataBatch: &metadataBatch,
                context: context
            )
            try Self.upsertSyncItemMetadata(
                metadataIdentityWrites,
                updating: [],
                metadataBatch: &metadataBatch,
                context: context
            )
        } catch {
            setBlockingStatus(NSLocalizedString("Eine lokale iCloud-Änderung konnte nicht sicher gespeichert werden. Prüfe den freien Speicher und versuche es erneut.", comment: ""))
            logSyncEvent("Lokale iCloud-Metadaten konnten nicht gespeichert werden", metadata: [
                "error": String(describing: error),
            ])
            return false
        }

        for mutation in mutations.values {
            guard let payloadData = payloadDataByRecordName[mutation.recordName] else { return false }
            let entry = entriesByRecordName[mutation.recordName]
                ?? NSEntityDescription.insertNewObject(forEntityName: Self.localOutboxEntityName, into: context)
            let revision = mutation.revision
            entry.setValue(accountRecordName, forKey: "accountRecordName")
            entry.setValue(mutation.recordName, forKey: "recordName")
            entry.setValue(mutation.category, forKey: "category")
            entry.setValue(mutation.operation, forKey: "operation")
            entry.setValue(false, forKey: "acknowledged")
            entry.setValue(revision, forKey: "revision")
            entry.setValue(mutation.changedAt, forKey: "changedAt")
            entry.setValue(payloadData, forKey: "payloadData")
            entriesByRecordName[mutation.recordName] = entry
            localOutboxSnapshotCache[mutation.recordName] = ICCloudSyncOutboxSnapshot(
                accountRecordName: accountRecordName,
                recordName: mutation.recordName,
                category: mutation.category,
                operation: mutation.operation,
                acknowledged: false,
                revision: revision,
                changedAt: mutation.changedAt,
                payloadData: payloadData)
        }
        return true
    }

    @discardableResult
    func restoreDurableSubscriptionOutboxIntent(feedURL: String,
                                                 subscribed: Bool,
                                                 changedAt: Date) -> Bool {
        guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              let context = databaseManager.objectContext else { return false }
        let activeRecordName = Self.subscriptionRecordName(forFeedURL: feedURL)
        let tombstoneRecordName = Self.subscriptionTombstoneRecordName(forFeedURL: feedURL)
        do {
            var metadataBatch = try Self.prepareSyncItemMetadataContextBatch(
                accountRecordName: accountRecordName,
                recordNames: [activeRecordName, tombstoneRecordName],
                context: context
            )
            return restoreDurableSubscriptionOutboxIntent(
                feedURL: feedURL,
                subscribed: subscribed,
                changedAt: changedAt,
                metadataBatch: &metadataBatch
            )
        } catch {
            handleLocalPersistenceFailure(error)
            return false
        }
    }

    @discardableResult
    func restoreDurableSubscriptionOutboxIntent(
        feedURL: String,
        subscribed: Bool,
        changedAt: Date,
        metadataBatch: inout ICCloudSyncItemMetadataContextBatch
    ) -> Bool {
        guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              accountRecordName == metadataBatch.accountRecordName,
              let context = databaseManager.objectContext,
              context === metadataBatch.context else { return false }
        let payload: [String: Any]
        let payloadHash: String?
        if subscribed {
            guard let url = URL(string: feedURL),
                  let feed = databaseManager.feed(withSourceURL: url), feed.subscribed else { return false }
            payload = Self.subscriptionPayload(for: feed, feedURL: feedURL, deviceID: deviceID)
            payloadHash = subscriptionPayloadHash(for: feed)
        } else {
            payload = [
                "feedURL": feedURL,
                "deleted": true,
                "deviceID": deviceID,
            ]
            payloadHash = nil
        }
        let revision = UUID().uuidString
        let activeRecordName = Self.subscriptionRecordName(forFeedURL: feedURL)
        let tombstoneRecordName = Self.subscriptionTombstoneRecordName(forFeedURL: feedURL)
        let mutations: [String: LocalOutboxMutation]
        if subscribed {
            mutations = [
                activeRecordName: LocalOutboxMutation(recordName: activeRecordName,
                                                      category: Self.localOutboxSubscriptionCategory,
                                                      operation: Self.localOutboxSaveOperation,
                                                      revision: revision,
                                                      changedAt: changedAt,
                                                      payload: payload),
                tombstoneRecordName: LocalOutboxMutation(recordName: tombstoneRecordName,
                                                         category: Self.localOutboxSubscriptionCategory,
                                                         operation: Self.localOutboxDeleteOperation,
                                                         revision: revision,
                                                         changedAt: changedAt,
                                                         payload: payload),
            ]
        } else {
            mutations = [
                activeRecordName: LocalOutboxMutation(recordName: activeRecordName,
                                                      category: Self.localOutboxSubscriptionCategory,
                                                      operation: Self.localOutboxDeleteOperation,
                                                      revision: revision,
                                                      changedAt: changedAt,
                                                      payload: payload),
                tombstoneRecordName: LocalOutboxMutation(recordName: tombstoneRecordName,
                                                         category: Self.localOutboxSubscriptionCategory,
                                                         operation: Self.localOutboxSaveOperation,
                                                         revision: revision,
                                                         changedAt: changedAt,
                                                         payload: payload),
            ]
        }
        let metadataWrite = ICCloudSyncItemMetadataWrite(
            category: Self.localOutboxSubscriptionCategory,
            recordName: activeRecordName,
            itemIdentifier: feedURL,
            localModifiedAt: changedAt,
            localState: subscribed,
            payloadHash: payloadHash
        )
        let metadataIdentityWrite = ICCloudSyncItemMetadataWrite(
            category: Self.localOutboxSubscriptionCategory,
            recordName: tombstoneRecordName,
            itemIdentifier: feedURL,
            localModifiedAt: nil,
            localState: nil,
            payloadHash: nil
        )
        guard persistLocalOutboxMutations(mutations,
                                          accountRecordName: accountRecordName,
                                          metadataWrites: [metadataWrite],
                                          metadataIdentityWrites: [metadataIdentityWrite],
                                          context: context,
                                          metadataBatch: &metadataBatch) else { return false }
        return true
    }

    func discardRemoteAppliedObjects(_ objects: [NSManagedObject]) -> [NSManagedObject] {
        let remainingIDs = Set(discardRemoteAppliedObjectIDs(objects.map(\.objectID)))
        return objects.filter { remainingIDs.contains($0.objectID) }
    }

    func mergeLocalOutboxSnapshotsIntoCache(_ entries: [ICCloudSyncOutboxSnapshot]) {
        for entry in entries {
            if let existing = localOutboxSnapshotCache[entry.recordName],
               existing.accountRecordName == entry.accountRecordName,
               existing.changedAt.compare(entry.changedAt) != .orderedAscending {
                continue
            }
            localOutboxSnapshotCache[entry.recordName] = entry
        }
    }

    func scheduleLocalOutboxDrain() {
        if localOutboxBatchDepth > 0 {
            localOutboxDrainDeferred = true
            return
        }
        guard isStarted, anySyncEnabled, !isICloudAccountSignedOut,
              isICloudAccountIdentityVerified else { return }
        if localOutboxDrainTask != nil {
            localOutboxDrainRequested = true
            return
        }
        localOutboxDrainRequested = false
        let generation = cloudAccountGeneration
        localOutboxDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.drainLocalOutbox()
            guard generation == self.cloudAccountGeneration else { return }
            self.localOutboxDrainTask = nil
            if self.localOutboxDrainRequested {
                self.localOutboxDrainRequested = false
                self.scheduleLocalOutboxDrain()
            }
        }
    }

    @objc func beginLocalOutboxBatch() {
        localOutboxBatchDepth += 1
    }

    @objc func endLocalOutboxBatch() {
        guard localOutboxBatchDepth > 0 else { return }
        localOutboxBatchDepth -= 1
        guard localOutboxBatchDepth == 0, localOutboxDrainDeferred else { return }
        localOutboxDrainDeferred = false
        scheduleLocalOutboxDrain()
    }

    func drainLocalOutbox() async -> Bool {
        guard isStarted, !isICloudAccountSignedOut, isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else { return false }
        let generation = cloudAccountGeneration
        var enabledCategories = Set<String>()
        if episodesSyncEnabled { enabledCategories.insert(Self.localOutboxEpisodeCategory) }
        if subscriptionsSyncEnabled { enabledCategories.insert(Self.localOutboxSubscriptionCategory) }
        guard !enabledCategories.isEmpty else { return true }

        let entries: [ICCloudSyncOutboxSnapshot]
        do {
            entries = try await Self.localOutboxEntries(accountRecordName: accountRecordName,
                                                        categories: enabledCategories)
        } catch {
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                  !Task.isCancelled else { return false }
            handleLocalPersistenceFailure(error)
            return false
        }
        guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
              !Task.isCancelled else { return false }
        guard !entries.isEmpty else { return true }
        mergeLocalOutboxSnapshotsIntoCache(entries)

        initializeSyncEngineIfNeeded()
        let recordNames = Set(entries.map(\.recordName))
        removePendingRecordChanges(recordNames: recordNames)
        var pendingKeys = pendingRecordZoneChangeKeys()
        var index = entries.startIndex
        while index < entries.endIndex {
            let end = entries.index(index, offsetBy: Self.pendingChangeQueueChunkSize,
                                    limitedBy: entries.endIndex) ?? entries.endIndex
            let batch = entries[index..<end]
            let saveRecordIDs = batch.filter {
                !$0.acknowledged && $0.operation == Self.localOutboxSaveOperation
            }.map {
                CKRecord.ID(recordName: $0.recordName, zoneID: zoneID)
            }
            let deleteRecordIDs = batch.filter {
                !$0.acknowledged && $0.operation == Self.localOutboxDeleteOperation
            }.map {
                CKRecord.ID(recordName: $0.recordName, zoneID: zoneID)
            }
            addPendingSaves(saveRecordIDs, pendingKeys: &pendingKeys,
                            stampDeviceRecordForUserData: false)
            addPendingDeletes(deleteRecordIDs, pendingKeys: &pendingKeys)
            index = end
            await Task.yield()
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                  !Task.isCancelled else { return false }
        }
        queueDeviceRecord(stampLastSyncDate: true)
        scheduleLowPrioritySync()
        return true
    }

    nonisolated static func localOutboxStoreError(code: Int,
                                                   description: String) -> NSError {
        NSError(domain: "ICiCloudSyncLocalOutbox",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    nonisolated static func localOutboxEntries(accountRecordName: String,
                                                categories: Set<String>? = nil,
                                                recordNames: Set<String>? = nil) async throws -> [ICCloudSyncOutboxSnapshot] {
        if let recordNames, recordNames.isEmpty { return [] }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw localOutboxStoreError(
                code: 1,
                description: "Die lokale iCloud-Outbox konnte nicht geöffnet werden."
            )
        }
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
            var predicates: [NSPredicate] = [NSPredicate(format: "accountRecordName == %@", accountRecordName)]
            if let categories, !categories.isEmpty {
                predicates.append(NSPredicate(format: "category IN %@", Array(categories)))
            }
            if let recordNames, !recordNames.isEmpty {
                predicates.append(NSPredicate(format: "recordName IN %@", Array(recordNames)))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.fetchBatchSize = pendingChangeQueueChunkSize
            let entries = try context.fetch(request)
            return try entries.map { entry in
                guard let accountRecordName = entry.value(forKey: "accountRecordName") as? String,
                      let recordName = entry.value(forKey: "recordName") as? String,
                      let category = entry.value(forKey: "category") as? String,
                      let operation = entry.value(forKey: "operation") as? String,
                      let acknowledged = entry.value(forKey: "acknowledged") as? Bool,
                      let revision = entry.value(forKey: "revision") as? String,
                      let changedAt = entry.value(forKey: "changedAt") as? Date,
                      let payloadData = entry.value(forKey: "payloadData") as? Data else {
                    throw localOutboxStoreError(
                        code: 2,
                        description: "Ein lokaler iCloud-Outbox-Eintrag ist unvollständig."
                    )
                }
                return ICCloudSyncOutboxSnapshot(accountRecordName: accountRecordName,
                                                 recordName: recordName,
                                                 category: category,
                                                 operation: operation,
                                                 acknowledged: acknowledged,
                                                 revision: revision,
                                                 changedAt: changedAt,
                                                 payloadData: payloadData)
            }
        }
    }

    func removePendingRecordChanges(recordNames: Set<String>) {
        guard let syncEngine, !recordNames.isEmpty else { return }
        let obsolete = syncEngine.state.pendingRecordZoneChanges.filter { change in
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID):
                return recordNames.contains(recordID.recordName)
            @unknown default:
                return false
            }
        }
        if !obsolete.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: obsolete)
        }
    }

    func deleteLocalOutboxEntries(for accountRecordName: String) {
        guard let context = databaseManager.objectContext else { return }
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.localOutboxEntityName)
        request.predicate = NSPredicate(format: "accountRecordName == %@", accountRecordName)
        let entries = (try? context.fetch(request)) ?? []
        guard !entries.isEmpty else { return }
        for entry in entries { context.delete(entry) }
        localOutboxSnapshotCache = localOutboxSnapshotCache.filter { $0.value.accountRecordName != accountRecordName }
        if let error = databaseManager.saveReturningError() {
            handleLocalPersistenceFailure(error)
        }
    }

    func bindUnboundLocalOutboxEntries(to accountRecordName: String) async throws {
        try await bindLocalOutboxEntries(from: Self.localOutboxUnboundAccountRecordName,
                                         to: accountRecordName)
    }

    func bindPendingAccountLocalOutboxEntries(to accountRecordName: String,
                                              pendingScope: String) async throws {
        try await bindLocalOutboxEntries(from: pendingScope,
                                         to: accountRecordName)
    }

    func bindLocalOutboxEntries(from sourceAccountRecordName: String,
                                to accountRecordName: String) async throws {
        guard !accountRecordName.isEmpty,
              let context = databaseManager.newBackgroundContext() else {
            throw NSError(domain: "ICiCloudSyncOutbox", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Die lokale iCloud-Outbox konnte nicht geöffnet werden."])
        }
        try await context.perform {
            while true {
                let request = NSFetchRequest<NSManagedObject>(entityName: Self.localOutboxEntityName)
                request.predicate = NSPredicate(format: "accountRecordName == %@",
                                                sourceAccountRecordName)
                request.sortDescriptors = [NSSortDescriptor(key: "changedAt", ascending: true)]
                request.fetchLimit = Self.pendingChangeQueueChunkSize
                let chunk = try context.fetch(request)
                guard !chunk.isEmpty else { break }
                let recordNames = chunk.compactMap { $0.value(forKey: "recordName") as? String }
                let existingRequest = NSFetchRequest<NSManagedObject>(entityName: Self.localOutboxEntityName)
                existingRequest.predicate = NSPredicate(format: "accountRecordName == %@ AND recordName IN %@",
                                                        accountRecordName, recordNames)
                let existing = try context.fetch(existingRequest)
                var existingByRecordName = Dictionary(uniqueKeysWithValues: existing.compactMap { entry -> (String, NSManagedObject)? in
                    guard let recordName = entry.value(forKey: "recordName") as? String else { return nil }
                    return (recordName, entry)
                })
                for entry in chunk {
                    guard let recordName = entry.value(forKey: "recordName") as? String else {
                        context.delete(entry)
                        continue
                    }
                    if let current = existingByRecordName[recordName] {
                        let currentDate = current.value(forKey: "changedAt") as? Date ?? .distantPast
                        let unboundDate = entry.value(forKey: "changedAt") as? Date ?? .distantPast
                        if currentDate.compare(unboundDate) == .orderedAscending {
                            context.delete(current)
                            entry.setValue(accountRecordName, forKey: "accountRecordName")
                            existingByRecordName[recordName] = entry
                        } else {
                            context.delete(entry)
                        }
                    } else {
                        entry.setValue(accountRecordName, forKey: "accountRecordName")
                        existingByRecordName[recordName] = entry
                    }
                }
                if context.hasChanges {
                    try context.save()
                }
                context.reset()
            }
        }
        localOutboxSnapshotCache = [:]
    }

    // `nonisolated` (see defaultsDidChange) so an off-main delivery can't trip the MainActor
    // executor assertion at entry. Hops to the main actor for the actual work.
    @objc nonisolated func listScrollPositionsDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, self.isStarted, self.episodesSyncEnabled, !self.isApplyingRemoteChange else { return }
            let now = Date()
            self.setScrollPositionsLocalModifiedDate(now)
            self.scrollDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.queueListScrollPositionsRecord()
                }
            }
            self.scrollDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
        }
    }

    // `nonisolated` (see defaultsDidChange). This fires from feed-refresh code paths that may
    // run on a background thread, so it must not be MainActor-isolated at entry. Processes
    // pending episode states AND pending subscriptions on the main actor.
    @objc nonisolated func episodesWereAdded(_ notification: Notification) {
        // Fires once PER FEED during a refresh. Applying pending remote states walks the whole
        // pending list (with a main-thread fetch per entry), so doing it per feed is
        // O(feeds × pending) on the main thread. Debounce it to run once after the refresh
        // settles instead.
        Task { @MainActor [weak self] in
            self?.scheduleApplyPendingPayloads()
        }
    }

    func scheduleApplyPendingPayloads() {
        guard isStarted, !isICloudAccountSignedOut, isICloudAccountIdentityVerified else { return }
        let generation = cloudAccountGeneration
        applyPendingDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isStarted,
                      !self.isICloudAccountSignedOut,
                      self.isICloudAccountIdentityVerified,
                      generation == self.cloudAccountGeneration else { return }
                await self.applyPendingEpisodeStates()
                await self.applyPendingSubscriptions()
            }
        }
        applyPendingDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    // Every UserDefaults write fires UserDefaults.didChangeNotification — including our own
    // ICiCloudSync* metadata, the engine state and status. We therefore do NOT act per
    // notification: we only (re)arm a debounced check. This both coalesces bursts and keeps
    // the per-write cost to a single work-item reschedule.
    func scheduleSettingsChangeCheck() {
        settingsDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.checkAndQueueSettingsChange()
            }
        }
        settingsDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    // CRITICAL: only queue when the actually-synced settings changed. Sync-internal
    // UserDefaults keys are excluded from the synced payload, so writing them leaves this hash
    // unchanged and we bail. Without this gate, queueing settings (which itself writes
    // defaults) re-triggers defaultsDidChange in an unbounded main-thread feedback loop — the
    // ~10s freeze when toggling a sync switch while settings sync is on.
    func checkAndQueueSettingsChange() {
        guard isStarted, !isApplyingRemoteChange else { return }
        if settingsSyncEnabled,
           !defaults.bool(forKey: Self.initialSettingsBackfillPendingKey),
           !hasPendingInitialSettingsChoice {
            let hash = syncedSettingsHash()
            if hash != storedSyncedSettingsHash() {
                setStoredSyncedSettingsHash(hash)
                setSettingsLocalModifiedDate(Date())
                addPendingSave(appSettingsRecordID())
            }
        }
        // hasLocalSubscriptionListSettings: a device without sort state publishes nothing
        // (and keeps no baseline) — see the backfill counterpart for the LWW rationale.
        if subscriptionsSyncEnabled, Self.hasLocalSubscriptionListSettings() {
            let fingerprint = Self.subscriptionListSettingsFingerprint()
            let storedBaseline = defaults.string(forKey: Self.subscriptionListSettingsBaselineKey)
            if fingerprint != storedBaseline {
                let isFormatMigration = !(storedBaseline?.hasPrefix(Self.subscriptionListSettingsFingerprintPrefix) ?? false)
                if isFormatMigration,
                   !Self.hasLocalManualFeedOrder(),
                   !Self.hasLocalEpisodeListSettings(),
                   !Self.hasLocalMainMenuListSettings() {
                    // Baseline format migration on a sort-mode-only device: nothing worth
                    // publishing — record the baseline silently so only a REAL future
                    // change publishes. A migration publish from here would race the
                    // manual-order device's repair publish under last-writer-wins.
                    setSyncMetadata(fingerprint, forKey: Self.subscriptionListSettingsBaselineKey)
                } else {
                    setSyncMetadata(fingerprint, forKey: Self.subscriptionListSettingsBaselineKey)
                    setSyncMetadata(Date(), forKey: Self.subscriptionListSettingsLocalModifiedDateKey)
                    addPendingSave(subscriptionListSettingsRecordID())
                }
            }
        }
    }

    // Baseline hash of the last queued/applied settings payload. Persisted: an in-memory
    // baseline is lost on every app start, so the first arbitrary UserDefaults write after
    // launch re-uploaded the whole (unchanged) settings record with a fresh updatedAt —
    // which could even beat genuinely *newer* remote settings under last-writer-wins.
    func storedSyncedSettingsHash() -> String? {
        defaults.string(forKey: Self.settingsSyncedHashKey)
    }

    func setStoredSyncedSettingsHash(_ hash: String?) {
        setSyncMetadata(hash, forKey: Self.settingsSyncedHashKey)
    }

    // Fingerprint of the settings values that are actually synced (the same filter used to
    // build the ICAppSettings payload).
    func syncedSettingsHash() -> String {
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        var components: [String] = []
        for (key, value) in domain where Self.shouldSyncSettingsKeyForSyncEngineCallback(key) && Self.isValidSettingsValueForSyncEngineCallback(value) {
            components.append("\(key)=\(value)")
        }
        return Self.sha256Hex(components.sorted().joined(separator: "\u{1}"))
    }

    func queueListScrollPositionsRecord() {
        addPendingSave(listScrollPositionsRecordID())
    }

    // MARK: - Stub-feed hydration (phase 2 of the subscription apply)

    // Loads the episodes of stub feeds (subscribed but never refreshed) ONE at a time,
    // so even hundreds of fresh subscriptions never block the UI. The queue is derived
    // from the data (lastUpdate == nil) on every step — an app kill simply resumes on
    // the next launch/foreground/fetch.
    // NOT gated on subscriptionsSyncEnabled: stub feeds are local subscriptions that
    // already exist — filling in their episodes is local cleanup, not a sync operation,
    // and must finish even if the user turns the category off mid-hydration.
    func hydrateStubFeedsIfNeeded() {
        guard isStarted, !isHydratingStubFeeds else { return }
        // Feeds that already failed are excluded from the run AND the count: with them
        // included, every trigger (each fetch batch ends in one) restarted a doomed
        // "Lade Podcast-Folgen… 0/3" run every ~10s — endless requests, status noise
        // and a pending-states sweep per round. They retry on the next foreground entry.
        let pendingStubCount = stubFeedObjectIDs().filter { !hydrationFailedFeedIDs.contains($0) }.count
        guard pendingStubCount > 0 else { return }
        isHydratingStubFeeds = true
        isWaitingForEpisodeLoader = false
        episodeLoaderWaitingFeedID = nil
        hydrationCompletedCount = 0
        hydrationTotalCount = pendingStubCount
        logSyncEvent("Podcast-Folgen-Nachladen gestartet", metadata: ["count": pendingStubCount])
        postStateChanged()
        hydrateNextStubFeed()
    }

    // episodes.@count == 0 keeps regularly subscribed feeds (which also have no
    // lastUpdate until their first refresh, but carry their initial episodes) out.
    // parked == NO honors the per-feed sync-stop switch: it travels in the
    // subscription payload, so a feed the user parked on the source device (e.g. a
    // dead feed URL) is never polled here — same rule as the regular refresh.
    func stubFeedObjectIDs() -> [NSManagedObjectID] {
        guard let context = databaseManager.objectContext else { return [] }
        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Feed")
        request.resultType = .managedObjectIDResultType
        request.predicate = NSPredicate(format: "subscribed == YES AND parked == NO AND lastUpdate == nil AND episodes.@count == 0")
        request.sortDescriptors = [NSSortDescriptor(key: "rank", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func hydrateNextStubFeed() {
        guard isStarted else {
            finishStubFeedHydration()
            return
        }
        // Skip feeds that already failed this session so an offline device doesn't spin
        // on the same feed; they are retried on the next hydration trigger.
        guard let nextID = stubFeedObjectIDs().first(where: { !hydrationFailedFeedIDs.contains($0) }),
              let context = databaseManager.objectContext,
              let feed = (try? context.existingObject(with: nextID)) as? CDFeed else {
            finishStubFeedHydration()
            return
        }

        subscriptionManager.hydrateStubFeed(feed) { [weak self] success, _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    self.hydrationCompletedCount += 1
                } else {
                    self.hydrationFailedFeedIDs.insert(nextID)
                }
                self.postStateChanged()
                let isLoadingHydratedFeed: Bool
                if success,
                   let context = self.databaseManager.objectContext,
                   let hydratedFeed = (try? context.existingObject(with: nextID)) as? CDFeed {
                    isLoadingHydratedFeed = EpisodeLoadingManager.shared().isLoading(hydratedFeed)
                } else {
                    isLoadingHydratedFeed = false
                }
                if isLoadingHydratedFeed {
                    // The background loader is still working through this feed's older
                    // episodes. Wait for its explicit finish/failure notification before
                    // fetching the next stub. Each job now owns an immutable payload and
                    // tiny cursor, so no cross-feed queue rewrite happens here.
                    self.waitForEpisodeLoader(feedID: nextID)
                } else {
                    self.scheduleNextStubHydration()
                }
            }
        }
    }

    func scheduleNextStubHydration() {
        // No fixed pacing delay: a plain run-loop hop lets pending UI events drain;
        // the real breathing room comes from the network parse of the next feed and
        // the adaptive episode batches (fast devices run at full speed, slow devices
        // are protected by the measured batch size, not by an arbitrary sleep).
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                self?.hydrateNextStubFeed()
            }
        }
    }

    func waitForEpisodeLoader(feedID: NSManagedObjectID) {
        isWaitingForEpisodeLoader = true
        episodeLoaderWaitingFeedID = feedID
    }

    // `nonisolated` (see defaultsDidChange) so an off-main delivery can't trip the
    // MainActor executor assertion at entry. Hops to the main actor for the actual work.
    @objc nonisolated func episodeLoadingDidFinish(_ notification: Notification) {
        let feedObjectIDURI = notification.userInfo?["feedObjectIDURI"] as? String
        Task { @MainActor [weak self] in
            guard let self, self.isWaitingForEpisodeLoader else { return }
            guard feedObjectIDURI == self.episodeLoaderWaitingFeedID?.uriRepresentation().absoluteString else { return }
            self.isWaitingForEpisodeLoader = false
            self.episodeLoaderWaitingFeedID = nil
            self.scheduleNextStubHydration()
        }
    }

    @objc nonisolated func episodeLoadingDidFail(_ notification: Notification) {
        let feedObjectIDURI = notification.userInfo?["feedObjectIDURI"] as? String
        Task { @MainActor [weak self] in
            guard let self, self.isWaitingForEpisodeLoader else { return }
            guard let waitingFeedID = self.episodeLoaderWaitingFeedID,
                  feedObjectIDURI == waitingFeedID.uriRepresentation().absoluteString else { return }
            self.hydrationFailedFeedIDs.insert(waitingFeedID)
            self.hydrationCompletedCount = max(0, self.hydrationCompletedCount - 1)
            self.isWaitingForEpisodeLoader = false
            self.episodeLoaderWaitingFeedID = nil
            self.postStateChanged()
            self.scheduleNextStubHydration()
        }
    }

    @objc nonisolated func episodeLoadingDidCancel(_ notification: Notification) {
        let feedObjectIDURI = notification.userInfo?["feedObjectIDURI"] as? String
        let isGlobalCancellation = notification.userInfo == nil
        Task { @MainActor [weak self] in
            guard let self, self.isWaitingForEpisodeLoader else { return }
            if let feedObjectIDURI {
                guard feedObjectIDURI == self.episodeLoaderWaitingFeedID?.uriRepresentation().absoluteString else { return }
            } else if !isGlobalCancellation {
                // A feed-specific cancellation without a resolvable feed is not proof
                // that the job this hydration run awaits has ended. A nil userInfo is
                // the explicit global-cancel event and releases every wait.
                return
            }
            self.isWaitingForEpisodeLoader = false
            self.episodeLoaderWaitingFeedID = nil
            self.scheduleNextStubHydration()
        }
    }

    func finishStubFeedHydration() {
        guard isHydratingStubFeeds else { return }
        isHydratingStubFeeds = false
        isWaitingForEpisodeLoader = false
        episodeLoaderWaitingFeedID = nil
        let completedCount = hydrationCompletedCount
        logSyncEvent("Podcast-Folgen-Nachladen beendet", metadata: [
            "completed": completedCount,
            "failed": hydrationFailedFeedIDs.count,
        ])
        hydrationCompletedCount = 0
        hydrationTotalCount = 0
        // hydrationFailedFeedIDs deliberately survives the run: clearing it here made
        // every subsequent trigger retry the same dead feeds immediately. It resets on
        // foreground entry (and app start) for a fresh attempt.
        postStateChanged()
        // The freshly hydrated episodes may have remote play states waiting in the
        // pending store — apply them in one batch now instead of on the next sync.
        if completedCount > 0 {
            Task { @MainActor [weak self] in
                await self?.applyPendingEpisodeStates()
            }
        }
    }
}
