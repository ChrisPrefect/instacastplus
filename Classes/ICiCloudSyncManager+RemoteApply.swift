//
//  ICiCloudSyncManager+RemoteApply.swift
//  Instacast
//
//  Fetched-event handling and applying remote records to the local model.
//

@preconcurrency import CloudKit
import CoreData
import CryptoKit
import Foundation
import UIKit

@available(iOS 17.0, *)
extension ICiCloudSyncManager {

    func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        clearError()

        switch event.changeType {
        case .signIn:
            setStatus(NSLocalizedString("iCloud angemeldet.", comment: ""))
            scheduleCurrentEnabledDataForUpload()
        case .signOut:
            setStatus(NSLocalizedString("Kein iCloud Account verfügbar.", comment: ""))
        case .switchAccounts:
            setSyncMetadata(nil, forKey: Self.engineStateKey)
            Self.removeSyncMetadataValue(forKey: Self.knownRecordsKey)
            Self.removeAllKnownRecordSystemFields()
            syncEngine = nil
            initializeSyncEngineIfNeeded()
            resetInitialBackfillCursorsForEnabledOptions()
            scheduleCurrentEnabledDataForUpload()
            setStatus(NSLocalizedString("iCloud Account gewechselt.", comment: ""))
        @unknown default:
            setStatus(NSLocalizedString("iCloud Account geändert.", comment: ""))
        }
    }

    func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for deletion in event.deletions where deletion.zoneID == zoneID {
            Self.removeSyncMetadataValue(forKey: Self.knownRecordsKey)
            Self.removeAllKnownRecordSystemFields()
            setSyncMetadata([String: [String: Any]](), forKey: Self.deviceCacheKey)
            scheduleCurrentEnabledDataForUpload()
        }
    }

    func handleFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        guard !event.modifications.isEmpty || !event.deletions.isEmpty else { return }

        if event.modifications.contains(where: { isUserDataRecordID($0.record.recordID) })
            || event.deletions.contains(where: { isUserDataRecordID($0.recordID) }) {
            syncedUserDataInCurrentRun = true
        }

        beginSyncActivity(.down)

        // Per-category progress for the status line ("Lädt herunter… 31/51 Abonnements").
        // orderedModifications groups the records by type, so the label switches once per
        // category instead of flickering.
        var expectedByType: [String: Int] = [:]
        for modification in event.modifications where isUserDataRecordID(modification.record.recordID) {
            expectedByType[modification.record.recordType, default: 0] += 1
        }

        isApplyingRemoteChange = true
        defer {
            isApplyingRemoteChange = false
            postStateChanged()
            postDevicesChanged()
        }

        var processedSinceYield = 0
        var modificationCountsByType: [String: Int] = [:]
        for modification in orderedModifications(event.modifications) {
            let record = modification.record
            modificationCountsByType[record.recordType, default: 0] += 1
            if isUserDataRecordID(record.recordID) {
                let label = Self.activityKindLabel(forRecordType: record.recordType)
                if label != syncActivityKindLabel {
                    syncActivityKindLabel = label
                    syncActivityRecordCount = 0
                    syncActivityExpectedCount = expectedByType[record.recordType] ?? 0
                }
            }
            rememberServerRecord(record)
            await applyRemoteRecord(record)
            if isUserDataRecordID(record.recordID) {
                recordSyncActivity(1)
            }
            // Yield periodically so a large initial download (thousands of episode
            // states on a fresh device) doesn't block the main thread in one go.
            processedSinceYield += 1
            if processedSinceYield >= 50 {
                processedSinceYield = 0
                postStateChanged()
                await Task.yield()
            }
        }

        for deletion in event.deletions {
            forgetServerRecord(for: deletion.recordID)
            applyRemoteDeletion(deletion)
        }

        await applyPendingSubscriptions()

        logSyncEvent("Remote-Änderungen verarbeitet", metadata: [
            "modifications": event.modifications.count,
            "deletions": event.deletions.count,
            "byType": modificationCountsByType.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","),
        ])

        // Replay a received manual sort order onto the feed ranks now that all
        // subscription records of this batch are applied.
        applySubscriptionListSortIfNeeded()

        // One coalesced write for everything the apply pass parked in the pending stores —
        // and a deterministic flush before the app could be killed mid-download.
        flushPendingPayloads()
        databaseManager.save()
        markSyncCompletedIfFinished()
        // Newly applied subscriptions are stubs — load their episodes one by one.
        hydrateStubFeedsIfNeeded()
    }

    // Apply subscriptions last and in the user's list order (rank): the per-feed network
    // subscribe makes that phase slow, so the visible top of the list should fill in
    // first. Everything else (device records, episode states) keeps its original order.
    func orderedModifications(_ modifications: [CKDatabase.RecordZoneChange.Modification]) -> [CKDatabase.RecordZoneChange.Modification] {
        guard modifications.contains(where: { $0.record.recordType == RecordKind.subscription }) else {
            return modifications
        }
        var others: [CKDatabase.RecordZoneChange.Modification] = []
        var subscriptions: [(modification: CKDatabase.RecordZoneChange.Modification, rank: Int)] = []
        var subscriptionListSettings: [CKDatabase.RecordZoneChange.Modification] = []
        for modification in modifications {
            if modification.record.recordType == RecordKind.subscription {
                let rank = (payloadDictionary(from: modification.record)?["rank"] as? NSNumber)?.intValue ?? Int.max
                subscriptions.append((modification, rank))
            } else if modification.record.recordType == RecordKind.subscriptionListSettings {
                subscriptionListSettings.append(modification)
            } else {
                others.append(modification)
            }
        }
        let sortedSubscriptions = subscriptions.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map { $0.element.modification }
        return others + sortedSubscriptions + subscriptionListSettings
    }

    func handleSentDatabaseChanges(_ event: CKSyncEngine.Event.SentDatabaseChanges) {
        var hasFailedDatabaseChanges = false

        for failedSave in event.failedZoneSaves {
            hasFailedDatabaseChanges = true
            handleCloudKitSendError(failedSave.error)
        }

        for (_, error) in event.failedZoneDeletes {
            hasFailedDatabaseChanges = true
            handleCloudKitSendError(error)
        }

        if hasFailedDatabaseChanges {
            hasUnresolvedSyncFailures = true
            postStateChanged()
            // A failed zone save is the classic first-enable failure (the custom zone
            // doesn't exist yet) — without a retry the sync stalls right there.
            scheduleSyncRetryAfterFailure(code: nil, reason: "failedDatabaseChanges")
        } else if !hasUnresolvedSyncFailures {
            markSyncCompletedIfFinished()
        }
    }

    func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) async {
        if event.savedRecords.contains(where: { isUserDataRecordID($0.recordID) })
            || event.deletedRecordIDs.contains(where: { isUserDataRecordID($0) }) {
            syncedUserDataInCurrentRun = true
        }

        for record in event.savedRecords {
            rememberServerRecord(record)
            if record.recordType == RecordKind.device, let payload = payloadDictionary(from: record) {
                updateDeviceCache(with: payload)
            }
        }
        recordInitialUploadRecordsSaved(event.savedRecords.map { $0.recordID })

        for recordID in event.deletedRecordIDs {
            forgetServerRecord(for: recordID)
        }

        var retryRecords: [CKSyncEngine.PendingRecordZoneChange] = []
        var retryZones: [CKSyncEngine.PendingDatabaseChange] = []
        var hasFailedRecordChanges = false
        var lastFailureCode: CKError.Code?

        for failedSave in event.failedRecordSaves {
            if !(await handleFailedRecordSave(failedSave, retryRecords: &retryRecords, retryZones: &retryZones)) {
                hasFailedRecordChanges = true
                lastFailureCode = failedSave.error.code
            }
        }

        for (recordID, error) in event.failedRecordDeletes {
            if !handleFailedRecordDelete(recordID: recordID, error: error) {
                hasFailedRecordChanges = true
                lastFailureCode = error.code
            }
        }

        if !retryZones.isEmpty {
            syncEngine.state.add(pendingDatabaseChanges: retryZones)
        }
        if !retryRecords.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: retryRecords)
        }

        beginSyncActivity(.up)
        recordSyncActivity(event.savedRecords.filter { isUserDataRecordID($0.recordID) }.count)

        if hasFailedRecordChanges {
            hasUnresolvedSyncFailures = true
            postStateChanged()
            // Covers both real failures and the re-queued conflict/zone repairs above —
            // nothing else triggers the next send attempt.
            scheduleSyncRetryAfterFailure(code: lastFailureCode, reason: "failedRecordSends")
        } else if !hasUnresolvedSyncFailures {
            markSyncCompletedIfFinished()
        }
    }

    func handleFailedRecordSave(_ failedSave: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
                                        retryRecords: inout [CKSyncEngine.PendingRecordZoneChange],
                                        retryZones: inout [CKSyncEngine.PendingDatabaseChange]) async -> Bool {
        let recordID = failedSave.record.recordID
        switch failedSave.error.code {
        case .serverRecordChanged:
            if let serverRecord = failedSave.error.serverRecord {
                rememberServerRecord(serverRecord)
                await applyRemoteRecord(serverRecord)
                retryRecords.append(.saveRecord(recordID))
            } else {
                setError(failedSave.error)
            }
            return false
        case .zoneNotFound:
            forgetServerRecord(for: recordID)
            retryZones.append(.saveZone(CKRecordZone(zoneID: recordID.zoneID)))
            retryRecords.append(.saveRecord(recordID))
            return false
        case .unknownItem:
            forgetServerRecord(for: recordID)
            retryRecords.append(.saveRecord(recordID))
            return false
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited:
            handleCloudKitSendError(failedSave.error)
            return false
        default:
            setError(failedSave.error)
            return false
        }
    }

    func handleFailedRecordDelete(recordID: CKRecord.ID, error: CKError) -> Bool {
        switch error.code {
        case .unknownItem, .zoneNotFound:
            forgetServerRecord(for: recordID)
            return true
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited:
            handleCloudKitSendError(error)
            return false
        default:
            setError(error)
            return false
        }
    }

    func handleCloudKitSendError(_ error: CKError) {
        switch error.code {
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited:
            setStatus(NSLocalizedString("iCloud ist vorübergehend nicht verfügbar.", comment: ""))
        default:
            setError(error)
        }
    }

    func applyRemoteRecord(_ record: CKRecord) async {
        guard let payload = payloadDictionary(from: record) else { return }

        switch record.recordType {
        case RecordKind.device:
            updateDeviceCache(with: payload)

        case RecordKind.episodeState:
            if episodesSyncEnabled {
                applyRemoteEpisodeState(payload, recordName: record.recordID.recordName)
            } else {
                // Category is off: do NOT apply, but keep the payload. The engine's change
                // token advances with this fetch and the record is never delivered again —
                // dropping it here made data that arrived while a category was off
                // unrecoverable. Applied (enabled-gated) once the category is turned on.
                storePendingEpisodeState(payload, recordName: record.recordID.recordName)
            }

        case RecordKind.subscription:
            if subscriptionsSyncEnabled {
                await applyRemoteSubscription(payload, recordName: record.recordID.recordName)
            } else {
                storePendingSubscription(payload, recordName: record.recordID.recordName)
            }

        case RecordKind.appSettings:
            if settingsSyncEnabled {
                applyRemoteAppSettings(payload)
            }

        case RecordKind.listScrollPositions:
            if episodesSyncEnabled {
                applyRemoteListScrollPositions(payload)
            }

        case RecordKind.subscriptionListSettings:
            if subscriptionsSyncEnabled {
                applyRemoteSubscriptionListSettings(payload)
            } else {
                storePendingSubscription(payload, recordName: record.recordID.recordName)
            }

        default:
            break
        }
    }

    @discardableResult
    func applyRemoteSubscriptionListSettings(_ payload: [String: Any]) -> Bool {
        let remoteSortMode = (payload["sortMode"] as? String) ?? ""
        let remoteManualOrder = (payload["manualOrder"] as? [String]) ?? []
        let remoteEpisodeLists = (payload["episodeLists"] as? [[String: Any]]) ?? []
        let hasRemoteEpisodeLists = !remoteEpisodeLists.isEmpty
        let hasRemoteMainMenuListUIDs = payload.keys.contains("mainMenuListUIDs")
        // An EMPTY record (published by a pre-fix build on a freshly installed device)
        // must not win last-writer-wins against a real local state: ignore it entirely —
        // applying it would re-stamp localModifiedDate/baseline and silence this device
        // forever — and push the real local state back up instead.
        guard !remoteSortMode.isEmpty || !remoteManualOrder.isEmpty || hasRemoteEpisodeLists || hasRemoteMainMenuListUIDs else {
            if Self.hasLocalSubscriptionListSettings() {
                addPendingSave(subscriptionListSettingsRecordID())
            }
            return true
        }
        // A record WITHOUT a manual order must never displace a local manual-order
        // state, regardless of its timestamp: it carries strictly less information
        // (sort-mode-only devices, e.g. one where the user tried the sort menu while
        // "Manual" was still missing) and would flip the active mode on the device
        // that owns the real order. If the record also carries episode-list settings,
        // merge those and push the richer local sort state back up afterwards.
        var shouldApplySortSettings = true
        var shouldRepairSortSettings = false
        if remoteManualOrder.isEmpty,
           defaults.string(forKey: FeedListSortMode) == "manual",
           databaseManager.hasManualFeedOrder() {
            guard hasRemoteEpisodeLists || hasRemoteMainMenuListUIDs else {
                addPendingSave(subscriptionListSettingsRecordID())
                return true
            }
            shouldApplySortSettings = false
            shouldRepairSortSettings = true
        }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = defaults.object(forKey: Self.subscriptionListSettingsLocalModifiedDateKey) as? Date,
           localDate.compare(remoteDate) == .orderedDescending {
            // Only defend the local state if one actually exists — a pre-fix build may
            // have stamped localModifiedDate on a device that has nothing to defend.
            if Self.hasLocalSubscriptionListSettings() {
                addPendingSave(subscriptionListSettingsRecordID())
                return true
            }
        }
        if shouldApplySortSettings, !remoteSortMode.isEmpty {
            defaults.set(remoteSortMode, forKey: FeedListSortMode)
        }
        if shouldApplySortSettings, !remoteManualOrder.isEmpty {
            defaults.set(remoteManualOrder, forKey: Self.manualFeedOrderDefaultsKey)
        }
        let resolvedEpisodeListFeeds = hasRemoteEpisodeLists ? applyRemoteEpisodeLists(remoteEpisodeLists) : true
        if hasRemoteMainMenuListUIDs {
            let mainMenuListUIDs = (payload["mainMenuListUIDs"] as? [String]) ?? []
            _ = applyRemoteMainMenuListUIDs(mainMenuListUIDs)
        }
        guard resolvedEpisodeListFeeds else {
            storePendingSubscription(payload, recordName: RecordPrefix.subscriptionListSettings)
            return false
        }
        setSyncMetadata(shouldRepairSortSettings ? Date() : remoteDate, forKey: Self.subscriptionListSettingsLocalModifiedDateKey)
        // Re-baseline so applying the payload doesn't read as a local change and echo back.
        setSyncMetadata(Self.subscriptionListSettingsFingerprint(), forKey: Self.subscriptionListSettingsBaselineKey)
        // The actual reordering happens once at the end of the apply batch, after all
        // subscription records (and their stub feeds) of this fetch exist.
        if shouldApplySortSettings {
            needsSubscriptionListSortApply = true
        }
        if shouldRepairSortSettings {
            addPendingSave(subscriptionListSettingsRecordID())
        }
        return true
    }

    // Writing the defaults alone changes nothing visible: the feed list orders by the
    // feeds' rank values. Replay the synced manual order onto the ranks once the apply
    // batch is done — that also makes "Manual" appear (and be checked) in the sort menu.
    func applySubscriptionListSortIfNeeded() {
        guard needsSubscriptionListSortApply else { return }
        needsSubscriptionListSortApply = false
        guard defaults.string(forKey: FeedListSortMode) == "manual",
              databaseManager.hasManualFeedOrder() else { return }
        // restoreManualFeedOrder rewrites every feed's rank without diff checks — shield
        // them all from the change observer so nothing echoes back as a local edit.
        if let feeds = databaseManager.feeds as? [CDFeed] {
            for feed in feeds {
                remoteAppliedObjectIDs.insert(feed.objectID)
            }
        }
        databaseManager.restoreManualFeedOrder()
        // The restore can produce ranks that differ from the cloud's (e.g. a feed whose
        // sourceURL changed after a redirect no longer matches the synced order and sorts
        // to the end). Refresh the payload-hash baseline so neither the change observer
        // nor the periodic hash sweep uploads the APPLIED order as a fresh local edit —
        // that re-upload stamped new updatedAt dates and rewrote the ranks on the other
        // devices ("iPhone lost its manual sort order").
        var appliedHashes: [String: String] = [:]
        for feed in (databaseManager.feeds as? [CDFeed]) ?? [] {
            if let feedURL = feed.sourceURL?.absoluteString {
                appliedHashes[feedURL] = subscriptionPayloadHash(for: feed)
            }
        }
        mergeSubscriptionPayloadHashes(appliedHashes)
        logSyncEvent("Synchronisierte Sortierreihenfolge angewendet")
    }

    func applyRemoteEpisodeLists(_ payloads: [[String: Any]]) -> Bool {
        guard !payloads.isEmpty, let context = databaseManager.objectContext else { return true }
        let uids = payloads.compactMap { $0["uid"] as? String }.filter { !$0.isEmpty }
        guard !uids.isEmpty else { return true }

        let request = NSFetchRequest<CDEpisodeList>(entityName: "EpisodeList")
        request.predicate = NSPredicate(format: "uid IN %@", uids)
        request.includesSubentities = false
        let existingLists = (try? context.fetch(request)) ?? []
        var listsByUID: [String: CDEpisodeList] = [:]
        for list in existingLists {
            if let uid = list.uid {
                listsByUID[uid] = list
            }
        }

        let allIncludedFeedURLs = Set(payloads.flatMap { ($0["includedFeedURLs"] as? [String]) ?? [] })
        var feedsByURL: [String: CDFeed] = [:]
        if !allIncludedFeedURLs.isEmpty {
            let feedRequest = NSFetchRequest<CDFeed>(entityName: "Feed")
            feedRequest.predicate = NSPredicate(format: "sourceURL_ IN %@", Array(allIncludedFeedURLs))
            feedRequest.includesSubentities = false
            let feeds = (try? context.fetch(feedRequest)) ?? []
            for feed in feeds {
                if let urlString = feed.value(forKey: "sourceURL_") as? String {
                    feedsByURL[urlString] = feed
                }
            }
        }

        var missingFeedURLs = Set<String>()
        var didMutateAnyList = false
        for payload in payloads {
            guard let uid = payload["uid"] as? String, !uid.isEmpty else { continue }
            let list: CDEpisodeList
            if let existingList = listsByUID[uid] {
                list = existingList
            } else if let newList = NSEntityDescription.insertNewObject(forEntityName: "EpisodeList", into: context) as? CDEpisodeList {
                list = newList
                listsByUID[uid] = newList
            } else {
                continue
            }
            let result = applyRemoteEpisodeListPayload(payload, to: list, feedsByURL: feedsByURL)
            missingFeedURLs.formUnion(result.missingFeedURLs)
            didMutateAnyList = didMutateAnyList || result.didMutate
        }

        if !missingFeedURLs.isEmpty {
            logSyncEvent("Listen-Einstellungen warten auf Abos", metadata: [
                "missingFeedURLCount": missingFeedURLs.count,
            ])
            return false
        }
        if didMutateAnyList {
            NotificationCenter.default.post(name: NSNotification.Name("MainMenuListUIDsDidChangeNotification"), object: nil)
        }
        return true
    }

    func applyRemoteEpisodeListPayload(_ payload: [String: Any], to list: CDEpisodeList, feedsByURL: [String: CDFeed]) -> (missingFeedURLs: Set<String>, didMutate: Bool) {
        var didMutate = false
        var missingFeedURLs = Set<String>()

        if let uid = payload["uid"] as? String, list.uid != uid {
            list.uid = uid
            didMutate = true
        }
        if let name = payload["name"] as? String, list.name != name {
            list.name = name
            didMutate = true
        }
        if let icon = payload["icon"] as? String, list.icon != icon {
            list.icon = icon
            didMutate = true
        }
        if let rank = Self.int32Value(payload["rank"]), list.rank != rank {
            list.rank = rank
            didMutate = true
        }
        if let queryValue = payload["query"] as? String {
            let query = queryValue.isEmpty ? nil : queryValue
            if list.query != query {
                list.query = query
                didMutate = true
            }
        }
        if let audio = Self.boolValue(payload["audio"]), list.audio != audio {
            list.audio = audio
            didMutate = true
        }
        if let video = Self.boolValue(payload["video"]), list.video != video {
            list.video = video
            didMutate = true
        }
        if let downloaded = Self.boolValue(payload["downloaded"]), list.downloaded != downloaded {
            list.downloaded = downloaded
            didMutate = true
        }
        if let downloading = Self.boolValue(payload["downloading"]), list.downloading != downloading {
            list.downloading = downloading
            didMutate = true
        }
        if let notDownloaded = Self.boolValue(payload["notDownloaded"]), list.notDownloaded != notDownloaded {
            list.notDownloaded = notDownloaded
            didMutate = true
        }
        if let unplayed = Self.boolValue(payload["unplayed"]), list.unplayed != unplayed {
            list.unplayed = unplayed
            didMutate = true
        }
        if let unfinished = Self.boolValue(payload["unfinished"]), list.unfinished != unfinished {
            list.unfinished = unfinished
            didMutate = true
        }
        if let played = Self.boolValue(payload["played"]), list.played != played {
            list.played = played
            didMutate = true
        }
        if let starred = Self.boolValue(payload["starred"]), list.starred != starred {
            list.starred = starred
            didMutate = true
        }
        if let notStarred = Self.boolValue(payload["notStarred"]), list.notStarred != notStarred {
            list.notStarred = notStarred
            didMutate = true
        }
        if let orderBy = payload["orderBy"] as? String, list.orderBy != orderBy {
            list.orderBy = orderBy
            didMutate = true
        }
        if let descending = Self.boolValue(payload["descending"]), list.descending != descending {
            list.descending = descending
            didMutate = true
        }
        if let groupByPodcast = Self.boolValue(payload["groupByPodcast"]), list.groupByPodcast != groupByPodcast {
            list.groupByPodcast = groupByPodcast
            didMutate = true
        }
        if let continuousPlayback = Self.boolValue(payload["continuousPlayback"]), list.continuousPlayback != continuousPlayback {
            list.continuousPlayback = continuousPlayback
            didMutate = true
        }

        if let includedFeedURLs = payload["includedFeedURLs"] as? [String] {
            let includedFeedURLSet = Set(includedFeedURLs)
            var feeds: [CDFeed] = []
            for urlString in includedFeedURLSet {
                if let feed = feedsByURL[urlString] {
                    feeds.append(feed)
                } else {
                    missingFeedURLs.insert(urlString)
                }
            }
            if missingFeedURLs.isEmpty {
                let currentFeedURLs = Set(((list.includedFeeds as? Set<CDFeed>) ?? []).compactMap { $0.sourceURL?.absoluteString })
                if currentFeedURLs != includedFeedURLSet {
                    let includedFeeds = Set(feeds)
                    list.includedFeeds = includedFeeds
                    didMutate = true
                }
            }
        }

        if didMutate {
            remoteAppliedObjectIDs.insert(list.objectID)
            list.invalidateCaches()
        }
        return (missingFeedURLs, didMutate)
    }

    func applyRemoteMainMenuListUIDs(_ mainMenuListUIDs: [String]) -> Bool {
        let currentUIDs = defaults.array(forKey: "MainMenuListUIDs") as? [String] ?? []
        guard currentUIDs != mainMenuListUIDs else { return false }
        defaults.set(mainMenuListUIDs, forKey: "MainMenuListUIDs")
        NotificationCenter.default.post(name: NSNotification.Name("MainMenuListUIDsDidChangeNotification"), object: nil)
        return true
    }

    func applyRemoteDeletion(_ deletion: CKDatabase.RecordZoneChange.Deletion) {
        if deletion.recordType == RecordKind.device {
            let deletedDeviceID = String(deletion.recordID.recordName.dropFirst(RecordPrefix.device.count))
            removeDeviceFromCache(deletedDeviceID)
            if deletedDeviceID == deviceID {
                // Another device removed THIS one (it cannot tell which entry is the
                // live install) — re-announce ourselves so the lists stay truthful.
                queueDeviceRecord()
            }
            return
        }
        if deletion.recordType == RecordKind.subscription && subscriptionsSyncEnabled {
            let recordName = deletion.recordID.recordName
            // Deletions are only propagated "live": the catch-up fetch right after
            // (re-)enabling subscription sync may carry deletions from while sync was
            // off — applying those would surprise-delete local subscriptions.
            guard !defaults.bool(forKey: Self.suppressSubscriptionDeletionsKey) else {
                logSyncEvent("Abo-Löschung unterdrückt (Nachhol-Fetch nach Aktivierung)", metadata: [
                    "recordName": recordName,
                ])
                return
            }
            guard let feedURL = subscriptionRecordURL(for: recordName) else { return }
            if let url = URL(string: feedURL),
               let feed = databaseManager.feed(withSourceURL: url) {
                remoteAppliedObjectIDs.insert(feed.objectID)
                databaseManager.unsubscribeFeed(feed)
            }
            removeSubscriptionLocalSyncState(forFeedURLs: [feedURL])
        }
    }

    func applyRemoteEpisodeState(_ payload: [String: Any], recordName: String, resolvedEpisode: CDEpisode? = nil) {
        guard let objectHash = payload["objectHash"] as? String, !objectHash.isEmpty else { return }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = episodeLocalModifiedDate(for: objectHash),
           localDate.compare(remoteDate) == .orderedDescending {
            addPendingSave(episodeRecordID(forObjectHash: objectHash))
            return
        }

        guard let episode = resolvedEpisode ?? episode(for: payload) else {
            storePendingEpisodeState(payload, recordName: recordName)
            return
        }

        var played = (payload["played"] as? Bool) ?? false
        var starred = (payload["starred"] as? Bool) ?? false
        var position = max(0, (payload["position"] as? NSNumber)?.int32Value ?? Int32((payload["position"] as? Int) ?? 0))

        // First reconciliation: an episode WITHOUT a sync date has never been part of
        // the sync dialog — its local state is an independent stand, not an outdated
        // one. Merge by content instead of timestamp (user decision 12.06.): heard
        // beats unheard, the farther playback position wins, favorite beats
        // non-favorite. Once the episode has a sync date, deliberate live edits win
        // by recency again (otherwise nothing could ever be reset to unheard).
        var localWon = false
        if episodeLocalModifiedDate(for: objectHash) == nil {
            if episode.consumed && !played {
                played = true
                localWon = true
            }
            if !played && episode.position > position {
                position = episode.position
                localWon = true
            }
            if episode.starred && !starred {
                starred = true
                localWon = true
            }
        }

        var didMutate = false
        if episode.consumed != played {
            episode.consumed = played
            didMutate = true
        }
        if episode.starred != starred {
            episode.starred = starred
            didMutate = true
        }
        if !played && episode.position != position {
            episode.position = position
            didMutate = true
        }
        if played && episode.position != 0 {
            episode.position = 0
            didMutate = true
        }
        if didMutate {
            remoteAppliedObjectIDs.insert(episode.objectID)
        }

        if localWon {
            // The merge kept local state the cloud doesn't have — push the merged
            // result back up with a fresh date so the other devices adopt it (their
            // copy already has a sync date, so plain recency applies there).
            setEpisodeLocalModifiedDate(Date(), for: objectHash)
            addPendingSave(episodeRecordID(forObjectHash: objectHash))
        } else {
            setEpisodeLocalModifiedDate(remoteDate, for: objectHash)
        }
    }

    func episode(for payload: [String: Any]) -> CDEpisode? {
        if let objectHash = payload["objectHash"] as? String,
           let episode = databaseManager.episode(withObjectHash: objectHash) {
            return episode
        }

        guard let guid = payload["guid"] as? String, !guid.isEmpty else { return nil }
        if let feedURLString = payload["feedURL"] as? String,
           let url = URL(string: feedURLString),
           let feed = databaseManager.feed(withSourceURL: url) {
            for episode in feed.episodes as? Set<CDEpisode> ?? [] where episode.guid == guid {
                return episode
            }
        }

        return databaseManager.episode(withGuid: guid)
    }

    func storePendingEpisodeState(_ payload: [String: Any], recordName: String) {
        var pending = pendingPayloads(forKey: Self.pendingEpisodeStatesKey)
        pending[recordName] = payload
        setPendingPayloads(pending, forKey: Self.pendingEpisodeStatesKey)
    }

    func applyPendingEpisodeStates() {
        // The pending store survives a category toggle (the engine's change token means
        // already-fetched records are never re-delivered), but it must only be APPLIED
        // while the category is on — like applyRemoteRecord.
        guard episodesSyncEnabled else { return }
        var pending = pendingPayloads(forKey: Self.pendingEpisodeStatesKey)
        guard !pending.isEmpty else { return }

        // One batch fetch instead of a store fetch per pending entry — this runs on the
        // main context right after a refresh settles, where per-entry fetches contended
        // with the merge writes for the store lock.
        let objectHashes = pending.values.compactMap { $0["objectHash"] as? String }
        guard !objectHashes.isEmpty, let context = databaseManager.objectContext else { return }
        let request = NSFetchRequest<CDEpisode>(entityName: "Episode")
        request.predicate = NSPredicate(format: "objectHash IN %@", objectHashes)
        request.includesSubentities = false
        let episodes = (try? context.fetch(request)) ?? []
        var episodesByHash: [String: CDEpisode] = [:]
        for episode in episodes {
            if let objectHash = episode.objectHash {
                episodesByHash[objectHash] = episode
            }
        }
        guard !episodesByHash.isEmpty else { return }

        let initialCount = pending.count
        for (recordName, payload) in pending {
            guard let objectHash = payload["objectHash"] as? String,
                  let episode = episodesByHash[objectHash] else { continue }
            applyRemoteEpisodeState(payload, recordName: recordName, resolvedEpisode: episode)
            pending.removeValue(forKey: recordName)
        }

        setPendingPayloads(pending, forKey: Self.pendingEpisodeStatesKey)
        databaseManager.save()
        logSyncEvent("Wartende Episoden-Status verarbeitet", metadata: [
            "applied": initialCount - pending.count,
            "remaining": pending.count,
        ])
    }

    func applyRemoteSubscription(_ payload: [String: Any], recordName: String) async {
        guard let feedURL = payload["feedURL"] as? String, !feedURL.isEmpty else { return }
        setSubscriptionRecordURL(feedURL, for: recordName)

        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = subscriptionLocalModifiedDate(for: feedURL),
           localDate.compare(remoteDate) == .orderedDescending {
            logSyncEvent("Remote-Abo übersprungen (lokal neuer)", metadata: ["feedURL": feedURL])
            addPendingSave(subscriptionRecordID(forFeedURL: feedURL))
            return
        }

        guard let feed = subscribedFeed(for: feedURL, title: payload["title"] as? String) else {
            storePendingSubscription(payload, recordName: recordName)
            return
        }

        applySubscriptionPayload(payload, to: feed)
        setSubscriptionLocalModifiedDate(remoteDate, for: feedURL)
        // Record the applied state's fingerprint so the next local objects-did-change pass
        // (or feed refresh) doesn't mistake the applied payload for a local edit and echo
        // it back up with a fresh updatedAt.
        mergeSubscriptionPayloadHashes([feedURL: subscriptionPayloadHash(for: feed)])
    }

    func subscribedFeed(for feedURL: String, title: String?) -> CDFeed? {
        guard let url = URL(string: feedURL) else { return nil }
        if let feed = databaseManager.feed(withSourceURL: url) {
            if !feed.subscribed {
                feed.subscribed = true
                // `subscribed` is a sync-relevant key — record the remote-driven mutation
                // so the observer doesn't echo it back as a local edit.
                remoteAppliedObjectIDs.insert(feed.objectID)
            }
            return feed
        }

        // Phase 1 of the two-phase apply: create a lightweight local STUB — no network,
        // no episodes. The whole list shows up immediately (in rank order) and the UI
        // stays responsive no matter how many subscriptions arrive. Episodes are loaded
        // one feed at a time by the low-priority hydration queue (phase 2), which derives
        // its work from the data (lastUpdate == nil) and therefore survives app kills.
        guard let stub = ICFeed.feed() as? ICFeed else { return nil }
        stub.sourceURL = url
        stub.title = (title?.isEmpty == false) ? title : feedURL
        guard let feed = subscriptionManager.subscribeParserFeed(stub, autodownload: false, options: .subscribeOptionDontManageRanking) else {
            logSyncEvent("Remote-Abo-Stub konnte nicht angelegt werden", metadata: ["feedURL": feedURL])
            return nil
        }
        remoteAppliedObjectIDs.insert(feed.objectID)
        return feed
    }

    // Equality-checked like applyRemoteEpisodeState: only real differences are written, so an
    // apply that changes nothing leaves no dirty objects (no objects-did-change pass, no save
    // churn, no echo upload).
    func applySubscriptionPayload(_ payload: [String: Any], to feed: CDFeed) {
        var didMutate = false
        if let title = payload["title"] as? String, !title.isEmpty, feed.title == nil {
            feed.title = title
            didMutate = true
        }
        if let rank = (payload["rank"] as? NSNumber)?.int32Value, feed.rank != rank {
            feed.rank = rank
            didMutate = true
        }
        if let parked = payload["parked"] as? Bool, feed.parked != parked {
            feed.parked = parked
            didMutate = true
        }
        if let username = payload["username"] as? String, !username.isEmpty, feed.username != username {
            feed.username = username
            didMutate = true
        }
        if let password = payload["password"] as? String, !password.isEmpty, feed.password != password {
            feed.password = password
            didMutate = true
        }

        if let properties = payload["properties"] as? [[String: Any]] {
            for property in properties {
                if applyFeedPropertyPayload(property, to: feed) {
                    didMutate = true
                }
            }
        }
        if didMutate {
            remoteAppliedObjectIDs.insert(feed.objectID)
        }
    }

    // Replicates all four CDFeedProperty value fields instead of guessing a single type.
    // CDFeedProperty carries no type marker; the old UserDefaults-based heuristic failed for
    // uid-prefixed double keys (the auto-skip periods/offsets) and applied them as bool —
    // silent value loss on the receiving device. The payload has always carried all four
    // fields; `valueType` is still uploaded so older app versions keep working.
    func applyFeedPropertyPayload(_ property: [String: Any], to feed: CDFeed) -> Bool {
        guard let rawKey = property["key"] as? String, !rawKey.isEmpty else { return false }
        // Map a uid-relative marker key back to this device's own feed uid (see stableFeedPropertyKey).
        let key = Self.localFeedPropertyKey(rawKey, feedUID: feed.uid)
        guard let cdProperty = feed.property(forKey: key, insertOnDemand: true) else { return false }

        var didMutate = cdProperty.isInserted
        let boolValue = (property["boolValue"] as? NSNumber)?.boolValue ?? false
        let int32Value = (property["int32Value"] as? NSNumber)?.int32Value ?? 0
        let doubleValue = (property["doubleValue"] as? NSNumber)?.doubleValue ?? 0
        let stringValue = property["stringValue"] as? String
        if cdProperty.boolValue != boolValue {
            cdProperty.boolValue = boolValue
            didMutate = true
        }
        if cdProperty.int32Value != int32Value {
            cdProperty.int32Value = int32Value
            didMutate = true
        }
        if cdProperty.doubleValue != doubleValue {
            cdProperty.doubleValue = doubleValue
            didMutate = true
        }
        if cdProperty.stringValue != stringValue {
            cdProperty.stringValue = stringValue
            didMutate = true
        }
        if didMutate {
            remoteAppliedObjectIDs.insert(cdProperty.objectID)
        }
        return didMutate
    }

    func storePendingSubscription(_ payload: [String: Any], recordName: String) {
        var pending = pendingPayloads(forKey: Self.pendingSubscriptionPayloadsKey)
        pending[recordName] = payload
        setPendingPayloads(pending, forKey: Self.pendingSubscriptionPayloadsKey)
    }

    func applyPendingSubscriptions() async {
        // Same enabled-gate as applyRemoteRecord: without it a customer who turned
        // subscription sync OFF could still get pending remote feeds subscribed
        // (including the network fetch) on the next app start.
        guard subscriptionsSyncEnabled else { return }
        var pending = pendingPayloads(forKey: Self.pendingSubscriptionPayloadsKey)
        guard !pending.isEmpty else { return }

        let initialCount = pending.count
        for (recordName, payload) in pending {
            // The list-settings singleton parks in the same pending store while the
            // category is off — it is not a feed payload.
            if recordName == RecordPrefix.subscriptionListSettings {
                if applyRemoteSubscriptionListSettings(payload) {
                    pending.removeValue(forKey: recordName)
                }
                continue
            }
            guard let feedURL = payload["feedURL"] as? String else { continue }
            if let feed = subscribedFeed(for: feedURL, title: payload["title"] as? String) {
                applySubscriptionPayload(payload, to: feed)
                let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
                setSubscriptionLocalModifiedDate(remoteDate, for: feedURL)
                mergeSubscriptionPayloadHashes([feedURL: subscriptionPayloadHash(for: feed)])
                pending.removeValue(forKey: recordName)
            }
        }

        applySubscriptionListSortIfNeeded()
        setPendingPayloads(pending, forKey: Self.pendingSubscriptionPayloadsKey)
        databaseManager.save()
        logSyncEvent("Wartende Abo-Payloads verarbeitet", metadata: [
            "applied": initialCount - pending.count,
            "remaining": pending.count,
        ])
        hydrateStubFeedsIfNeeded()
    }

    func applyRemoteAppSettings(_ payload: [String: Any]) {
        // Enable phase (marker still set, nothing published yet) and the cloud already
        // has settings: the USER decides (12.06.) — adopt the cloud state or overwrite
        // it with this device's settings. Park the payload and ask; nothing is applied
        // or published until the choice is made (the fetch-gated initial publish is
        // held back by the parked payload).
        if defaults.bool(forKey: Self.initialSettingsBackfillPendingKey) {
            setSyncMetadata(payload, forKey: Self.pendingInitialSettingsPayloadKey)
            logSyncEvent("Einstellungs-Wahl erforderlich (iCloud hat bereits Einstellungen)")
            postStateChanged()
            NotificationCenter.default.post(name: NSNotification.Name(Self.initialSettingsChoiceNeededNotification), object: nil)
            return
        }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = settingsLocalModifiedDate(), localDate.compare(remoteDate) == .orderedDescending {
            addPendingSave(appSettingsRecordID())
            return
        }
        adoptSettingsPayload(payload)
    }

    // Shared apply core: writes the synced values, re-baselines and refreshes the UI.
    func adoptSettingsPayload(_ payload: [String: Any]) {
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        guard let values = payload["values"] as? [String: Any] else {
            logSyncEvent("Einstellungs-Payload ungültig", metadata: [
                "hasValues": false,
                "payloadKeyCount": payload.keys.count,
            ])
            return
        }
        var appliedSettingsValueCount = 0
        for (key, value) in values where Self.shouldSyncSettingsKeyForSyncEngineCallback(key) && Self.isValidSettingsValueForSyncEngineCallback(value) {
            defaults.set(value, forKey: key)
            appliedSettingsValueCount += 1
        }

        let credentials = payload["credentials"] as? NSDictionary
        if let credentials {
            ICRemoteChapterCredentialStore.restoreBackupCredentialValues(credentials)
        }

        setSettingsLocalModifiedDate(remoteDate)
        // Re-baseline so the apply itself doesn't read as a local settings change on the
        // next debounced check (that echoed the record back up with a fresh updatedAt).
        setStoredSyncedSettingsHash(syncedSettingsHash())
        // Remote settings adopted — the fetch-gated initial publish is obsolete.
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
        defaults.synchronize()
        ICAppearanceManager.shared()?.updateAppearance()
        NotificationCenter.default.post(name: NSNotification.Name("MainMenuListUIDsDidChangeNotification"), object: nil)
        logSyncEvent("Einstellungs-Payload übernommen", metadata: [
            "settingsValueCount": values.count,
            "appliedSettingsValueCount": appliedSettingsValueCount,
            "hasCredentials": credentials != nil,
        ])
        postStateChanged()
    }

    // MARK: - Initial settings choice (user decision on enabling settings sync)

    @objc var hasPendingInitialSettingsChoice: Bool {
        Self.syncMetadataValue(forKey: Self.pendingInitialSettingsPayloadKey) != nil
    }

    // "Einstellungen aus iCloud übernehmen": apply the parked cloud settings here.
    @objc func resolveInitialSettingsAdoptingCloud() {
        guard let payload = Self.syncMetadataValue(forKey: Self.pendingInitialSettingsPayloadKey) as? [String: Any] else {
            logSyncEvent("Einstellungs-Wahl: iCloud-Stand fehlt", metadata: syncDiagnosticsMetadata())
            postStateChanged()
            return
        }
        logSyncEvent("Einstellungs-Wahl: iCloud-Stand wird übernommen", metadata: [
            "settingsValueCount": (payload["values"] as? [String: Any])?.count ?? -1,
            "hasCredentials": payload["credentials"] != nil,
        ])
        setSyncMetadata(nil, forKey: Self.pendingInitialSettingsPayloadKey)
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
        adoptSettingsPayload(payload)
        logSyncEvent("Einstellungs-Wahl: iCloud-Stand übernommen")
    }

    // "Meine Einstellungen für alle verwenden": publish this device's settings with a
    // fresh date — the other devices adopt them via plain recency.
    @objc func resolveInitialSettingsPublishingLocal() {
        setSyncMetadata(nil, forKey: Self.pendingInitialSettingsPayloadKey)
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
        setSettingsLocalModifiedDate(Date())
        setStoredSyncedSettingsHash(syncedSettingsHash())
        addPendingSave(appSettingsRecordID())
        logSyncEvent("Einstellungs-Wahl: lokale Einstellungen veröffentlicht")
        postStateChanged()
    }

    func applyRemoteListScrollPositions(_ payload: [String: Any]) {
        guard let positions = payload["positions"] as? [String: NSNumber] else { return }
        let remoteDate = payload["lastModified"] as? Date ?? payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = scrollPositionsLocalModifiedDate(), localDate.compare(remoteDate) == .orderedDescending {
            addPendingSave(listScrollPositionsRecordID())
            return
        }

        ICApplySyncedListScrollPositions(positions, remoteDate)
        setScrollPositionsLocalModifiedDate(remoteDate)
    }
}
