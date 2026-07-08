//
//  ICiCloudSyncManager+EngineRecords.swift
//  Instacast
//
//  CKSyncEngine delegate callbacks and record/payload builders.
//

@preconcurrency import CloudKit
import CoreData
import CryptoKit
import Darwin
import Foundation
import UIKit

@available(iOS 17.0, *)
extension ICiCloudSyncManager {

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handleEventOnMain(event, syncEngine: syncEngine)
    }

    func handleEventOnMain(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let event):
            persistStateSerialization(event.stateSerialization)

        case .accountChange(let event):
            handleAccountChange(event)

        case .fetchedDatabaseChanges(let event):
            handleFetchedDatabaseChanges(event)

        case .fetchedRecordZoneChanges(let event):
            await handleFetchedRecordZoneChanges(event)

        case .sentDatabaseChanges(let event):
            handleSentDatabaseChanges(event)

        case .sentRecordZoneChanges(let event):
            await handleSentRecordZoneChanges(event, syncEngine: syncEngine)

        case .willFetchChanges, .willFetchRecordZoneChanges:
            beginSyncActivity(.down)
            postStateChanged()

        case .willSendChanges:
            hasUnresolvedSyncFailures = false
            beginSyncActivity(.up)
            postStateChanged()

        case .didFetchChanges:
            // The first complete fetch after (re-)enabling subscription sync has been
            // processed (its catch-up deletions were suppressed) — deletions arriving
            // from now on are live propagation and are applied again. Must happen here,
            // after a real FETCH, not in markSyncCompleted: during the backfill a run can
            // complete with sends only, and the catch-up fetch comes later.
            if subscriptionsSyncEnabled, !hasUnresolvedSyncFailures, !hasInitialUploadBackfillWork,
               defaults.bool(forKey: Self.suppressSubscriptionDeletionsKey) {
                defaults.removeObject(forKey: Self.suppressSubscriptionDeletionsKey)
                logSyncEvent("Abo-Löschungs-Unterdrückung beendet (erster Fetch abgeschlossen)")
            }
            // Initial settings publish, fetch-gated: the first complete fetch after
            // enabling settings sync brought no remote settings record (a parked
            // payload means one DID arrive and the user's choice is still pending) —
            // this device's settings seed the cloud.
            if settingsSyncEnabled, !hasUnresolvedSyncFailures,
               defaults.bool(forKey: Self.initialSettingsBackfillPendingKey),
               !hasPendingInitialSettingsChoice {
                defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
                setSettingsLocalModifiedDate(Date())
                setStoredSyncedSettingsHash(syncedSettingsHash())
                addPendingSave(appSettingsRecordID())
                logSyncEvent("Initiale Einstellungen werden hochgeladen (keine in iCloud gefunden)")
            }
            markSyncCompletedIfFinished()

        case .didFetchRecordZoneChanges(let event):
            if let error = event.error {
                hasUnresolvedSyncFailures = true
                setError(error)
                scheduleSyncRetryAfterFailure(error: error, reason: "fetchZoneChanges")
            } else {
                markSyncCompletedIfFinished()
            }

        case .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scopedChanges = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !scopedChanges.isEmpty else { return nil }

        let snapshot = Self.syncEngineCallbackSnapshot()
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var staleSaveChanges: [CKSyncEngine.PendingRecordZoneChange] = []

        var saveRecordIDs: [CKRecord.ID] = []
        var validChangeCount = 0
        for change in scopedChanges {
            if validChangeCount >= Self.maximumRecordZoneChangesPerBatch { break }

            switch change {
            case .saveRecord(let recordID):
                saveRecordIDs.append(recordID)
                validChangeCount += 1
            case .deleteRecord(let recordID):
                recordIDsToDelete.append(recordID)
                validChangeCount += 1

            @unknown default:
                break
            }
        }

        // Materialize the whole batch with ONE Core Data fetch for the episodes instead of a
        // fresh background context + fetch per record. The per-record approach was the upload
        // bottleneck (1-2 min for 4400 episodes) and the store-lock contention that froze the UI.
        let materialized = Self.materializeRecordsForSyncEngineCallback(saveRecordIDs, snapshot: snapshot)
        recordsToSave = materialized.records
        staleSaveChanges = materialized.stale

        if !staleSaveChanges.isEmpty {
            let staleUserDataSaveChanges = staleSaveChanges.filter { change in
                if case .saveRecord(let recordID) = change {
                    return Self.isUserDataRecordName(recordID.recordName)
                }
                return false
            }
            if !staleUserDataSaveChanges.isEmpty {
                Self.logStaleUserDataSaveChanges(staleUserDataSaveChanges, snapshot: snapshot, pendingRecordZoneChanges: syncEngine.state.pendingRecordZoneChanges.count)
            }
            syncEngine.state.remove(pendingRecordZoneChanges: staleSaveChanges)
        }

        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }
        Self.logSyncEvent("CKSyncEngine-Send-Batch materialisiert", snapshot: snapshot, pendingRecordZoneChanges: syncEngine.state.pendingRecordZoneChanges.count, metadata: [
            "scopedChanges": scopedChanges.count,
            "recordsToSave": recordsToSave.count,
            "recordIDsToDelete": recordIDsToDelete.count,
            "staleSaveChanges": staleSaveChanges.count,
            "validChangeCount": validChangeCount,
            // Identifies what keeps re-queueing in repeated small batches (record names
            // carry only hashes/prefixes, no user content).
            "recordNames": recordsToSave.prefix(6).map { $0.recordID.recordName }.joined(separator: ","),
            "deleteNames": recordIDsToDelete.prefix(3).map { $0.recordName }.joined(separator: ","),
        ])
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: recordsToSave,
                                                  recordIDsToDelete: recordIDsToDelete,
                                                  atomicByZone: false)
    }

    nonisolated static func materializeRecordsForSyncEngineCallback(_ recordIDs: [CKRecord.ID], snapshot: SyncEngineCallbackSnapshot) -> (records: [CKRecord], stale: [CKSyncEngine.PendingRecordZoneChange]) {
        var records: [CKRecord] = []
        var stale: [CKSyncEngine.PendingRecordZoneChange] = []

        let episodeRecordIDs = recordIDs.filter { $0.recordName.hasPrefix(RecordPrefix.episode) }
        if !episodeRecordIDs.isEmpty {
            if snapshot.episodesSyncEnabled {
                let statesByHash = episodeStatesByObjectHash(episodeRecordIDs.map { String($0.recordName.dropFirst(RecordPrefix.episode.count)) })
                for recordID in episodeRecordIDs {
                    let objectHash = String(recordID.recordName.dropFirst(RecordPrefix.episode.count))
                    guard var payload = statesByHash[objectHash] else {
                        stale.append(.saveRecord(recordID))
                        continue
                    }
                    let updatedAt = date(from: snapshot.episodeLocalModifiedDates[objectHash]) ?? Date()
                    payload["updatedAt"] = updatedAt
                    let record = mutableRecordForSyncEngineCallback(recordType: RecordKind.episodeState, recordID: recordID)
                    populateForSyncEngineCallback(record, payload: payload, updatedAt: updatedAt, deviceID: snapshot.deviceID)
                    records.append(record)
                }
            } else {
                stale.append(contentsOf: episodeRecordIDs.map { .saveRecord($0) })
            }
        }

        // Subscriptions get the same one-fetch-per-batch treatment as episodes. The previous
        // per-record path (fresh background context + feed fetch + a relationship fault per
        // feed property) was the same store-lock-contention pattern that froze the UI when
        // toggling episode sync — just triggered by the subscriptions switch instead.
        let subscriptionRecordIDs = recordIDs.filter { $0.recordName.hasPrefix(RecordPrefix.subscription) }
        if !subscriptionRecordIDs.isEmpty {
            if snapshot.subscriptionsSyncEnabled {
                let feedURLs = subscriptionRecordIDs.compactMap { snapshot.subscriptionRecordURLs[$0.recordName] }
                let payloadsByURL = subscriptionPayloadsByFeedURL(feedURLs, deviceID: snapshot.deviceID)
                for recordID in subscriptionRecordIDs {
                    guard let feedURL = snapshot.subscriptionRecordURLs[recordID.recordName],
                          var payload = payloadsByURL[feedURL] else {
                        stale.append(.saveRecord(recordID))
                        continue
                    }
                    let updatedAt = date(from: snapshot.subscriptionLocalModifiedDates[feedURL]) ?? Date()
                    payload["updatedAt"] = updatedAt
                    let record = mutableRecordForSyncEngineCallback(recordType: RecordKind.subscription, recordID: recordID)
                    populateForSyncEngineCallback(record, payload: payload, updatedAt: updatedAt, deviceID: snapshot.deviceID)
                    records.append(record)
                }
            } else {
                stale.append(contentsOf: subscriptionRecordIDs.map { .saveRecord($0) })
            }
        }

        // Device / settings / scroll records — only a handful per batch.
        for recordID in recordIDs
        where !recordID.recordName.hasPrefix(RecordPrefix.episode) && !recordID.recordName.hasPrefix(RecordPrefix.subscription) {
            if let record = recordToSaveForSyncEngineCallback(for: recordID, snapshot: snapshot) {
                records.append(record)
            } else {
                stale.append(.saveRecord(recordID))
            }
        }
        return (records, stale)
    }

    nonisolated static func logStaleUserDataSaveChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange], snapshot: SyncEngineCallbackSnapshot, pendingRecordZoneChanges: Int) {
        let recordNames = changes.compactMap { change -> String? in
            if case .saveRecord(let recordID) = change {
                return recordID.recordName
            }
            return nil
        }
        logSyncEvent("iCloud Upload-Nutzerdaten nicht materialisiert", snapshot: snapshot, pendingRecordZoneChanges: pendingRecordZoneChanges, metadata: [
            "staleUserDataSaveChanges": recordNames.count,
            "recordNames": recordNames.prefix(8).joined(separator: ","),
        ])
    }

    // One fetch (with the properties relationship prefetched) for the whole batch instead of
    // a context + fetch + property faults per subscription record.
    nonisolated static func subscriptionPayloadsByFeedURL(_ feedURLs: [String], deviceID: String) -> [String: [String: Any]] {
        guard !feedURLs.isEmpty, let context = DatabaseManager.shared()?.newBackgroundContext() else { return [:] }
        return context.performAndWait {
            let request = NSFetchRequest<CDFeed>(entityName: "Feed")
            request.predicate = NSPredicate(format: "sourceURL_ IN %@ AND subscribed == YES", feedURLs)
            request.includesSubentities = false
            request.relationshipKeyPathsForPrefetching = ["properties"]
            let feeds = (try? context.fetch(request)) ?? []
            var result: [String: [String: Any]] = [:]
            for feed in feeds {
                guard let feedURL = feed.value(forKey: "sourceURL_") as? String else { continue }
                result[feedURL] = subscriptionPayload(for: feed, feedURL: feedURL, deviceID: deviceID)
            }
            return result
        }
    }

    // The caller stamps "updatedAt" before populating the record.
    nonisolated static func subscriptionPayload(for feed: CDFeed, feedURL: String, deviceID: String) -> [String: Any] {
        let feedUID = feed.uid
        var properties: [[String: Any]] = []
        for property in feed.properties as? Set<CDFeedProperty> ?? [] {
            guard let key = property.key, !internalFeedPropertyKeys.contains(key) else { continue }
            var propertyPayload: [String: Any] = [
                "key": stableFeedPropertyKey(key, feedUID: feedUID),
                "valueType": Self.feedPropertyValueType(for: property),
                "boolValue": property.boolValue,
                "int32Value": Int(property.int32Value),
                "doubleValue": property.doubleValue,
            ]
            if let stringValue = property.stringValue {
                propertyPayload["stringValue"] = stringValue
            }
            properties.append(propertyPayload)
        }

        return [
            "feedURL": feedURL,
            "title": feed.title ?? "",
            "rank": Int(feed.rank),
            "parked": feed.parked,
            "username": feed.username ?? "",
            "password": feed.password ?? "",
            "properties": properties,
            "deviceID": deviceID,
        ]
    }

    nonisolated static func episodeStatesByObjectHash(_ objectHashes: [String]) -> [String: [String: Any]] {
        guard !objectHashes.isEmpty, let context = DatabaseManager.shared()?.newBackgroundContext() else { return [:] }
        return context.performAndWait {
            let request = NSFetchRequest<CDEpisode>(entityName: "Episode")
            request.predicate = NSPredicate(format: "objectHash IN %@", objectHashes)
            request.includesSubentities = false
            let episodes = (try? context.fetch(request)) ?? []
            var result: [String: [String: Any]] = [:]
            for episode in episodes {
                guard let objectHash = episode.objectHash else { continue }
                result[objectHash] = [
                    "objectHash": objectHash,
                    "played": episode.consumed,
                    "position": Int(episode.position),
                    "starred": episode.starred,
                ]
            }
            return result
        }
    }

    struct SyncEngineCallbackSnapshot {
        let episodesSyncEnabled: Bool
        let subscriptionsSyncEnabled: Bool
        let settingsSyncEnabled: Bool
        let anySyncEnabled: Bool
        let deviceID: String
        let deviceRecordShouldStampSyncDate: Bool
        let subscriptionRecordURLs: [String: String]
        let episodeLocalModifiedDates: [String: TimeInterval]
        let subscriptionLocalModifiedDates: [String: TimeInterval]
        let settingsLocalModifiedDate: Date?
        let scrollPositionsLocalModifiedDate: Date?
        let lastSyncDate: Date?
    }

    nonisolated static func syncEngineCallbackSnapshot() -> SyncEngineCallbackSnapshot {
        let defaults = UserDefaults.standard
        let episodesEnabled = defaults.bool(forKey: ICiCloudSyncEpisodesEnabled)
        let subscriptionsEnabled = defaults.bool(forKey: ICiCloudSyncSubscriptionsEnabled)
        let settingsEnabled = defaults.bool(forKey: ICiCloudSyncSettingsEnabled)
        return SyncEngineCallbackSnapshot(
            episodesSyncEnabled: episodesEnabled,
            subscriptionsSyncEnabled: subscriptionsEnabled,
            settingsSyncEnabled: settingsEnabled,
            anySyncEnabled: episodesEnabled || subscriptionsEnabled || settingsEnabled,
            deviceID: deviceIDForSyncEngineCallback(),
            deviceRecordShouldStampSyncDate: defaults.bool(forKey: Self.deviceRecordShouldStampSyncDateKey),
            subscriptionRecordURLs: syncMetadataValue(forKey: Self.subscriptionRecordURLsKey) as? [String: String] ?? [:],
            episodeLocalModifiedDates: syncMetadataValue(forKey: Self.episodeLocalModifiedDatesKey) as? [String: TimeInterval] ?? [:],
            subscriptionLocalModifiedDates: syncMetadataValue(forKey: Self.subscriptionLocalModifiedDatesKey) as? [String: TimeInterval] ?? [:],
            settingsLocalModifiedDate: defaults.object(forKey: Self.settingsLocalModifiedDateKey) as? Date,
            scrollPositionsLocalModifiedDate: defaults.object(forKey: Self.scrollPositionsLocalModifiedDateKey) as? Date,
            lastSyncDate: defaults.object(forKey: Self.lastSyncDateKey) as? Date
        )
    }

    // Episode and subscription records are materialized in batches with a single fetch —
    // see materializeRecordsForSyncEngineCallback. This handles only the singleton records.
    nonisolated static func recordToSaveForSyncEngineCallback(for recordID: CKRecord.ID, snapshot: SyncEngineCallbackSnapshot) -> CKRecord? {
        if recordID.recordName.hasPrefix(RecordPrefix.device) {
            return deviceRecordForSyncEngineCallback(for: recordID, snapshot: snapshot)
        }
        if recordID.recordName == RecordPrefix.appSettings {
            guard snapshot.settingsSyncEnabled else { return nil }
            return appSettingsRecordForSyncEngineCallback(for: recordID, snapshot: snapshot)
        }
        if recordID.recordName == RecordPrefix.listScrollPositions {
            guard snapshot.episodesSyncEnabled else { return nil }
            return listScrollPositionsRecordForSyncEngineCallback(for: recordID, snapshot: snapshot)
        }
        if recordID.recordName == RecordPrefix.subscriptionListSettings {
            guard snapshot.subscriptionsSyncEnabled else { return nil }
            return subscriptionListSettingsRecordForSyncEngineCallback(for: recordID, snapshot: snapshot)
        }
        return nil
    }

    // The feed-list sort mode and the saved manual order belong to the SUBSCRIPTIONS:
    // they sync with subscription sync (not settings sync), so a device that only has
    // subscriptions enabled shows the same list the same way. Without the saved manual
    // order, "Manual" was not even offered in the receiving device's sort menu.
    nonisolated static func subscriptionListSettingsRecordForSyncEngineCallback(for recordID: CKRecord.ID, snapshot: SyncEngineCallbackSnapshot) -> CKRecord {
        let defaults = UserDefaults.standard
        let updatedAt = defaults.object(forKey: Self.subscriptionListSettingsLocalModifiedDateKey) as? Date ?? Date()
        var payload: [String: Any] = [
            "sortMode": defaults.string(forKey: FeedListSortMode) ?? "",
            "updatedAt": updatedAt,
        ]
        if let manualOrder = defaults.array(forKey: Self.manualFeedOrderDefaultsKey) as? [String], !manualOrder.isEmpty {
            payload["manualOrder"] = manualOrder
        }
        payload["episodeLists"] = episodeListPayloadsForSyncEngineCallback()
        payload["mainMenuListUIDs"] = mainMenuListUIDsForSyncEngineCallback()
        let record = mutableRecordForSyncEngineCallback(recordType: RecordKind.subscriptionListSettings, recordID: recordID)
        populateForSyncEngineCallback(record, payload: payload, updatedAt: updatedAt, deviceID: snapshot.deviceID)
        return record
    }

    // The "v2:" format prefix makes migrated baselines recognizable: on a baseline
    // written by an older build, checkAndQueueSettingsChange decides between a one-time
    // repair re-publish (device owns a manual order) and silently recording the baseline
    // (sort-mode-only device — publishing would race the real state under LWW; exactly
    // that race flipped the iPhone off "manual" once).
    nonisolated static let subscriptionListSettingsFingerprintPrefix = "v3:"

    nonisolated static func subscriptionListSettingsFingerprint() -> String {
        let defaults = UserDefaults.standard
        let sortMode = defaults.string(forKey: FeedListSortMode) ?? ""
        let manualOrder = (defaults.array(forKey: manualFeedOrderDefaultsKey) as? [String]) ?? []
        var components = ["sortMode=\(sortMode)", "manualOrder=\(manualOrder.joined(separator: "\u{1}"))"]
        components.append("mainMenuListUIDs=\(mainMenuListUIDsForSyncEngineCallback().joined(separator: "\u{1}"))")
        components.append(contentsOf: episodeListPayloadsForSyncEngineCallback().map { episodeListFingerprintComponent($0) })
        return subscriptionListSettingsFingerprintPrefix + sha256Hex(components.joined(separator: "\u{2}"))
    }

    nonisolated static func episodeListPayloadsForSyncEngineCallback() -> [[String: Any]] {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else { return [] }
        return context.performAndWait {
            let request = NSFetchRequest<CDEpisodeList>(entityName: "EpisodeList")
            request.includesSubentities = false
            request.relationshipKeyPathsForPrefetching = ["includedFeeds"]
            request.sortDescriptors = [
                NSSortDescriptor(key: "rank", ascending: true),
                NSSortDescriptor(key: "uid", ascending: true),
            ]
            let lists = (try? context.fetch(request)) ?? []
            return lists.compactMap { episodeListPayloadForSyncEngineCallback($0) }
        }
    }

    nonisolated static func episodeListPayloadForSyncEngineCallback(_ list: CDEpisodeList) -> [String: Any]? {
        guard let uid = list.uid, !uid.isEmpty else { return nil }
        let includedFeedURLs = ((list.includedFeeds as? Set<CDFeed>) ?? [])
            .compactMap { $0.value(forKey: "sourceURL_") as? String }
            .sorted()
        return [
            "uid": uid,
            "name": list.name ?? "",
            "icon": list.icon ?? "",
            "rank": Int(list.rank),
            "query": list.query ?? "",
            "audio": list.audio,
            "video": list.video,
            "downloaded": list.downloaded,
            "downloading": list.downloading,
            "notDownloaded": list.notDownloaded,
            "unplayed": list.unplayed,
            "unfinished": list.unfinished,
            "played": list.played,
            "starred": list.starred,
            "notStarred": list.notStarred,
            "orderBy": list.orderBy ?? "",
            "descending": list.descending,
            "groupByPodcast": list.groupByPodcast,
            "continuousPlayback": list.continuousPlayback,
            "includedFeedURLs": includedFeedURLs,
        ]
    }

    nonisolated static func mainMenuListUIDsForSyncEngineCallback() -> [String] {
        UserDefaults.standard.array(forKey: "MainMenuListUIDs") as? [String] ?? []
    }

    nonisolated static func episodeListFingerprintComponent(_ payload: [String: Any]) -> String {
        let keys = [
            "uid", "name", "icon", "rank", "query", "audio", "video", "downloaded",
            "downloading", "notDownloaded", "unplayed", "unfinished", "played",
            "starred", "notStarred", "orderBy", "descending", "groupByPodcast",
            "continuousPlayback",
        ]
        var components = keys.map { key in "\(key)=\(payload[key] ?? "")" }
        let includedFeedURLs = payload["includedFeedURLs"] as? [String] ?? []
        components.append("includedFeedURLs=\(includedFeedURLs.joined(separator: "\u{1}"))")
        return components.joined(separator: "\u{1}")
    }

    // A device without any list sort state (fresh install, sort menu never used) has
    // nothing to publish — and must never defend that emptiness under last-writer-wins.
    nonisolated static func hasLocalSubscriptionListSettings() -> Bool {
        let defaults = UserDefaults.standard
        if let sortMode = defaults.string(forKey: FeedListSortMode), !sortMode.isEmpty { return true }
        if let manualOrder = defaults.array(forKey: manualFeedOrderDefaultsKey) as? [String], !manualOrder.isEmpty { return true }
        if hasLocalEpisodeListSettings() { return true }
        if hasLocalMainMenuListSettings() { return true }
        return false
    }

    nonisolated static func hasLocalManualFeedOrder() -> Bool {
        let manualOrder = UserDefaults.standard.array(forKey: manualFeedOrderDefaultsKey) as? [String]
        return manualOrder?.isEmpty == false
    }

    nonisolated static func hasLocalSubscriptionListSettingsForInitialBackfill() -> Bool {
        hasLocalManualFeedOrder() || hasLocalEpisodeListSettings() || hasLocalMainMenuListSettings()
    }

    nonisolated static func hasLocalEpisodeListSettings() -> Bool {
        for payload in episodeListPayloadsForSyncEngineCallback() {
            guard let uid = payload["uid"] as? String else { continue }
            guard let defaultPayload = defaultEpisodeListPayload(uid: uid) else { return true }
            if episodeListFingerprintComponent(payload) != episodeListFingerprintComponent(defaultPayload) {
                return true
            }
        }
        return false
    }

    nonisolated static func hasLocalMainMenuListSettings() -> Bool {
        guard UserDefaults.standard.object(forKey: "MainMenuListUIDs") != nil else { return false }
        return mainMenuListUIDsForSyncEngineCallback() != defaultMainMenuListUIDs()
    }

    nonisolated static func defaultMainMenuListUIDs() -> [String] {
        ["default.favorites", "default.unplayed", "default.started", "default.downloaded"]
    }

    nonisolated static func defaultEpisodeListPayload(uid: String) -> [String: Any]? {
        let defaults: [String: [String: Any]] = [
            "default.favorites": [
                "uid": "default.favorites",
                "name": NSLocalizedString("Favorites", comment: ""),
                "icon": "List Favorites",
                "rank": 0,
                "query": "",
                "audio": true,
                "video": true,
                "downloaded": true,
                "downloading": true,
                "notDownloaded": true,
                "unplayed": true,
                "unfinished": true,
                "played": true,
                "starred": true,
                "notStarred": false,
                "orderBy": "pubDate",
                "descending": true,
                "groupByPodcast": false,
                "continuousPlayback": true,
                "includedFeedURLs": [],
            ],
            "default.unplayed": [
                "uid": "default.unplayed",
                "name": NSLocalizedString("Unplayed", comment: ""),
                "icon": "List Unplayed",
                "rank": 1,
                "query": "",
                "audio": true,
                "video": true,
                "downloaded": true,
                "downloading": true,
                "notDownloaded": true,
                "unplayed": true,
                "unfinished": true,
                "played": false,
                "starred": true,
                "notStarred": true,
                "orderBy": "pubDate",
                "descending": true,
                "groupByPodcast": false,
                "continuousPlayback": true,
                "includedFeedURLs": [],
            ],
            "default.started": [
                "uid": "default.started",
                "name": NSLocalizedString("Started", comment: ""),
                "icon": "List Partially Played",
                "rank": 2,
                "query": "",
                "audio": true,
                "video": true,
                "downloaded": true,
                "downloading": true,
                "notDownloaded": true,
                "unplayed": false,
                "unfinished": true,
                "played": false,
                "starred": true,
                "notStarred": true,
                "orderBy": "lastPlayed",
                "descending": true,
                "groupByPodcast": false,
                "continuousPlayback": true,
                "includedFeedURLs": [],
            ],
            "default.downloaded": [
                "uid": "default.downloaded",
                "name": NSLocalizedString("Downloaded", comment: ""),
                "icon": "List Downloaded",
                "rank": 3,
                "query": "",
                "audio": true,
                "video": true,
                "downloaded": true,
                "downloading": true,
                "notDownloaded": false,
                "unplayed": true,
                "unfinished": true,
                "played": true,
                "starred": true,
                "notStarred": true,
                "orderBy": "pubDate",
                "descending": true,
                "groupByPodcast": false,
                "continuousPlayback": true,
                "includedFeedURLs": [],
            ],
            "default.video": [
                "uid": "default.video",
                "name": NSLocalizedString("Videos", comment: ""),
                "icon": "List Video",
                "rank": 4,
                "query": "",
                "audio": false,
                "video": true,
                "downloaded": true,
                "downloading": true,
                "notDownloaded": true,
                "unplayed": true,
                "unfinished": true,
                "played": true,
                "starred": true,
                "notStarred": true,
                "orderBy": "pubDate",
                "descending": true,
                "groupByPodcast": false,
                "continuousPlayback": true,
                "includedFeedURLs": [],
            ],
        ]
        return defaults[uid]
    }

    nonisolated static func deviceRecordForSyncEngineCallback(for recordID: CKRecord.ID, snapshot: SyncEngineCallbackSnapshot) -> CKRecord {
        let now = Date()
        var payload = localDevicePayloadForSyncEngineCallback(snapshot: snapshot)
        if snapshot.deviceRecordShouldStampSyncDate {
            payload["lastSyncDate"] = now
        }
        payload["updatedAt"] = now
        let record = mutableRecordForSyncEngineCallback(recordType: RecordKind.device, recordID: recordID)
        populateForSyncEngineCallback(record, payload: payload, updatedAt: now, deviceID: snapshot.deviceID)
        record["deviceID"] = snapshot.deviceID as CKRecordValue
        return record
    }


    // Some feed-property keys embed the feed's `uid`, e.g. "<uid>_auto_skip_chapter_name" (the
    // auto-skip chapter terms + per-chapter offsets). `uid` is a *per-device* random UUID, so a
    // literal key would never match on another device. We translate the local uid prefix to a
    // stable marker on upload and back to the receiving device's own uid on apply, so these
    // settings actually sync. (Feeds themselves sync by URL hash, episodes by content hash —
    // those were already device-stable; only these uid-prefixed properties were broken.)
    nonisolated static let feedUIDKeyMarker = "@@FEEDUID@@"

    nonisolated static func stableFeedPropertyKey(_ key: String, feedUID: String?) -> String {
        guard let feedUID, !feedUID.isEmpty, key.hasPrefix(feedUID + "_") else { return key }
        return feedUIDKeyMarker + key.dropFirst(feedUID.count)
    }

    nonisolated static func localFeedPropertyKey(_ key: String, feedUID: String?) -> String {
        guard key.hasPrefix(feedUIDKeyMarker) else { return key }
        let suffix = key.dropFirst(feedUIDKeyMarker.count)
        guard let feedUID, !feedUID.isEmpty else { return String(suffix) }
        return feedUID + suffix
    }

    nonisolated static func appSettingsRecordForSyncEngineCallback(for recordID: CKRecord.ID, snapshot: SyncEngineCallbackSnapshot) -> CKRecord {
        let updatedAt = snapshot.settingsLocalModifiedDate ?? Date()
        let record = mutableRecordForSyncEngineCallback(recordType: RecordKind.appSettings, recordID: recordID)
        populateForSyncEngineCallback(record, payload: appSettingsPayloadForSyncEngineCallback(updatedAt: updatedAt, deviceID: snapshot.deviceID), updatedAt: updatedAt, deviceID: snapshot.deviceID)
        return record
    }

    nonisolated static func listScrollPositionsRecordForSyncEngineCallback(for recordID: CKRecord.ID, snapshot: SyncEngineCallbackSnapshot) -> CKRecord {
        let updatedAt = snapshot.scrollPositionsLocalModifiedDate ?? ICListScrollPositionsLastModifiedDate() ?? Date()
        let payload: [String: Any] = [
            "positions": ICListScrollPositionsSnapshot() ?? [:],
            "lastModified": updatedAt,
            "deviceID": snapshot.deviceID,
            "updatedAt": updatedAt,
        ]
        let record = mutableRecordForSyncEngineCallback(recordType: RecordKind.listScrollPositions, recordID: recordID)
        populateForSyncEngineCallback(record, payload: payload, updatedAt: updatedAt, deviceID: snapshot.deviceID)
        return record
    }

    nonisolated static func mutableRecordForSyncEngineCallback(recordType: CKRecord.RecordType, recordID: CKRecord.ID) -> CKRecord {
        if let knownRecord = knownRecordForSyncEngineCallback(for: recordID), knownRecord.recordType == recordType {
            return knownRecord
        }
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    nonisolated static func populateForSyncEngineCallback(_ record: CKRecord, payload: [String: Any], updatedAt: Date, deviceID: String) {
        record["schemaVersion"] = Self.schemaVersion as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
        record["deviceID"] = deviceID as CKRecordValue
        if let data = propertyListDataForSyncEngineCallback(from: payload) {
            record.encryptedValues["payload"] = data as CKRecordValue
        }
    }

    nonisolated static func localDevicePayloadForSyncEngineCallback(snapshot: SyncEngineCallbackSnapshot) -> [String: Any] {
        devicePayload(deviceID: snapshot.deviceID,
                      episodesEnabled: snapshot.episodesSyncEnabled,
                      subscriptionsEnabled: snapshot.subscriptionsSyncEnabled,
                      settingsEnabled: snapshot.settingsSyncEnabled,
                      lastSyncDate: snapshot.lastSyncDate)
    }

    // Single builder for this device's payload — used for both the uploaded record and the
    // locally merged device-list entry. There used to be two near-duplicates (one UIDevice-,
    // one ProcessInfo-based), so the local list showed different values than other devices
    // received for the same device.
    nonisolated static func devicePayload(deviceID: String,
                                                  episodesEnabled: Bool,
                                                  subscriptionsEnabled: Bool,
                                                  settingsEnabled: Bool,
                                                  lastSyncDate: Date?) -> [String: Any] {
        let marketingName = deviceMarketingNameForSyncEngineCallback()
        var payload: [String: Any] = [
            "deviceID": deviceID,
            "name": marketingName,
            "model": marketingName,
            "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": appVersionStringForSyncEngineCallback(),
            "episodesEnabled": episodesEnabled,
            "subscriptionsEnabled": subscriptionsEnabled,
            "settingsEnabled": settingsEnabled,
        ]
        if let lastSyncDate {
            payload["lastSyncDate"] = lastSyncDate
        }
        return payload
    }

    nonisolated static func appSettingsPayloadForSyncEngineCallback(updatedAt: Date, deviceID: String) -> [String: Any] {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        var values: [String: Any] = [:]
        for (key, value) in domain {
            guard shouldSyncSettingsKeyForSyncEngineCallback(key), isValidSettingsValueForSyncEngineCallback(value) else { continue }
            values[key] = value
        }

        let credentials = ICRemoteChapterCredentialStore.backupCredentialValues()
        return [
            "values": values,
            "credentials": credentials,
            "deviceID": deviceID,
            "updatedAt": updatedAt,
        ]
    }

    nonisolated static func shouldSyncSettingsKeyForSyncEngineCallback(_ key: String) -> Bool {
        if syncMetadataKeysForSyncEngineCallback().contains(key) { return false }
        if key.hasPrefix("ICiCloudSync") { return false }
        if transientSettingsKeysForSyncEngineCallback().contains(key) { return false }
        if nonSettingsUserDefaultsKeysForSyncEngineCallback().contains(key) { return false }
        return true
    }

    nonisolated static func syncMetadataKeysForSyncEngineCallback() -> Set<String> {
        [
            Self.deviceIDKey,
            Self.engineStateKey,
            Self.knownRecordsKey,
            Self.deviceCacheKey,
            Self.subscriptionRecordURLsKey,
            Self.pendingEpisodeStatesKey,
            Self.pendingSubscriptionPayloadsKey,
            Self.episodeLocalModifiedDatesKey,
            Self.subscriptionLocalModifiedDatesKey,
            Self.settingsLocalModifiedDateKey,
            Self.settingsSyncedHashKey,
            Self.scrollPositionsLocalModifiedDateKey,
            Self.lastSyncDateKey,
            Self.lastStatusKey,
            Self.lastErrorKey,
            Self.deviceRecordShouldStampSyncDateKey,
        ]
    }

    nonisolated static func transientSettingsKeysForSyncEngineCallback() -> Set<String> {
        [
            LastRefreshSubscriptionDate,
            FirstLaunchDate,
            kUIPersistenceMainSidebarItem,
            kUIPersistenceSubscriptionsSelectedFeedUID,
            kUIPersistenceSubscriptionsSearchTerm,
            kUIPersistencePlaylistsSelectedPlaylistUID,
            kUIPersistenceBookmarkSelectedEpisodeGUID,
            kUIPersistenceDirectorySearchSearchString,
            kUIPersistenceDirectorySearchSelectedScopeIndex,
            UIStateSelectedFeed,
            UIStateSelectedEpisode,
            kUIPersistenceListScrollPositions,
            kUIPersistenceListScrollPositionsLastModified,
            UncompletedSleepTimeInterval,
            "TranscriptionBackgroundTaskActive",
            // Device-local playback restore state (AudioSession kPlaybackState* keys).
            // Syncing PlaybackEpisode dirtied the settings hash on EVERY episode change
            // (one settings upload per switch) and made another device restore this
            // device's episode after a restart. Positions sync via episode states.
            "PlaybackEpisode",
            "PlaybackPlaylist",
            "PlaybackSourceList",
            // Per-device statistics counters (User-Entscheid 08.07.: Statistiken bleiben
            // lokal). Synced as settings, last-writer-wins overwrote one device's counts
            // with another's on every settings apply.
            "TotalEpisodesPlayedCount",
            "TotalListeningTime",
            "SleepTimerFellAsleepCount",
            // Travels with subscription sync (ICSubscriptionListSettings), not settings sync.
            FeedListSortMode,
            "MainMenuListUIDs",
        ]
    }

    nonisolated static func nonSettingsUserDefaultsKeysForSyncEngineCallback() -> Set<String> {
        [
            "DownloadResumeInfos",
            "DownloadResumeInfos_NSURLSession",
            "EpisodeLoadingQueueKey",
            "ICDiagnosticPreviousSessionEndedInBackground",
            "ICDiagnosticPreviousSessionEndedUnexpectedly",
            "ICDiagnosticPreviousSessionState",
        ]
    }

    // Feed properties that are device-local bookkeeping and never synced.
    nonisolated static let internalFeedPropertyKeys: Set<String> = [
        "episodeLoadingComplete",
        "loadedEpisodeCount",
        "totalExpectedEpisodes",
        "cachedPlayerTintColor",
        "durationMetadataRefreshAttempted",
    ]

    nonisolated static func isValidSettingsValueForSyncEngineCallback(_ value: Any) -> Bool {
        switch value {
        case is String, is NSNumber, is Date:
            return true
        default:
            return false
        }
    }

    nonisolated static func knownRecordForSyncEngineCallback(for recordID: CKRecord.ID) -> CKRecord? {
        guard let data = knownRecordSystemFieldsData(forRecordName: recordID.recordName) else { return nil }
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            return CKRecord(coder: unarchiver)
        } catch {
            return nil
        }
    }

    nonisolated static func propertyListDataForSyncEngineCallback(from dictionary: [String: Any]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }

    nonisolated static func deviceIDForSyncEngineCallback() -> String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.deviceIDKey), !stored.isEmpty {
            return stored
        }
        let newID = UUID().uuidString
        defaults.set(newID, forKey: Self.deviceIDKey)
        return newID
    }

    nonisolated static func deviceMarketingNameForSyncEngineCallback() -> String {
        let identifier = deviceHardwareIdentifierForSyncEngineCallback()
        if let name = deviceMarketingNamesForSyncEngineCallback()[identifier] {
            return name
        }
        return identifier.isEmpty ? "Unknown Device" : identifier
    }

    nonisolated static func deviceHardwareIdentifierForSyncEngineCallback() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? ""
            }
        }
    }

    nonisolated static func appVersionStringForSyncEngineCallback() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if version.isEmpty { return build }
        if build.isEmpty { return version }
        return "\(version) (\(build))"
    }

    nonisolated static func deviceMarketingNamesForSyncEngineCallback() -> [String: String] {
        [
            "iPhone12,1": "iPhone 11",
            "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd generation)",
            "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air",
        ]
    }

    nonisolated static func date(from timeInterval: TimeInterval?) -> Date? {
        guard let timeInterval, timeInterval > 0 else { return nil }
        return Date(timeIntervalSince1970: timeInterval)
    }

    nonisolated static func logSyncEvent(_ message: String, snapshot: SyncEngineCallbackSnapshot, pendingRecordZoneChanges: Int, metadata: [String: Any] = [:]) {
        var details = metadata
        details["episodesSyncEnabled"] = snapshot.episodesSyncEnabled
        details["subscriptionsSyncEnabled"] = snapshot.subscriptionsSyncEnabled
        details["settingsSyncEnabled"] = snapshot.settingsSyncEnabled
        details["anySyncEnabled"] = snapshot.anySyncEnabled
        details["pendingRecordZoneChanges"] = pendingRecordZoneChanges
        details["isMainThread"] = Thread.isMainThread
        ICDiagnosticLogger.shared.logEvent("icloud-sync", message: message, metadata: details as NSDictionary)
    }
}
