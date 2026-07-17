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

private struct ICBackgroundEpisodeJournalSnapshot {
    let objectHash: String
    let played: Bool
    let position: Int
    let starred: Bool
}

private struct ICBackgroundSubscriptionJournalSnapshot {
    let feedURL: String
    let subscribed: Bool
    let payload: [String: Any]
    let payloadHash: String?
}

private let localCredentialAccountRecordName = "__local_credentials__"
private let localCredentialOutboxCategory = "localCredential"
private let localCredentialRecordPrefix = "localCredential_"
private let localCredentialExpectedPasswordKey = "expectedPassword"
private let localCredentialExpectedPasswordPresentKey = "expectedPasswordPresent"
private let localCredentialDesiredUsernameKey = "desiredUsername"
private let localCredentialDesiredPasswordKey = "desiredPassword"
private let localCredentialReplaySemaphore = DispatchSemaphore(value: 1)

struct ICLocalCredentialReplayResult: Sendable {
    var resolvedCount = 0
    var supersededIdentityCount = 0
    var supersededPasswordCount = 0

    var supersededCount: Int {
        supersededIdentityCount + supersededPasswordCount
    }

    var processedCount: Int {
        resolvedCount + supersededCount
    }
}

enum ICSubscriptionListOutboxPreparationResult: Sendable {
    case success(ICCloudSyncOutboxSnapshot)
    case staleRace
    case persistenceFailure
}

@available(iOS 17.0, *)
@MainActor
@objc final class ICBackgroundLocalSubscriptionMergePlan: NSObject {
    let viewContext: NSManagedObjectContext
    let coordinator: NSPersistentStoreCoordinator
    let insertedObjectIDs: Set<NSManagedObjectID>
    let updatedObjectIDs: Set<NSManagedObjectID>

    init(
        viewContext: NSManagedObjectContext,
        coordinator: NSPersistentStoreCoordinator,
        insertedObjectIDs: Set<NSManagedObjectID>,
        updatedObjectIDs: Set<NSManagedObjectID>
    ) {
        self.viewContext = viewContext
        self.coordinator = coordinator
        self.insertedObjectIDs = insertedObjectIDs
        self.updatedObjectIDs = updatedObjectIDs
    }
}

@available(iOS 17.0, *)
@objc final class ICBackgroundLocalOutboxCommitPlan: NSObject {
    let commitLease: ICiCloudRemoteApplyCommitLease?

    init(commitLease: ICiCloudRemoteApplyCommitLease?) {
        self.commitLease = commitLease
    }
}

@available(iOS 17.0, *)
@objc final class ICLocalCredentialRestoreLease: NSObject {
    private let completionLock = NSLock()
    private var isCompleted = false

    func consume() -> Bool {
        completionLock.lock()
        defer { completionLock.unlock() }
        guard !isCompleted else { return false }
        isCompleted = true
        return true
    }

    var isActive: Bool {
        completionLock.lock()
        defer { completionLock.unlock() }
        return !isCompleted
    }
}

@available(iOS 17.0, *)
extension ICiCloudSyncManager {

    @objc nonisolated static func beginLocalCredentialRestore() -> ICLocalCredentialRestoreLease {
        localCredentialReplaySemaphore.wait()
        return ICLocalCredentialRestoreLease()
    }

    @objc nonisolated static func endLocalCredentialRestore(
        _ lease: ICLocalCredentialRestoreLease
    ) {
        guard lease.consume() else { return }
        localCredentialReplaySemaphore.signal()
    }

    @objc(prepareBackgroundLocalOutboxCommitInContext:error:)
    nonisolated static func prepareBackgroundLocalOutboxCommit(
        in context: NSManagedObjectContext
    ) throws -> ICBackgroundLocalOutboxCommitPlan {
        let accountRecordNames = Set(
            context.insertedObjects.union(context.updatedObjects).compactMap { object -> String? in
                guard object.entity.name == localOutboxEntityName,
                      let category = object.value(forKey: "category") as? String,
                      category != localCredentialOutboxCategory,
                      category != localSubscriptionCleanupCategory else {
                    return nil
                }
                return object.value(forKey: "accountRecordName") as? String
            }
        )
        guard !accountRecordNames.isEmpty else {
            return ICBackgroundLocalOutboxCommitPlan(commitLease: nil)
        }
        guard accountRecordNames.count == 1,
              let accountRecordName = accountRecordNames.first,
              let commitLease = sharedSyncEngineCallbackGate.acquireLocalCaptureCommitLease(
                accountRecordName: accountRecordName
              ) else {
            throw localOutboxStoreError(
                code: 6,
                description: NSLocalizedString(
                    "Der iCloud-Account hat sich während der lokalen Änderung geändert. Die Änderung wurde nicht gespeichert.",
                    comment: ""
                )
            )
        }

        let defaults = UserDefaults.standard
        let verifiedAccountRecordName = sharedSyncEngineCallbackGate
            .verifiedAccountRecordNameForLocalCapture()
        guard localOutboxCaptureAccountRecordName(
            defaults: defaults,
            verifiedAccountRecordName: verifiedAccountRecordName
        ) == accountRecordName else {
            sharedSyncEngineCallbackGate.releaseRemoteApplyCommitLease(commitLease)
            throw localOutboxStoreError(
                code: 6,
                description: NSLocalizedString(
                    "Der iCloud-Account hat sich während der lokalen Änderung geändert. Die Änderung wurde nicht gespeichert.",
                    comment: ""
                )
            )
        }
        return ICBackgroundLocalOutboxCommitPlan(commitLease: commitLease)
    }

    @objc(completeBackgroundLocalOutboxCommit:)
    nonisolated static func completeBackgroundLocalOutboxCommit(
        _ plan: ICBackgroundLocalOutboxCommitPlan
    ) {
        if let commitLease = plan.commitLease {
            sharedSyncEngineCallbackGate.releaseRemoteApplyCommitLease(commitLease)
        }
    }

    @objc(cancelBackgroundLocalOutboxCommit:)
    nonisolated static func cancelBackgroundLocalOutboxCommit(
        _ plan: ICBackgroundLocalOutboxCommitPlan
    ) {
        completeBackgroundLocalOutboxCommit(plan)
    }

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
            let capturesSubscriptionSettings = defaults.bool(
                forKey: Self.subscriptionsSyncHasParticipatedKey
            )
            guard isStarted,
                  settingsSyncEnabled || subscriptionsSyncEnabled || capturesSubscriptionSettings,
                  !isApplyingRemoteChange, !isWritingSyncMetadata else { return }
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
        let deletedEpisodeList = Self.hasDeletedEpisodeList(in: notification)
        guard !insertedIDs.isEmpty || !updatedIDs.isEmpty || !deletedIDs.isEmpty
                || !deletedFeedURLs.isEmpty || !deletedPropertyFeedURLs.isEmpty
                || deletedEpisodeList else { return }

        if Thread.isMainThread {
            let notificationBox = CoreDataNotificationBox(notification)
            MainActor.assumeIsolated {
                guard isStarted, !isApplyingRemoteChange else { return }
                journalLocalOutboxChanges(notificationBox.notification,
                                          accountRecordName: accountRecordName,
                                          capturesEpisodes: capturesEpisodes,
                                          capturesSubscriptions: capturesSubscriptions,
                                          deletedFeedURLs: deletedFeedURLs,
                                          deletedPropertyFeedURLs: deletedPropertyFeedURLs,
                                          deletedEpisodeList: deletedEpisodeList)
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
                                        deletedEpisodeList: deletedEpisodeList,
                                        accountRecordName: accountRecordName,
                                        capturesEpisodes: capturesEpisodes,
                                        capturesSubscriptions: capturesSubscriptions)
        Task { @MainActor [weak self] in
            self?.processSyncObjectIDs(inserted: changes.inserted,
                                       updated: changes.updated,
                                       deleted: changes.deleted,
                                       deletedFeedURLs: changes.deletedFeedURLs,
                                       deletedPropertyFeedURLs: changes.deletedPropertyFeedURLs,
                                       deletedEpisodeList: changes.deletedEpisodeList,
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
        let deletedEpisodeList: Bool
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

    // A sibling background-context save is merged into the view context as a keyless refresh,
    // so its original changed keys cannot be reconstructed by the view-context observer. Local
    // background writers call this while they still own the transaction, before their one save.
    // The episode state, item clock, and durable upload intent therefore commit or roll back
    // together, exactly like a main-context user edit.
    @objc(journalBackgroundEpisodeChangesInContext:error:)
    nonisolated static func journalBackgroundEpisodeChanges(
        in context: NSManagedObjectContext
    ) throws {
        let episodes = context.updatedObjects.compactMap { object -> CDEpisode? in
            guard let episode = object as? CDEpisode else { return nil }
            let changedKeys = Set(episode.changedValuesForCurrentEvent().keys)
            return changedKeys.isDisjoint(with: syncRelevantEpisodeKeys) ? nil : episode
        }
        guard !episodes.isEmpty else { return }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: episodesSyncHasParticipatedKey) else { return }
        let verifiedAccountRecordName = sharedSyncEngineCallbackGate
            .verifiedAccountRecordNameForLocalCapture()
        guard let accountRecordName = localOutboxCaptureAccountRecordName(
            defaults: defaults,
            verifiedAccountRecordName: verifiedAccountRecordName
        ), !accountRecordName.isEmpty else {
            throw NSError(
                domain: "ICiCloudSyncBackgroundEpisodeJournal",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                    "Der iCloud-Account für die lokale Änderung konnte nicht bestimmt werden.",
                    comment: ""
                )]
            )
        }
        let deviceID = try resolveInstallationDeviceID()

        var snapshotsByObjectHash: [String: ICBackgroundEpisodeJournalSnapshot] = [:]
        for episode in episodes {
            guard let objectHash = episode.objectHash, !objectHash.isEmpty else { continue }
            snapshotsByObjectHash[objectHash] = ICBackgroundEpisodeJournalSnapshot(
                objectHash: objectHash,
                played: episode.consumed,
                position: Int(episode.position),
                starred: episode.starred
            )
        }
        guard !snapshotsByObjectHash.isEmpty else { return }

        let recordNames = Set(snapshotsByObjectHash.keys.map { RecordPrefix.episode + $0 })
        var metadataBatch = try prepareSyncItemMetadataContextBatch(
            accountRecordName: accountRecordName,
            recordNames: recordNames,
            context: context
        )

        var causalScopes: Set<String> = [accountRecordName]
        if verifiedAccountRecordName == accountRecordName {
            if let pendingScope = defaults.string(forKey: localOutboxPendingScopeKey),
               !pendingScope.isEmpty {
                causalScopes.insert(pendingScope)
            }
            if !defaults.bool(forKey: localOutboxHasVerifiedAccountKey) {
                causalScopes.insert(localOutboxUnboundAccountRecordName)
            }
        }

        let outboxRequest = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
        outboxRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "accountRecordName IN %@", Array(causalScopes)),
            NSPredicate(format: "recordName IN %@", Array(recordNames)),
        ])
        let existingOutboxEntries = try context.fetch(outboxRequest)
        var targetEntryByRecordName: [String: NSManagedObject] = [:]
        var supersededEntriesByRecordName: [String: [NSManagedObject]] = [:]
        var latestOutboxDateByRecordName: [String: Date] = [:]
        for entry in existingOutboxEntries {
            guard let recordName = entry.value(forKey: "recordName") as? String else {
                throw NSError(
                    domain: "ICiCloudSyncBackgroundEpisodeJournal",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                        "Ein lokaler iCloud-Outbox-Eintrag ist beschädigt.",
                        comment: ""
                    )]
                )
            }
            if let changedAt = entry.value(forKey: "changedAt") as? Date,
               changedAt > (latestOutboxDateByRecordName[recordName] ?? .distantPast) {
                latestOutboxDateByRecordName[recordName] = changedAt
            }
            if entry.value(forKey: "accountRecordName") as? String == accountRecordName {
                guard targetEntryByRecordName[recordName] == nil else {
                    throw NSError(
                        domain: "ICiCloudSyncBackgroundEpisodeJournal",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                            "Ein lokaler iCloud-Outbox-Eintrag ist mehrfach vorhanden.",
                            comment: ""
                        )]
                    )
                }
                targetEntryByRecordName[recordName] = entry
            } else {
                supersededEntriesByRecordName[recordName, default: []].append(entry)
            }
        }

        let proposedDate = Date()
        var changedAtByRecordName: [String: Date] = [:]
        var payloadDataByRecordName: [String: Data] = [:]
        var metadataWrites: [ICCloudSyncItemMetadataWrite] = []
        for snapshot in snapshotsByObjectHash.values {
            let recordName = RecordPrefix.episode + snapshot.objectHash
            let metadata = try syncItemMetadataSnapshot(
                forRecordName: recordName,
                metadataBatch: metadataBatch
            )
            let causalFloor = [
                latestOutboxDateByRecordName[recordName],
                metadata?.localModifiedAt,
                sharedRemoteEpisodeClockGate.floor(for: recordName),
            ].compactMap { $0 }.max()
            let changedAt = nextCloudKitSafeDate(proposed: proposedDate, after: causalFloor)
            let payload: [String: Any] = [
                "objectHash": snapshot.objectHash,
                "played": snapshot.played,
                "position": snapshot.position,
                "starred": snapshot.starred,
                "deviceID": deviceID,
            ]
            payloadDataByRecordName[recordName] = try PropertyListSerialization.data(
                fromPropertyList: payload,
                format: .binary,
                options: 0
            )
            changedAtByRecordName[recordName] = changedAt
            metadataWrites.append(ICCloudSyncItemMetadataWrite(
                category: localOutboxEpisodeCategory,
                recordName: recordName,
                itemIdentifier: snapshot.objectHash,
                localModifiedAt: changedAt,
                localState: nil,
                payloadHash: nil
            ))
        }

        try upsertSyncItemMetadata(
            metadataWrites,
            metadataBatch: &metadataBatch,
            context: context
        )
        for snapshot in snapshotsByObjectHash.values {
            let recordName = RecordPrefix.episode + snapshot.objectHash
            guard let payloadData = payloadDataByRecordName[recordName],
                  let changedAt = changedAtByRecordName[recordName] else { continue }
            let entry = targetEntryByRecordName[recordName]
                ?? NSEntityDescription.insertNewObject(
                    forEntityName: "ICCloudSyncOutboxEntry",
                    into: context
                )
            entry.setValue(accountRecordName, forKey: "accountRecordName")
            entry.setValue(recordName, forKey: "recordName")
            entry.setValue(localOutboxEpisodeCategory, forKey: "category")
            entry.setValue(localOutboxSaveOperation, forKey: "operation")
            Self.markLocalOutboxEntryUnacknowledged(entry)
            entry.setValue(UUID().uuidString, forKey: "revision")
            entry.setValue(changedAt, forKey: "changedAt")
            entry.setValue(payloadData, forKey: "payloadData")
            for supersededEntry in supersededEntriesByRecordName[recordName] ?? [] {
                context.delete(supersededEntry)
            }
        }
    }

    // Background writers must commit the changed subscription payload and its paired CloudKit
    // intent in the same SQLite transaction. A later view-context merge contains no reliable
    // changed-key snapshot, so reconstructing this intent on MainActor would both race and stall
    // the UI for large imports.
    @objc(journalBackgroundSubscriptionChangesInContext:credentialIntents:error:)
    nonisolated static func journalBackgroundSubscriptionChanges(
        in context: NSManagedObjectContext,
        credentialIntents: [String: NSDictionary]
    ) throws {
        var feedsByURL: [String: CDFeed] = [:]
        for object in context.insertedObjects.union(context.updatedObjects) {
            if let feed = object as? CDFeed {
                let changedKeys = Set(feed.changedValuesForCurrentEvent().keys)
                guard object.isInserted
                        || !changedKeys.isDisjoint(with: syncRelevantFeedKeys) else { continue }
                guard let feedURL = feed.sourceURL?.absoluteString,
                      !feedURL.isEmpty else { continue }
                feedsByURL[feedURL] = feed
            } else if let property = object as? CDFeedProperty,
                      let key = property.key,
                      !internalFeedPropertyKeys.contains(key),
                      let feed = property.feed,
                      feed.subscribed,
                      let feedURL = feed.sourceURL?.absoluteString,
                      !feedURL.isEmpty {
                feedsByURL[feedURL] = feed
            }
        }
        if !credentialIntents.isEmpty {
            for case let feed as CDFeed in context.registeredObjects {
                guard feed.subscribed,
                      let feedURL = feed.sourceURL?.absoluteString,
                      credentialIntents[feedURL] != nil else { continue }
                feedsByURL[feedURL] = feed
            }
        }
        guard !feedsByURL.isEmpty else { return }

        // Keychain writes cannot participate in the Core Data transaction. Persist a local-only
        // compare-and-set intent in the same SQLite transaction as the restored feed first. It is
        // independent of iCloud participation and is deleted only after verified Keychain readback.
        if !credentialIntents.isEmpty {
            let credentialRecordNames = Set(credentialIntents.keys.map {
                localCredentialRecordPrefix + sha256Hex($0)
            })
            let request = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "accountRecordName == %@", localCredentialAccountRecordName),
                NSPredicate(format: "recordName IN %@", Array(credentialRecordNames)),
            ])
            var entriesByRecordName: [String: NSManagedObject] = [:]
            for entry in try context.fetch(request) {
                guard let recordName = entry.value(forKey: "recordName") as? String,
                      credentialRecordNames.contains(recordName),
                      entriesByRecordName[recordName] == nil else {
                    throw localOutboxStoreError(
                        code: 2,
                        description: NSLocalizedString(
                            "Die vorgemerkte Wiederherstellung der Podcast-Zugangsdaten ist beschädigt.",
                            comment: ""
                        )
                    )
                }
                entriesByRecordName[recordName] = entry
            }
            for (feedURL, intent) in credentialIntents {
                guard let expectedPassword = intent[localCredentialExpectedPasswordKey] as? String,
                      let expectedPasswordPresent = intent[localCredentialExpectedPasswordPresentKey] as? Bool,
                      let desiredUsername = intent[localCredentialDesiredUsernameKey] as? String,
                      !desiredUsername.isEmpty,
                      let desiredPassword = intent[localCredentialDesiredPasswordKey] as? String else {
                    throw localOutboxStoreError(
                        code: 2,
                        description: NSLocalizedString(
                            "Die importierten Podcast-Zugangsdaten sind unvollständig.",
                            comment: ""
                        )
                    )
                }
                let payload: [String: Any] = [
                    "feedURL": feedURL,
                    localCredentialExpectedPasswordKey: expectedPassword,
                    localCredentialExpectedPasswordPresentKey: expectedPasswordPresent,
                    localCredentialDesiredUsernameKey: desiredUsername,
                    localCredentialDesiredPasswordKey: desiredPassword,
                ]
                let payloadData = try PropertyListSerialization.data(
                    fromPropertyList: payload,
                    format: .binary,
                    options: 0
                )
                let recordName = localCredentialRecordPrefix + sha256Hex(feedURL)
                let entry = entriesByRecordName[recordName]
                    ?? NSEntityDescription.insertNewObject(
                        forEntityName: localOutboxEntityName,
                        into: context
                    )
                entry.setValue(localCredentialAccountRecordName, forKey: "accountRecordName")
                entry.setValue(recordName, forKey: "recordName")
                entry.setValue(localCredentialOutboxCategory, forKey: "category")
                entry.setValue(localOutboxSaveOperation, forKey: "operation")
                Self.markLocalOutboxEntryUnacknowledged(entry)
                entry.setValue(UUID().uuidString, forKey: "revision")
                entry.setValue(Date(), forKey: "changedAt")
                entry.setValue(payloadData, forKey: "payloadData")
            }
        }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: subscriptionsSyncHasParticipatedKey) else { return }
        let verifiedAccountRecordName = sharedSyncEngineCallbackGate
            .verifiedAccountRecordNameForLocalCapture()
        guard let accountRecordName = localOutboxCaptureAccountRecordName(
            defaults: defaults,
            verifiedAccountRecordName: verifiedAccountRecordName
        ), !accountRecordName.isEmpty else {
            throw localOutboxStoreError(
                code: 1,
                description: NSLocalizedString(
                    "Der iCloud-Account für die lokale Änderung konnte nicht bestimmt werden.",
                    comment: ""
                )
            )
        }
        let deviceID = try resolveInstallationDeviceID()

        var snapshotsByFeedURL: [String: ICBackgroundSubscriptionJournalSnapshot] = [:]
        for (feedURL, feed) in feedsByURL {
            let payload: [String: Any]
            let payloadHash: String?
            if feed.subscribed {
                var activePayload = subscriptionPayload(
                    for: feed,
                    feedURL: feedURL,
                    deviceID: deviceID
                )
                let passwordOverride = credentialIntents[feedURL]?[localCredentialDesiredPasswordKey] as? String
                if let passwordOverride {
                    activePayload["password"] = passwordOverride
                }
                payload = activePayload
                payloadHash = subscriptionPayloadHash(
                    for: feed,
                    passwordOverride: passwordOverride
                )
            } else {
                payload = [
                    "feedURL": feedURL,
                    "deleted": true,
                    "deviceID": deviceID,
                ]
                payloadHash = nil
            }
            snapshotsByFeedURL[feedURL] = ICBackgroundSubscriptionJournalSnapshot(
                feedURL: feedURL,
                subscribed: feed.subscribed,
                payload: payload,
                payloadHash: payloadHash
            )
        }

        var recordNames = Set<String>()
        for feedURL in snapshotsByFeedURL.keys {
            recordNames.insert(subscriptionRecordName(forFeedURL: feedURL))
            recordNames.insert(subscriptionTombstoneRecordName(forFeedURL: feedURL))
        }
        var metadataBatch = try prepareSyncItemMetadataContextBatch(
            accountRecordName: accountRecordName,
            recordNames: recordNames,
            context: context
        )

        var causalScopes: Set<String> = [accountRecordName]
        if verifiedAccountRecordName == accountRecordName {
            if let pendingScope = defaults.string(forKey: localOutboxPendingScopeKey),
               !pendingScope.isEmpty {
                causalScopes.insert(pendingScope)
            }
            if !defaults.bool(forKey: localOutboxHasVerifiedAccountKey) {
                causalScopes.insert(localOutboxUnboundAccountRecordName)
            }
        }

        let outboxRequest = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
        outboxRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "accountRecordName IN %@", Array(causalScopes)),
            NSPredicate(format: "recordName IN %@", Array(recordNames)),
        ])
        let existingEntries = try context.fetch(outboxRequest)
        var targetEntryByRecordName: [String: NSManagedObject] = [:]
        var supersededEntriesByRecordName: [String: [NSManagedObject]] = [:]
        var latestOutboxDateByRecordName: [String: Date] = [:]
        for entry in existingEntries {
            guard let recordName = entry.value(forKey: "recordName") as? String,
                  recordNames.contains(recordName) else {
                throw localOutboxStoreError(
                    code: 2,
                    description: NSLocalizedString(
                        "Ein lokaler iCloud-Outbox-Eintrag ist beschädigt.",
                        comment: ""
                    )
                )
            }
            if let changedAt = entry.value(forKey: "changedAt") as? Date,
               changedAt > (latestOutboxDateByRecordName[recordName] ?? .distantPast) {
                latestOutboxDateByRecordName[recordName] = changedAt
            }
            if entry.value(forKey: "accountRecordName") as? String == accountRecordName {
                guard targetEntryByRecordName[recordName] == nil else {
                    throw localOutboxStoreError(
                        code: 2,
                        description: NSLocalizedString(
                            "Ein lokaler iCloud-Outbox-Eintrag ist mehrfach vorhanden.",
                            comment: ""
                        )
                    )
                }
                targetEntryByRecordName[recordName] = entry
            } else {
                supersededEntriesByRecordName[recordName, default: []].append(entry)
            }
        }

        let proposedDate = Date()
        var activeMetadataWrites: [ICCloudSyncItemMetadataWrite] = []
        var identityMetadataWrites: [ICCloudSyncItemMetadataWrite] = []
        for snapshot in snapshotsByFeedURL.values {
            let activeRecordName = subscriptionRecordName(forFeedURL: snapshot.feedURL)
            let tombstoneRecordName = subscriptionTombstoneRecordName(forFeedURL: snapshot.feedURL)
            let metadata = try syncItemMetadataSnapshot(
                forRecordName: activeRecordName,
                metadataBatch: metadataBatch
            )
            let causalFloor = [
                latestOutboxDateByRecordName[activeRecordName],
                latestOutboxDateByRecordName[tombstoneRecordName],
                metadata?.localModifiedAt,
            ].compactMap { $0 }.max()
            let changedAt = nextCloudKitSafeDate(proposed: proposedDate, after: causalFloor)
            let revision = UUID().uuidString
            let payloadData = try PropertyListSerialization.data(
                fromPropertyList: snapshot.payload,
                format: .binary,
                options: 0
            )

            activeMetadataWrites.append(ICCloudSyncItemMetadataWrite(
                category: localOutboxSubscriptionCategory,
                recordName: activeRecordName,
                itemIdentifier: snapshot.feedURL,
                localModifiedAt: changedAt,
                localState: snapshot.subscribed,
                payloadHash: snapshot.payloadHash
            ))
            identityMetadataWrites.append(ICCloudSyncItemMetadataWrite(
                category: localOutboxSubscriptionCategory,
                recordName: tombstoneRecordName,
                itemIdentifier: snapshot.feedURL,
                localModifiedAt: nil,
                localState: nil,
                payloadHash: nil
            ))

            for (recordName, operation) in [
                (activeRecordName, snapshot.subscribed ? localOutboxSaveOperation : localOutboxDeleteOperation),
                (tombstoneRecordName, snapshot.subscribed ? localOutboxDeleteOperation : localOutboxSaveOperation),
            ] {
                let entry = targetEntryByRecordName[recordName]
                    ?? NSEntityDescription.insertNewObject(
                        forEntityName: localOutboxEntityName,
                        into: context
                    )
                entry.setValue(accountRecordName, forKey: "accountRecordName")
                entry.setValue(recordName, forKey: "recordName")
                entry.setValue(localOutboxSubscriptionCategory, forKey: "category")
                entry.setValue(operation, forKey: "operation")
                Self.markLocalOutboxEntryUnacknowledged(entry)
                entry.setValue(revision, forKey: "revision")
                entry.setValue(changedAt, forKey: "changedAt")
                entry.setValue(payloadData, forKey: "payloadData")
                for supersededEntry in supersededEntriesByRecordName[recordName] ?? [] {
                    context.delete(supersededEntry)
                }
            }
        }

        try upsertSyncItemMetadata(
            activeMetadataWrites,
            metadataBatch: &metadataBatch,
            context: context
        )
        try upsertSyncItemMetadata(
            identityMetadataWrites,
            updating: [],
            metadataBatch: &metadataBatch,
            context: context
        )
    }

    nonisolated static func resolvePendingLocalCredentialIntentsBatch(
        in context: NSManagedObjectContext,
        feedURLs: Set<String>? = nil
    ) throws -> ICLocalCredentialReplayResult {
        let request = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
        var predicates: [NSPredicate] = [
            NSPredicate(format: "accountRecordName == %@", localCredentialAccountRecordName),
            NSPredicate(format: "category == %@", localCredentialOutboxCategory),
        ]
        if let feedURLs {
            let recordNames = feedURLs.map { localCredentialRecordPrefix + sha256Hex($0) }
            if recordNames.isEmpty { return ICLocalCredentialReplayResult() }
            predicates.append(NSPredicate(format: "recordName IN %@", recordNames))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
        request.fetchLimit = pendingChangeQueueChunkSize
        request.fetchBatchSize = pendingChangeQueueChunkSize
        let entries = try context.fetch(request)
        guard !entries.isEmpty else { return ICLocalCredentialReplayResult() }

        var payloadByEntry: [NSManagedObject: [String: Any]] = [:]
        var requestedFeedURLs = Set<String>()
        for entry in entries {
            guard let payloadData = entry.value(forKey: "payloadData") as? Data,
                  let payload = try PropertyListSerialization.propertyList(
                    from: payloadData,
                    options: [],
                    format: nil
                  ) as? [String: Any],
                  let feedURL = payload["feedURL"] as? String,
                  !feedURL.isEmpty,
                  entry.value(forKey: "recordName") as? String
                    == localCredentialRecordPrefix + sha256Hex(feedURL) else {
                throw localOutboxStoreError(
                    code: 2,
                    description: NSLocalizedString(
                        "Die vorgemerkte Wiederherstellung der Podcast-Zugangsdaten ist beschädigt.",
                        comment: ""
                    )
                )
            }
            payloadByEntry[entry] = payload
            requestedFeedURLs.insert(feedURL)
        }

        let feedRequest = NSFetchRequest<CDFeed>(entityName: "Feed")
        feedRequest.predicate = NSPredicate(format: "sourceURL_ IN %@", Array(requestedFeedURLs))
        feedRequest.includesSubentities = false
        let feeds = try context.fetch(feedRequest)
        var feedsByURL: [String: CDFeed] = [:]
        for feed in feeds {
            guard let feedURL = feed.value(forKey: "sourceURL_") as? String else { continue }
            feedsByURL[feedURL] = feed
        }

        var result = ICLocalCredentialReplayResult()
        func retireSupersededIntent(_ entry: NSManagedObject, identityChanged: Bool) {
            context.delete(entry)
            if identityChanged {
                result.supersededIdentityCount += 1
            } else {
                result.supersededPasswordCount += 1
            }
        }

        for entry in entries {
            guard let payload = payloadByEntry[entry],
                  let feedURL = payload["feedURL"] as? String,
                  let expectedPassword = payload[localCredentialExpectedPasswordKey] as? String,
                  let expectedPasswordPresent = payload[localCredentialExpectedPasswordPresentKey] as? Bool,
                  let desiredUsername = payload[localCredentialDesiredUsernameKey] as? String,
                  !desiredUsername.isEmpty,
                  let desiredPassword = payload[localCredentialDesiredPasswordKey] as? String,
                  !desiredPassword.isEmpty else {
                throw localOutboxStoreError(
                    code: 2,
                    description: NSLocalizedString(
                        "Die vorgemerkte Wiederherstellung der Podcast-Zugangsdaten ist beschädigt.",
                        comment: ""
                    )
                )
            }

            guard let feed = feedsByURL[feedURL],
                  feed.username == desiredUsername else {
                retireSupersededIntent(entry, identityChanged: true)
                continue
            }

            let replaced: Bool
            do {
                var didMatch = ObjCBool(false)
                try feed.compareAndSetPassword(
                    desiredPassword,
                    expected: expectedPasswordPresent ? expectedPassword : nil,
                    expectedPresent: expectedPasswordPresent,
                    didMatch: &didMatch
                )
                replaced = didMatch.boolValue
            } catch {
                throw NSError(
                    domain: "ICiCloudSyncLocalOutbox",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString(
                            "Die importierten Podcast-Zugangsdaten konnten nicht sicher gespeichert werden.",
                            comment: ""
                        ),
                        NSUnderlyingErrorKey: error,
                    ]
                )
            }
            guard replaced else {
                retireSupersededIntent(entry, identityChanged: false)
                continue
            }
            context.delete(entry)
            result.resolvedCount += 1
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        context.reset()
        return result
    }

    nonisolated static func resolvePendingLocalCredentialIntentsInCriticalSection(
        feedURLs: Set<String>?
    ) throws -> ICLocalCredentialReplayResult {
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            throw localOutboxStoreError(
                code: 1,
                description: NSLocalizedString(
                    "Der lokale Speicher für die importierten Podcast-Zugangsdaten konnte nicht geöffnet werden.",
                    comment: ""
                )
            )
        }
        var aggregate = ICLocalCredentialReplayResult()
        while true {
            let batch = try context.performAndWait {
                try resolvePendingLocalCredentialIntentsBatch(
                    in: context,
                    feedURLs: feedURLs
                )
            }
            aggregate.resolvedCount += batch.resolvedCount
            aggregate.supersededIdentityCount += batch.supersededIdentityCount
            aggregate.supersededPasswordCount += batch.supersededPasswordCount
            guard batch.processedCount > 0 else { return aggregate }
        }
    }

    nonisolated static func resolvePendingLocalCredentialIntentsSerialized(
        feedURLs: Set<String>?
    ) throws -> ICLocalCredentialReplayResult {
        localCredentialReplaySemaphore.wait()
        defer { localCredentialReplaySemaphore.signal() }
        return try resolvePendingLocalCredentialIntentsInCriticalSection(
            feedURLs: feedURLs
        )
    }

    nonisolated static func validateTargetedLocalCredentialReplay(
        _ result: ICLocalCredentialReplayResult
    ) throws {
        if result.supersededIdentityCount > 0 {
            throw localOutboxStoreError(
                code: 3,
                description: NSLocalizedString(
                    "Die importierten Podcast-Zugangsdaten passen nicht mehr zum lokalen Podcast.",
                    comment: ""
                )
            )
        }
        if result.supersededPasswordCount > 0 {
            throw localOutboxStoreError(
                code: 4,
                description: NSLocalizedString(
                    "Die Podcast-Zugangsdaten wurden zwischenzeitlich geändert und nicht überschrieben.",
                    comment: ""
                )
            )
        }
    }

    @objc(resolvePendingLocalCredentialIntentsForFeedURLs:error:)
    nonisolated static func resolvePendingLocalCredentialIntents(
        forFeedURLs feedURLs: [String]
    ) throws {
        let result = try resolvePendingLocalCredentialIntentsSerialized(
            feedURLs: Set(feedURLs)
        )
        try validateTargetedLocalCredentialReplay(result)
    }

    @objc(resolvePendingLocalCredentialIntentsWithRestoreLease:feedURLs:error:)
    nonisolated static func resolvePendingLocalCredentialIntents(
        withRestoreLease lease: ICLocalCredentialRestoreLease,
        feedURLs: [String]
    ) throws {
        guard lease.isActive else {
            throw localOutboxStoreError(
                code: 1,
                description: NSLocalizedString(
                    "Die vorgemerkte Wiederherstellung der Podcast-Zugangsdaten ist beschädigt.",
                    comment: ""
                )
            )
        }
        let result = try resolvePendingLocalCredentialIntentsInCriticalSection(
            feedURLs: Set(feedURLs)
        )
        try validateTargetedLocalCredentialReplay(result)
    }

    nonisolated static func resolvePendingLocalCredentialIntents() async throws -> Int {
        let result = try await Task.detached(priority: .utility) {
            try resolvePendingLocalCredentialIntentsSerialized(feedURLs: nil)
        }.value
        if result.supersededCount > 0 {
            logSyncEvent("Überholte Podcast-Zugangsdaten-Wiederherstellungen verworfen", metadata: [
                "identityCount": result.supersededIdentityCount,
                "passwordCount": result.supersededPasswordCount,
            ])
        }
        return result.processedCount
    }

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

    nonisolated static func hasDeletedEpisodeList(in notification: Notification) -> Bool {
        guard let objects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> else {
            return false
        }
        return objects.contains { $0.objectID.entity.name == "EpisodeList" }
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
                              deletedEpisodeList: Bool = false,
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
        guard !inserted.isEmpty || !updated.isEmpty || !deleted.isEmpty
                || deletedEpisodeList else { return }
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
                                  deletedEpisodeList: deletedEpisodeList,
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
                                   deletedPropertyFeedURLs: [String],
                                   deletedEpisodeList: Bool) {
        let inserted = (notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>) ?? []
        let updated = (notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>) ?? []
        let insertedIDs = Set(Self.syncRelevantInsertedObjectIDs(in: notification))
        let updatedIDs = Set(Self.syncRelevantUpdatedObjectIDs(in: notification))
        journalLocalOutboxObjects(inserted: inserted.filter { insertedIDs.contains($0.objectID) },
                                  updated: updated.filter { updatedIDs.contains($0.objectID) },
                                  deletedFeedURLs: deletedFeedURLs,
                                  deletedPropertyFeedURLs: deletedPropertyFeedURLs,
                                  deletedEpisodeList: deletedEpisodeList,
                                  accountRecordName: accountRecordName,
                                  capturesEpisodes: capturesEpisodes,
                                  capturesSubscriptions: capturesSubscriptions,
                                  changesAlreadyFiltered: false)
    }

    func journalLocalOutboxObjects(inserted: [NSManagedObject],
                                   updated: [NSManagedObject],
                                   deletedFeedURLs: [String],
                                   deletedPropertyFeedURLs: [String],
                                   deletedEpisodeList: Bool,
                                   accountRecordName: String,
                                   capturesEpisodes: Bool,
                                   capturesSubscriptions: Bool,
                                   changesAlreadyFiltered: Bool) {
        guard isStarted, !isApplyingRemoteChange,
              let context = databaseManager.objectContext,
              let deviceID else { return }

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

        let episodeListChanged = deletedEpisodeList
            || (inserted + updated).contains(where: { $0 is CDEpisodeList })
        if capturesSubscriptions, episodeListChanged {
            let recordName = subscriptionListSettingsRecordID().recordName
            mutations[recordName] = LocalOutboxMutation(
                recordName: recordName,
                category: Self.localOutboxSubscriptionListSettingsCategory,
                operation: Self.localOutboxSaveOperation,
                revision: UUID().uuidString,
                changedAt: now,
                payload: Self.subscriptionListSettingsDirtyMarkerPayload
            )
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

    func causalLocalOutboxScopes(for accountRecordName: String) -> Set<String> {
        var scopes: Set<String> = [accountRecordName]
        guard syncEngineCallbackGate.verifiedAccountRecordNameForLocalCapture()
                == accountRecordName else {
            return scopes
        }
        if let pendingScope = currentPendingLocalOutboxScope(), !pendingScope.isEmpty {
            scopes.insert(pendingScope)
        }
        if !defaults.bool(forKey: Self.localOutboxHasVerifiedAccountKey) {
            scopes.insert(Self.localOutboxUnboundAccountRecordName)
        }
        return scopes
    }

    @discardableResult
    func persistLocalOutboxMutations(_ mutations: [String: LocalOutboxMutation],
                                     accountRecordName: String,
                                     metadataWrites: [ICCloudSyncItemMetadataWrite],
                                     metadataIdentityWrites: [ICCloudSyncItemMetadataWrite],
                                     context: NSManagedObjectContext,
                                     metadataBatch: inout ICCloudSyncItemMetadataContextBatch) -> Bool {
        let recordNames = Array(mutations.keys)
        let causalScopes = causalLocalOutboxScopes(for: accountRecordName)
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.localOutboxEntityName)
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "accountRecordName IN %@", Array(causalScopes)),
            NSPredicate(format: "recordName IN %@", recordNames),
        ])
        let existingEntries: [NSManagedObject]
        do {
            existingEntries = try context.fetch(request)
        } catch {
            setBlockingStatus(NSLocalizedString("Eine lokale iCloud-Änderung konnte nicht sicher gespeichert werden. Prüfe den freien Speicher und versuche es erneut.", comment: ""))
            logSyncEvent("Lokale iCloud-Outbox konnte nicht gelesen werden", metadata: ["error": String(describing: error)])
            return false
        }
        var entriesByRecordName: [String: NSManagedObject] = [:]
        var supersededEntriesByRecordName: [String: [NSManagedObject]] = [:]
        var highestCommittedOutboxDateByRecordName: [String: Date] = [:]
        var highestTargetOutboxDateByRecordName: [String: Date] = [:]
        var highestSourceOutboxDateByRecordName: [String: Date] = [:]
        for entry in existingEntries {
            guard let recordName = entry.value(forKey: "recordName") as? String else { continue }
            if entry.value(forKey: "accountRecordName") as? String == accountRecordName {
                entriesByRecordName[recordName] = entry
                if let changedAt = entry.value(forKey: "changedAt") as? Date {
                    highestTargetOutboxDateByRecordName[recordName] = changedAt
                }
            } else {
                supersededEntriesByRecordName[recordName, default: []].append(entry)
                if let changedAt = entry.value(forKey: "changedAt") as? Date,
                   changedAt > (highestSourceOutboxDateByRecordName[recordName] ?? .distantPast) {
                    highestSourceOutboxDateByRecordName[recordName] = changedAt
                }
            }
            if let changedAt = entry.value(forKey: "changedAt") as? Date,
               changedAt > (highestCommittedOutboxDateByRecordName[recordName] ?? .distantPast) {
                highestCommittedOutboxDateByRecordName[recordName] = changedAt
            }
        }
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

        let mutationsByRevision = Dictionary(grouping: mutations.values, by: \.revision)
        var causalDatesByRevision: [String: Date] = [:]
        for (revision, revisionMutations) in mutationsByRevision {
            var causalFloor: Date?
            for mutation in revisionMutations {
                let candidates = [
                    causalFloor,
                    highestCommittedOutboxDateByRecordName[mutation.recordName],
                    (metadataBatch.entriesByRecordName[mutation.recordName]?
                        .value(forKey: "localModifiedAt") as? Date),
                ].compactMap { $0 }
                causalFloor = candidates.max()
                if mutation.category == Self.localOutboxEpisodeCategory,
                   let remoteFloor = remoteEpisodeClockGate.floor(for: mutation.recordName),
                   remoteFloor > (causalFloor ?? .distantPast) {
                    causalFloor = remoteFloor
                }
                if mutation.category == Self.localOutboxSubscriptionListSettingsCategory {
                    var singletonFloors = causalScopes.compactMap {
                        singletonClockFloor(
                            recordName: mutation.recordName,
                            accountRecordName: $0
                        )
                    }
                    singletonFloors.append(contentsOf: Self.pendingSingletonUploadIntents()
                        .filter {
                            $0.recordName == mutation.recordName
                                && causalScopes.contains($0.accountRecordName)
                        }
                        .map(\.modifiedAt))
                    if syncEngineCallbackGate.verifiedAccountRecordNameForLocalCapture()
                        == accountRecordName,
                       let metadataFloor = singletonMetadataClockFloor(
                            recordName: mutation.recordName
                       ) {
                        singletonFloors.append(metadataFloor)
                    }
                    let singletonFloor = singletonFloors.max()
                    if let singletonFloor,
                       singletonFloor > (causalFloor ?? .distantPast) {
                        causalFloor = singletonFloor
                    }
                }
            }
            let sourceFloor = revisionMutations.compactMap {
                highestSourceOutboxDateByRecordName[$0.recordName]
            }.max()
            if let sourceFloor {
                var targetFloorCandidates = revisionMutations.flatMap { mutation in
                    [
                        highestTargetOutboxDateByRecordName[mutation.recordName],
                        (metadataBatch.entriesByRecordName[mutation.recordName]?
                            .value(forKey: "localModifiedAt") as? Date),
                    ].compactMap { $0 }
                }
                for mutation in revisionMutations
                where mutation.category == Self.localOutboxSubscriptionListSettingsCategory {
                    if let singletonFloor = singletonClockFloor(
                        recordName: mutation.recordName,
                        accountRecordName: accountRecordName
                    ) {
                        targetFloorCandidates.append(singletonFloor)
                    }
                }
                let targetFloor = targetFloorCandidates.max()
                let reboundSourceFloor = Self.nextCloudKitSafeDate(
                    proposed: sourceFloor,
                    after: targetFloor
                )
                if reboundSourceFloor > (causalFloor ?? .distantPast) {
                    causalFloor = reboundSourceFloor
                }
            }
            let proposed = revisionMutations.map(\.changedAt).max() ?? Date()
            causalDatesByRevision[revision] = Self.nextCloudKitSafeDate(
                proposed: proposed,
                after: causalFloor
            )
        }
        let metadataWritesWithCausalDates = metadataWrites.map { write in
            guard let revision = mutations[write.recordName]?.revision,
                  let causalDate = causalDatesByRevision[revision] else { return write }
            return ICCloudSyncItemMetadataWrite(
                category: write.category,
                recordName: write.recordName,
                itemIdentifier: write.itemIdentifier,
                localModifiedAt: causalDate,
                localState: write.localState,
                payloadHash: write.payloadHash
            )
        }

        do {
            try Self.upsertSyncItemMetadata(
                metadataWritesWithCausalDates,
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
            guard let changedAt = causalDatesByRevision[revision] else { return false }
            entry.setValue(accountRecordName, forKey: "accountRecordName")
            entry.setValue(mutation.recordName, forKey: "recordName")
            entry.setValue(mutation.category, forKey: "category")
            entry.setValue(mutation.operation, forKey: "operation")
            Self.markLocalOutboxEntryUnacknowledged(entry)
            entry.setValue(revision, forKey: "revision")
            entry.setValue(changedAt, forKey: "changedAt")
            entry.setValue(payloadData, forKey: "payloadData")
            for supersededEntry in supersededEntriesByRecordName[mutation.recordName] ?? [] {
                context.delete(supersededEntry)
            }
            entriesByRecordName[mutation.recordName] = entry
            highestCommittedOutboxDateByRecordName[mutation.recordName] = changedAt
            if mutation.category != Self.localOutboxSubscriptionListSettingsCategory {
                localOutboxSnapshotCache[mutation.recordName] = ICCloudSyncOutboxSnapshot(
                    accountRecordName: accountRecordName,
                    recordName: mutation.recordName,
                    category: mutation.category,
                    operation: mutation.operation,
                    acknowledged: false,
                    revision: revision,
                    changedAt: changedAt,
                    payloadData: payloadData)
            }
        }
        return true
    }

    nonisolated static func causallyOrderedLocalOutboxDate(
        proposed: Date,
        after existing: Date?
    ) -> Date {
        nextCloudKitSafeDate(proposed: proposed, after: existing)
    }

    nonisolated static func nextCloudKitSafeDate(
        proposed: Date,
        after existing: Date?
    ) -> Date {
        let floor = max(
            proposed.timeIntervalSince1970,
            existing?.timeIntervalSince1970 ?? proposed.timeIntervalSince1970
        )
        return Date(timeIntervalSince1970: (ceil(floor * 1_000.0) + 1.0) / 1_000.0)
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
              context === metadataBatch.context,
              let deviceID else { return false }
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

    @objc(prepareBackgroundLocalSubscriptionMergeWithInsertedObjectURIStrings:updatedObjectURIStrings:error:)
    func prepareBackgroundLocalSubscriptionMerge(
        insertedObjectURIStrings: [String],
        updatedObjectURIStrings: [String]
    ) throws -> ICBackgroundLocalSubscriptionMergePlan {
        guard let viewContext = databaseManager.objectContext else {
            throw Self.localOutboxStoreError(
                code: 1,
                description: NSLocalizedString(
                    "Die importierten Podcast-Einstellungen konnten nicht in der Oberfläche aktualisiert werden.",
                    comment: ""
                )
            )
        }
        guard let coordinator = databaseManager.storeCoordinator else {
            throw Self.localOutboxStoreError(
                code: 1,
                description: NSLocalizedString(
                    "Die importierten Podcast-Einstellungen konnten nicht in der Oberfläche aktualisiert werden.",
                    comment: ""
                )
            )
        }
        let insertedObjectIDs = try managedObjectIDs(
            forURIStrings: Set(insertedObjectURIStrings),
            coordinator: coordinator
        )
        let updatedObjectIDs = try managedObjectIDs(
            forURIStrings: Set(updatedObjectURIStrings),
            coordinator: coordinator
        )
        return ICBackgroundLocalSubscriptionMergePlan(
            viewContext: viewContext,
            coordinator: coordinator,
            insertedObjectIDs: insertedObjectIDs,
            updatedObjectIDs: updatedObjectIDs
        )
    }

    @objc func commitBackgroundLocalSubscriptionMergePlan(
        _ plan: ICBackgroundLocalSubscriptionMergePlan
    ) {
        var changes: [AnyHashable: Any] = [:]
        if !plan.insertedObjectIDs.isEmpty {
            changes[NSInsertedObjectIDsKey] = plan.insertedObjectIDs
        }
        if !plan.updatedObjectIDs.isEmpty {
            changes[NSUpdatedObjectIDsKey] = plan.updatedObjectIDs
        }
        if !changes.isEmpty {
            // The background transaction already contains the exact outbox intent. The merge
            // notification is synchronous, so suppressing observation only for this call stack
            // cannot hide a later genuine user edit.
            isApplyingRemoteChange = true
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: changes,
                into: [plan.viewContext]
            )
            isApplyingRemoteChange = false
        }
        scheduleLocalOutboxDrain()
    }

    @objc func backgroundLocalOutboxChangesDidCommit() {
        scheduleLocalOutboxDrain()
    }

    @objc func backgroundLocalEpisodeChangesDidCommit() {
        backgroundLocalOutboxChangesDidCommit()
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

    func resolvePendingLocalCredentialIntentsIfNeeded() async -> Bool {
        if let localCredentialReplayTask {
            return await localCredentialReplayTask.value
        }
        let task = Task { @MainActor [weak self] in
            do {
                _ = try await Self.resolvePendingLocalCredentialIntents()
                return true
            } catch {
                self?.handleLocalPersistenceFailure(error)
                return false
            }
        }
        localCredentialReplayTask = task
        let succeeded = await task.value
        localCredentialReplayTask = nil
        return succeeded
    }

    func drainLocalOutbox() async -> Bool {
        guard await resolvePendingLocalCredentialIntentsIfNeeded() else { return false }
        guard isStarted, !isICloudAccountSignedOut, isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else { return false }
        let generation = cloudAccountGeneration
        var enabledCategories = Set<String>()
        if episodesSyncEnabled { enabledCategories.insert(Self.localOutboxEpisodeCategory) }
        if subscriptionsSyncEnabled {
            enabledCategories.insert(Self.localOutboxSubscriptionCategory)
            enabledCategories.insert(Self.localOutboxSubscriptionListSettingsCategory)
        }
        guard !enabledCategories.isEmpty else { return true }

        var entries: [ICCloudSyncOutboxSnapshot]
        do {
            entries = try await Self.localOutboxEntries(accountRecordName: accountRecordName,
                                                        categories: enabledCategories,
                                                        unresolvedOnly: true)
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
        let loadedRecordNames = Set(entries.map(\.recordName))
        let missingSubscriptionPairRecordNames = entries.reduce(into: Set<String>()) {
            result, entry in
            guard entry.category == Self.localOutboxSubscriptionCategory else { return }
            result.formUnion(Self.subscriptionOutboxRecordNames(
                forCloudRecordName: entry.recordName
            ))
        }.subtracting(loadedRecordNames)
        if !missingSubscriptionPairRecordNames.isEmpty {
            do {
                entries.append(contentsOf: try await Self.localOutboxEntries(
                    accountRecordName: accountRecordName,
                    categories: [Self.localOutboxSubscriptionCategory],
                    recordNames: missingSubscriptionPairRecordNames
                ))
            } catch {
                handleLocalPersistenceFailure(error)
                return false
            }
            guard generation == cloudAccountGeneration,
                  isICloudAccountIdentityVerified,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                  !Task.isCancelled else { return false }
        }
        let episodeRecordNames = Set(entries.compactMap {
            $0.category == Self.localOutboxEpisodeCategory ? $0.recordName : nil
        })
        if !episodeRecordNames.isEmpty {
            let metadataByRecordName: [String: ICCloudSyncItemMetadataSnapshot]
            do {
                metadataByRecordName = try await Self.syncItemMetadataByRecordName(
                    episodeRecordNames,
                    accountRecordName: accountRecordName
                )
            } catch {
                handleLocalPersistenceFailure(error)
                return false
            }
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                  !Task.isCancelled else { return false }
            let resolvedRecordNames = Set(entries.compactMap { entry -> String? in
                guard entry.category == Self.localOutboxEpisodeCategory,
                      Self.episodeOutboxRevisionResolvedByMetadata(
                        entry,
                        metadata: metadataByRecordName[entry.recordName]
                      ) else { return nil }
                return entry.recordName
            })
            if !resolvedRecordNames.isEmpty {
                for recordName in resolvedRecordNames {
                    if let cached = localOutboxSnapshotCache[recordName],
                       Self.episodeOutboxRevisionResolvedByMetadata(
                        cached,
                        metadata: metadataByRecordName[recordName]
                       ) {
                        localOutboxSnapshotCache.removeValue(forKey: recordName)
                    }
                }
                removePendingRecordChanges(recordNames: resolvedRecordNames)
                entries.removeAll { resolvedRecordNames.contains($0.recordName) }
            }
        }
        guard !entries.isEmpty else { return true }
        for index in entries.indices
        where entries[index].category == Self.localOutboxSubscriptionListSettingsCategory {
            let expanded: ICCloudSyncOutboxSnapshot
            switch await expandCommittedSubscriptionListSettingsOutboxEntry(
                entries[index]
            ) {
            case .success(let entry):
                expanded = entry
            case .staleRace:
                scheduleLocalOutboxDrain()
                return false
            case .persistenceFailure:
                return false
            }
            let intent = pendingSingletonUploadIntent(
                recordName: RecordPrefix.subscriptionListSettings,
                accountRecordName: accountRecordName
            )
            let aligned: ICCloudSyncOutboxSnapshot
            switch await alignCommittedSubscriptionListSettingsOutboxEntry(
                expanded,
                intent: intent
            ) {
            case .success(let entry):
                aligned = entry
            case .staleRace:
                scheduleLocalOutboxDrain()
                return false
            case .persistenceFailure:
                return false
            }
            let currentIntent = pendingSingletonUploadIntent(
                recordName: RecordPrefix.subscriptionListSettings,
                accountRecordName: accountRecordName
            )
            let intentIsUnchanged: Bool
            switch (intent, currentIntent) {
            case (nil, nil):
                intentIsUnchanged = true
            case let (.some(previous), .some(current)):
                intentIsUnchanged = previous.revision == current.revision
                    && previous.modifiedAt == current.modifiedAt
            default:
                intentIsUnchanged = false
            }
            guard intentIsUnchanged else {
                scheduleLocalOutboxDrain()
                return false
            }
            entries[index] = aligned
            guard generation == cloudAccountGeneration,
                  isICloudAccountIdentityVerified,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                  !Task.isCancelled else { return false }
        }
        mergeLocalOutboxSnapshotsIntoCache(entries)

        initializeSyncEngineIfNeeded()
        let recordNames = Set(entries.map(\.recordName))
        removePendingRecordChanges(recordNames: recordNames)
        var pendingKeys = pendingRecordZoneChangeKeys()
        for entry in entries
        where !entry.acknowledged
            && entry.category == Self.localOutboxSubscriptionListSettingsCategory {
            guard prepareCommittedSubscriptionListSettingsOutboxEntryForUpload(
                entry,
                pendingKeys: &pendingKeys
            ) else { return false }
        }
        var index = entries.startIndex
        while index < entries.endIndex {
            let end = entries.index(index, offsetBy: Self.pendingChangeQueueChunkSize,
                                    limitedBy: entries.endIndex) ?? entries.endIndex
            let batch = entries[index..<end]
            let saveRecordIDs = batch.filter {
                !$0.acknowledged
                    && $0.operation == Self.localOutboxSaveOperation
                    && $0.category != Self.localOutboxSubscriptionListSettingsCategory
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

    func expandCommittedSubscriptionListSettingsOutboxEntry(
        _ entry: ICCloudSyncOutboxSnapshot
    ) async -> ICSubscriptionListOutboxPreparationResult {
        guard entry.payloadDictionary()?[Self.subscriptionListSettingsDirtyMarkerPayloadKey] as? Bool == true else {
            return .success(entry)
        }
        do {
            let payload = try await Self.committedSubscriptionListSettingsPayload()
            guard let expanded = try await Self.replaceSubscriptionListSettingsDirtyMarker(
                accountRecordName: entry.accountRecordName,
                expectedRevision: entry.revision,
                payload: payload
            ) else { return .staleRace }
            return .success(expanded)
        } catch {
            handleLocalPersistenceFailure(error)
            return .persistenceFailure
        }
    }

    func alignCommittedSubscriptionListSettingsOutboxEntry(
        _ entry: ICCloudSyncOutboxSnapshot,
        intent: PendingSingletonUploadIntent?
    ) async -> ICSubscriptionListOutboxPreparationResult {
        guard let intent,
              intent.revision != entry.revision || intent.modifiedAt != entry.changedAt,
              intent.modifiedAt > entry.changedAt else { return .success(entry) }
        guard let payloadData = intent.payloadData,
              let context = databaseManager.newICloudSyncBackgroundContext() else {
            handleLocalPersistenceFailure(Self.localOutboxStoreError(
                code: 2,
                description: "Die lokalen Listen-Einstellungen sind unvollständig."
            ))
            return .persistenceFailure
        }
        context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        do {
            return try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(
                    entityName: Self.localOutboxEntityName
                )
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "accountRecordName == %@", entry.accountRecordName),
                    NSPredicate(format: "recordName == %@", entry.recordName),
                ])
                request.fetchLimit = 1
                guard let storedEntry = try context.fetch(request).first,
                      storedEntry.value(forKey: "revision") as? String == entry.revision,
                      storedEntry.value(forKey: "changedAt") as? Date == entry.changedAt else {
                    return .staleRace
                }
                storedEntry.setValue(intent.revision, forKey: "revision")
                storedEntry.setValue(intent.modifiedAt, forKey: "changedAt")
                storedEntry.setValue(payloadData, forKey: "payloadData")
                Self.markLocalOutboxEntryUnacknowledged(storedEntry)
                do {
                    try context.save()
                } catch {
                    let persistenceError = error as NSError
                    context.rollback()
                    if persistenceError.domain == NSCocoaErrorDomain,
                       persistenceError.code == 133020 {
                        return .staleRace
                    }
                    throw error
                }
                return .success(ICCloudSyncOutboxSnapshot(
                    accountRecordName: entry.accountRecordName,
                    recordName: entry.recordName,
                    category: entry.category,
                    operation: entry.operation,
                    acknowledged: false,
                    revision: intent.revision,
                    changedAt: intent.modifiedAt,
                    payloadData: payloadData
                ))
            }
        } catch {
            handleLocalPersistenceFailure(error)
            return .persistenceFailure
        }
    }

    nonisolated static func committedSubscriptionListSettingsPayload() async throws -> [String: Any] {
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            throw localOutboxStoreError(
                code: 1,
                description: "Die lokalen Listen-Einstellungen konnten nicht gelesen werden."
            )
        }
        return try await context.perform {
            let request = NSFetchRequest<CDEpisodeList>(entityName: "EpisodeList")
            request.includesSubentities = false
            request.relationshipKeyPathsForPrefetching = ["includedFeeds"]
            request.sortDescriptors = [
                NSSortDescriptor(key: "rank", ascending: true),
                NSSortDescriptor(key: "uid", ascending: true),
            ]
            let payloads = try context.fetch(request).compactMap {
                episodeListPayloadForSyncEngineCallback($0)
            }
            return subscriptionListSettingsPayloadForSyncEngineCallback(
                episodeListPayloads: payloads
            )
        }
    }

    nonisolated static func replaceSubscriptionListSettingsDirtyMarker(
        accountRecordName: String,
        expectedRevision: String,
        payload: [String: Any]
    ) async throws -> ICCloudSyncOutboxSnapshot? {
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            throw localOutboxStoreError(
                code: 1,
                description: "Die lokale iCloud-Outbox konnte nicht geöffnet werden."
            )
        }
        context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        let payloadData = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
            request.predicate = NSPredicate(
                format: "accountRecordName == %@ AND recordName == %@",
                accountRecordName,
                RecordPrefix.subscriptionListSettings
            )
            request.fetchLimit = 1
            guard let entry = try context.fetch(request).first,
                  entry.value(forKey: "revision") as? String == expectedRevision,
                  entry.value(forKey: "category") as? String == localOutboxSubscriptionListSettingsCategory,
                  entry.value(forKey: "operation") as? String == localOutboxSaveOperation,
                  let recordName = entry.value(forKey: "recordName") as? String,
                  let revision = entry.value(forKey: "revision") as? String,
                  let changedAt = entry.value(forKey: "changedAt") as? Date else {
                return nil
            }
            entry.setValue(payloadData, forKey: "payloadData")
            do {
                try context.save()
            } catch {
                let persistenceError = error as NSError
                context.rollback()
                if persistenceError.domain == NSCocoaErrorDomain,
                   persistenceError.code == 133020 {
                    return nil
                }
                throw error
            }
            return ICCloudSyncOutboxSnapshot(
                accountRecordName: accountRecordName,
                recordName: recordName,
                category: localOutboxSubscriptionListSettingsCategory,
                operation: localOutboxSaveOperation,
                acknowledged: localOutboxEntryIsAcknowledged(entry),
                revision: revision,
                changedAt: changedAt,
                payloadData: payloadData
            )
        }
    }

    func prepareCommittedSubscriptionListSettingsOutboxEntryForUpload(
        _ entry: ICCloudSyncOutboxSnapshot,
        pendingKeys: inout Set<String>
    ) -> Bool {
        let revision = entry.revision
        guard entry.recordName == RecordPrefix.subscriptionListSettings,
              entry.category == Self.localOutboxSubscriptionListSettingsCategory,
              entry.operation == Self.localOutboxSaveOperation,
              let payload = entry.payloadDictionary(),
              let intent = persistPendingSingletonUploadIntent(
                for: subscriptionListSettingsRecordID(),
                revision: revision,
                modifiedAt: entry.changedAt,
                payload: payload
              ) else { return false }
        setSyncMetadata(
            Self.subscriptionListSettingsFingerprint(payload: payload),
            forKey: Self.subscriptionListSettingsBaselineKey
        )
        setSyncMetadata(
            intent.modifiedAt,
            forKey: Self.subscriptionListSettingsLocalModifiedDateKey
        )
        addPendingSaves(
            [subscriptionListSettingsRecordID()],
            pendingKeys: &pendingKeys,
            stampDeviceRecordForUserData: false
        )
        return true
    }

    nonisolated static func localOutboxStoreError(code: Int,
                                                   description: String) -> NSError {
        NSError(domain: "ICiCloudSyncLocalOutbox",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    nonisolated static func localOutboxEntryIsAcknowledged(_ entry: NSManagedObject) -> Bool {
        guard let revision = entry.value(forKey: "revision") as? String,
              let operation = entry.value(forKey: "operation") as? String else {
            return false
        }
        let acknowledgedRevision = entry.value(forKey: "acknowledgedRevision") as? String
        let acknowledgedOperation = entry.value(forKey: "acknowledgedOperation") as? String
        if acknowledgedRevision == nil, acknowledgedOperation == nil {
            return (entry.value(forKey: "acknowledged") as? Bool) == true
        }
        return acknowledgedRevision == revision && acknowledgedOperation == operation
    }

    nonisolated static func markLocalOutboxEntryUnacknowledged(_ entry: NSManagedObject) {
        entry.setValue(false, forKey: "acknowledged")
        entry.setValue(nil, forKey: "acknowledgedRevision")
        entry.setValue(nil, forKey: "acknowledgedOperation")
    }

    @discardableResult
    nonisolated static func markLocalOutboxEntryAcknowledged(
        _ entry: NSManagedObject,
        revision: String,
        operation: String
    ) -> Bool {
        guard entry.value(forKey: "revision") as? String == revision,
              entry.value(forKey: "operation") as? String == operation else {
            return false
        }
        entry.setValue(revision, forKey: "acknowledgedRevision")
        entry.setValue(operation, forKey: "acknowledgedOperation")
        return true
    }

    nonisolated static func localOutboxEntries(accountRecordName: String,
                                                categories: Set<String>? = nil,
                                                recordNames: Set<String>? = nil,
                                                unresolvedOnly: Bool = false) async throws -> [ICCloudSyncOutboxSnapshot] {
        if let recordNames, recordNames.isEmpty { return [] }
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
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
            if unresolvedOnly {
                let pendingLegacyEntry = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "acknowledgedRevision == nil"),
                    NSPredicate(format: "acknowledgedOperation == nil"),
                    NSPredicate(format: "acknowledged == NO"),
                ])
                let hasAnyReceiptField = NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "acknowledgedRevision != nil"),
                    NSPredicate(format: "acknowledgedOperation != nil"),
                ])
                let receiptIsIncompleteOrStale = NSCompoundPredicate(
                    orPredicateWithSubpredicates: [
                        NSPredicate(format: "acknowledgedRevision == nil"),
                        NSPredicate(format: "acknowledgedOperation == nil"),
                        NSPredicate(format: "acknowledgedRevision != revision"),
                        NSPredicate(format: "acknowledgedOperation != operation"),
                    ]
                )
                predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                    pendingLegacyEntry,
                    NSCompoundPredicate(andPredicateWithSubpredicates: [
                        hasAnyReceiptField,
                        receiptIsIncompleteOrStale,
                    ]),
                ]))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.fetchBatchSize = pendingChangeQueueChunkSize
            let entries = try context.fetch(request)
            return try entries.map { entry in
                guard let accountRecordName = entry.value(forKey: "accountRecordName") as? String,
                      let recordName = entry.value(forKey: "recordName") as? String,
                      let category = entry.value(forKey: "category") as? String,
                      let operation = entry.value(forKey: "operation") as? String,
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
                                                 acknowledged: localOutboxEntryIsAcknowledged(entry),
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

    func deleteLocalOutboxEntries(for accountRecordName: String) async throws {
        guard let context = databaseManager.objectContext,
              let coordinator = context.persistentStoreCoordinator,
              let backgroundContext = databaseManager.newICloudSyncBackgroundContext() else {
            throw Self.localOutboxStoreError(
                code: 1,
                description: "Die lokale iCloud-Outbox konnte nicht geöffnet werden."
            )
        }
        while true {
            let deletedObjectIDURIs: [URL] = try await backgroundContext.perform {
                let request = NSFetchRequest<NSManagedObjectID>(
                    entityName: Self.localOutboxEntityName
                )
                request.resultType = .managedObjectIDResultType
                request.predicate = NSPredicate(
                    format: "accountRecordName == %@",
                    accountRecordName
                )
                request.fetchLimit = Self.pendingChangeQueueChunkSize
                let objectIDs = try backgroundContext.fetch(request)
                guard !objectIDs.isEmpty else { return [] }
                let deleteRequest = NSBatchDeleteRequest(objectIDs: objectIDs)
                try backgroundContext.execute(deleteRequest)
                backgroundContext.reset()
                return objectIDs.map { $0.uriRepresentation() }
            }
            guard !deletedObjectIDURIs.isEmpty else { break }
            let deletedObjectIDs = deletedObjectIDURIs.compactMap {
                coordinator.managedObjectID(forURIRepresentation: $0)
            }
            if !deletedObjectIDs.isEmpty {
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: [NSDeletedObjectIDsKey: deletedObjectIDs],
                    into: [context]
                )
                context.processPendingChanges()
            }
            await Task.yield()
        }
        localOutboxSnapshotCache = localOutboxSnapshotCache.filter { $0.value.accountRecordName != accountRecordName }
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
              let context = databaseManager.newICloudSyncBackgroundContext() else {
            throw NSError(domain: "ICiCloudSyncOutbox", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Die lokale iCloud-Outbox konnte nicht geöffnet werden."])
        }
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType)
        let destinationListClockFloor = singletonClockFloor(
            recordName: RecordPrefix.subscriptionListSettings,
            accountRecordName: accountRecordName
        )
        try await context.perform {
            while true {
                let request = NSFetchRequest<NSManagedObject>(entityName: Self.localOutboxEntityName)
                request.predicate = NSPredicate(format: "accountRecordName == %@",
                                                sourceAccountRecordName)
                request.sortDescriptors = [NSSortDescriptor(key: "changedAt", ascending: true)]
                request.fetchLimit = Self.pendingChangeQueueChunkSize
                let seedChunk = try context.fetch(request)
                guard !seedChunk.isEmpty else { break }
                let revisions = Set(seedChunk.compactMap {
                    $0.value(forKey: "revision") as? String
                })
                let completeRequest = NSFetchRequest<NSManagedObject>(
                    entityName: Self.localOutboxEntityName
                )
                completeRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "accountRecordName == %@", sourceAccountRecordName),
                    NSPredicate(format: "revision IN %@", Array(revisions)),
                ])
                let chunk = try context.fetch(completeRequest)
                let recordNames = chunk.compactMap { $0.value(forKey: "recordName") as? String }
                let existingRequest = NSFetchRequest<NSManagedObject>(entityName: Self.localOutboxEntityName)
                existingRequest.predicate = NSPredicate(format: "accountRecordName == %@ AND recordName IN %@",
                                                        accountRecordName, recordNames)
                let existing = try context.fetch(existingRequest)
                var existingByRecordName = Dictionary(uniqueKeysWithValues: existing.compactMap { entry -> (String, NSManagedObject)? in
                    guard let recordName = entry.value(forKey: "recordName") as? String else { return nil }
                    return (recordName, entry)
                })
                let metadataRequest = NSFetchRequest<NSManagedObject>(
                    entityName: Self.syncItemMetadataEntityName
                )
                metadataRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(
                        format: "accountRecordName IN %@",
                        [sourceAccountRecordName, accountRecordName]
                    ),
                    NSPredicate(format: "recordName IN %@", recordNames),
                ])
                let metadataEntries = try context.fetch(metadataRequest)
                var metadataByIdentity: [String: NSManagedObject] = [:]
                for metadataEntry in metadataEntries {
                    guard let scope = metadataEntry.value(forKey: "accountRecordName") as? String,
                          let recordName = metadataEntry.value(forKey: "recordName") as? String else {
                        continue
                    }
                    metadataByIdentity["\(scope)\u{1}\(recordName)"] = metadataEntry
                }
                let entriesByRevision = Dictionary(grouping: chunk) {
                    $0.value(forKey: "revision") as? String ?? ""
                }
                for revisionEntries in entriesByRevision.values {
                    let revisionRecordNames = revisionEntries.compactMap {
                        $0.value(forKey: "recordName") as? String
                    }
                    var destinationFloor = revisionRecordNames.compactMap {
                        existingByRecordName[$0]?.value(forKey: "changedAt") as? Date
                    }.max()
                    let destinationMetadataFloor = revisionRecordNames.compactMap {
                        metadataByIdentity["\(accountRecordName)\u{1}\($0)"]?
                            .value(forKey: "localModifiedAt") as? Date
                    }.max()
                    if let destinationMetadataFloor,
                       destinationMetadataFloor > (destinationFloor ?? .distantPast) {
                        destinationFloor = destinationMetadataFloor
                    }
                    if revisionRecordNames.contains(RecordPrefix.subscriptionListSettings),
                       let destinationListClockFloor,
                       destinationListClockFloor > (destinationFloor ?? .distantPast) {
                        destinationFloor = destinationListClockFloor
                    }
                    let proposed = revisionEntries.compactMap {
                        $0.value(forKey: "changedAt") as? Date
                    }.max() ?? .distantPast
                    let reboundDate = Self.nextCloudKitSafeDate(
                        proposed: proposed,
                        after: destinationFloor
                    )
                    for entry in revisionEntries {
                        guard let recordName = entry.value(forKey: "recordName") as? String else {
                            context.delete(entry)
                            continue
                        }
                        if let current = existingByRecordName[recordName] {
                            for key in ["category", "operation", "acknowledged",
                                        "acknowledgedRevision", "acknowledgedOperation",
                                        "revision", "changedAt", "payloadData"] {
                                current.setValue(entry.value(forKey: key), forKey: key)
                            }
                            current.setValue(reboundDate, forKey: "changedAt")
                            context.delete(entry)
                        } else {
                            entry.setValue(accountRecordName, forKey: "accountRecordName")
                            entry.setValue(reboundDate, forKey: "changedAt")
                            existingByRecordName[recordName] = entry
                        }
                        if let sourceMetadata = metadataByIdentity[
                            "\(sourceAccountRecordName)\u{1}\(recordName)"
                        ] {
                            sourceMetadata.setValue(reboundDate, forKey: "localModifiedAt")
                        }
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
            guard let self, self.isStarted,
                  self.defaults.bool(forKey: Self.episodesSyncHasParticipatedKey),
                  !self.isApplyingRemoteChange else { return }
            let now = Date()
            guard let intent = self.persistPendingSingletonUploadIntent(
                for: self.listScrollPositionsRecordID(),
                modifiedAt: now
            ) else { return }
            self.setScrollPositionsLocalModifiedDate(intent.modifiedAt)
            self.scrollDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.scrollDebounceWorkItem = nil
                    self.queueListScrollPositionsRecord()
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
        settingsChangeCheckRevision &+= 1
        let revision = settingsChangeCheckRevision
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.checkAndQueueSettingsChange(expectedRevision: revision)
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
    func checkAndQueueSettingsChange(expectedRevision: UInt64) async {
        guard isStarted, !isApplyingRemoteChange,
              expectedRevision == settingsChangeCheckRevision else { return }
        settingsDebounceWorkItem = nil
        let generation = cloudAccountGeneration
        let captureAccountRecordName = Self.localOutboxCaptureAccountRecordName(
            defaults: defaults,
            verifiedAccountRecordName: syncEngineCallbackGate.verifiedAccountRecordNameForLocalCapture()
        )
        let capturesSubscriptionListSettings = defaults.bool(
            forKey: Self.subscriptionsSyncHasParticipatedKey
        )

        let subscriptionListSettingsPayload: [String: Any]?
        if capturesSubscriptionListSettings {
            do {
                subscriptionListSettingsPayload = try await Self.committedSubscriptionListSettingsPayload()
            } catch {
                guard generation == cloudAccountGeneration,
                      expectedRevision == settingsChangeCheckRevision,
                      captureAccountRecordName == Self.localOutboxCaptureAccountRecordName(
                        defaults: defaults,
                        verifiedAccountRecordName: syncEngineCallbackGate.verifiedAccountRecordNameForLocalCapture()
                      ),
                      !Task.isCancelled else { return }
                handleLocalPersistenceFailure(error)
                return
            }
        } else {
            subscriptionListSettingsPayload = nil
        }

        guard isStarted, !isApplyingRemoteChange,
              generation == cloudAccountGeneration,
              expectedRevision == settingsChangeCheckRevision,
              captureAccountRecordName == Self.localOutboxCaptureAccountRecordName(
                defaults: defaults,
                verifiedAccountRecordName: syncEngineCallbackGate.verifiedAccountRecordNameForLocalCapture()
              ),
              !Task.isCancelled else { return }

        if settingsSyncEnabled,
           !defaults.bool(forKey: Self.initialSettingsBackfillPendingKey),
           !hasPendingInitialSettingsChoice {
            let hash = syncedSettingsHash()
            if hash != storedSyncedSettingsHash() {
                guard let intent = persistPendingSingletonUploadIntent(
                    for: appSettingsRecordID()
                ) else { return }
                setStoredSyncedSettingsHash(hash)
                setSettingsLocalModifiedDate(intent.modifiedAt)
                addPendingSave(appSettingsRecordID())
            }
        }
        // hasLocalSubscriptionListSettings: a device without sort state publishes nothing
        // (and keeps no baseline) — see the backfill counterpart for the LWW rationale.
        if let subscriptionListSettingsPayload {
            let fingerprint = Self.subscriptionListSettingsFingerprint(payload: subscriptionListSettingsPayload)
            let storedBaseline = defaults.string(forKey: Self.subscriptionListSettingsBaselineKey)
            if fingerprint != storedBaseline {
                let isFormatMigration = !(storedBaseline?.hasPrefix(Self.subscriptionListSettingsFingerprintPrefix) ?? false)
                let hasLocalManualFeedOrder = (subscriptionListSettingsPayload["manualOrder"] as? [String])?.isEmpty == false
                let hasLocalEpisodeListSettings = ((subscriptionListSettingsPayload["episodeLists"] as? [[String: Any]]) ?? []).contains { payload in
                    guard let uid = payload["uid"] as? String,
                          let defaultPayload = Self.defaultEpisodeListPayload(uid: uid) else {
                        return true
                    }
                    return Self.episodeListFingerprintComponent(payload)
                        != Self.episodeListFingerprintComponent(defaultPayload)
                }
                let hasLocalMainMenuListSettings = ((subscriptionListSettingsPayload["mainMenuListUIDs"] as? [String]) ?? [])
                    != Self.defaultMainMenuListUIDs()
                if isFormatMigration,
                   !hasLocalManualFeedOrder,
                   !hasLocalEpisodeListSettings,
                   !hasLocalMainMenuListSettings {
                    // Baseline format migration on a sort-mode-only device: nothing worth
                    // publishing — record the baseline silently so only a REAL future
                    // change publishes. A migration publish from here would race the
                    // manual-order device's repair publish under last-writer-wins.
                    setSyncMetadata(fingerprint, forKey: Self.subscriptionListSettingsBaselineKey)
                } else {
                    guard let intent = persistPendingSingletonUploadIntent(
                        for: subscriptionListSettingsRecordID(),
                        payload: subscriptionListSettingsPayload
                    ) else { return }
                    setSyncMetadata(fingerprint, forKey: Self.subscriptionListSettingsBaselineKey)
                    setSyncMetadata(intent.modifiedAt, forKey: Self.subscriptionListSettingsLocalModifiedDateKey)
                    if subscriptionsSyncEnabled {
                        addPendingSave(subscriptionListSettingsRecordID())
                    }
                }
            }
        }
    }

    func episodeListPayloads(in context: NSManagedObjectContext) -> [[String: Any]] {
        let request = NSFetchRequest<CDEpisodeList>(entityName: "EpisodeList")
        request.includesSubentities = false
        request.relationshipKeyPathsForPrefetching = ["includedFeeds"]
        request.sortDescriptors = [
            NSSortDescriptor(key: "rank", ascending: true),
            NSSortDescriptor(key: "uid", ascending: true),
        ]
        return ((try? context.fetch(request)) ?? []).compactMap {
            Self.episodeListPayloadForSyncEngineCallback($0)
        }
    }

    func subscriptionListSettingsPayload(in context: NSManagedObjectContext) -> [String: Any] {
        Self.subscriptionListSettingsPayloadForSyncEngineCallback(
            episodeListPayloads: episodeListPayloads(in: context)
        )
    }

    func subscriptionListSettingsFingerprint(in context: NSManagedObjectContext) -> String {
        Self.subscriptionListSettingsFingerprint(
            payload: subscriptionListSettingsPayload(in: context)
        )
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
        return syncedSettingsHash(values: domain)
    }

    func syncedSettingsHash(payload: [String: Any]) -> String? {
        guard let values = payload["values"] as? [String: Any] else { return nil }
        return syncedSettingsHash(values: values)
    }

    private func syncedSettingsHash(values: [String: Any]) -> String {
        var components: [String] = []
        let nonDefaultValues = Self.syncableNonDefaultSettingsValuesForSyncEngineCallback(values)
        for (key, value) in nonDefaultValues {
            components.append("\(key)=\(value)")
        }
        return Self.sha256Hex(components.sorted().joined(separator: "\u{1}"))
    }

    func queueListScrollPositionsRecord() {
        if queuePendingSingletonUploadWithoutReplacingIntent(
            recordName: RecordPrefix.listScrollPositions
        ) {
            scheduleLowPrioritySync()
        }
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
