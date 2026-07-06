//
//  ICiCloudSyncManager+Metadata.swift
//  Instacast
//
//  Sync metadata storage, device cache, record IDs, status and diagnostics.
//

@preconcurrency import CloudKit
import CoreData
import CryptoKit
import Foundation
import UIKit

@available(iOS 17.0, *)
extension ICiCloudSyncManager {

    func localDevicePayload() -> [String: Any] {
        Self.devicePayload(deviceID: deviceID,
                           episodesEnabled: episodesSyncEnabled,
                           subscriptionsEnabled: subscriptionsSyncEnabled,
                           settingsEnabled: settingsSyncEnabled,
                           lastSyncDate: lastSyncDate)
    }

    nonisolated static func feedPropertyValueType(for property: CDFeedProperty) -> String {
        if property.stringValue != nil {
            return "string"
        }
        guard let key = property.key else {
            return "bool"
        }
        return defaultFeedPropertyValueType(for: key)
    }

    nonisolated static func defaultFeedPropertyValueType(for key: String) -> String {
        guard let value = UserDefaults.standard.object(forKey: key) else {
            return "bool"
        }
        if value is String {
            return "string"
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return "bool"
            }
            let objCType = String(cString: number.objCType)
            if objCType == "d" || objCType == "f" {
                return "double"
            }
            return "integer"
        }
        return "bool"
    }

    nonisolated static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    nonisolated static func int32Value(_ value: Any?) -> Int32? {
        if let value = value as? NSNumber { return value.int32Value }
        if let value = value as? Int { return Int32(value) }
        return nil
    }

    func payloadDictionary(from record: CKRecord) -> [String: Any]? {
        guard let rawPayload = record.encryptedValues["payload"] else { return nil }
        let data: Data
        if let swiftData = rawPayload as? Data {
            data = swiftData
        } else if let nsData = rawPayload as? NSData {
            data = nsData as Data
        } else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    func rememberServerRecord(_ record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        Self.writeKnownRecordSystemFields(archiver.encodedData, forRecordName: record.recordID.recordName)
    }

    func forgetServerRecord(for recordID: CKRecord.ID) {
        Self.removeKnownRecordSystemFields(forRecordName: recordID.recordName)
    }

    func pendingPayloads(forKey key: String) -> [String: [String: Any]] {
        if let cached = pendingPayloadsCache[key] {
            return cached
        }
        let payloads = Self.syncMetadataValue(forKey: key) as? [String: [String: Any]] ?? [:]
        pendingPayloadsCache[key] = payloads
        return payloads
    }

    // All writers of the two pending stores go through here: cache + ONE coalesced disk
    // write (plus an explicit flush at the end of each fetch event) instead of a full
    // plist write per stored record.
    func setPendingPayloads(_ payloads: [String: [String: Any]], forKey key: String) {
        pendingPayloadsCache[key] = payloads
        dirtyPendingPayloadKeys.insert(key)
        schedulePendingPayloadsWrite()
    }

    func schedulePendingPayloadsWrite() {
        pendingPayloadsWriteWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushPendingPayloads()
            }
        }
        pendingPayloadsWriteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    func flushPendingPayloads() {
        guard !dirtyPendingPayloadKeys.isEmpty else { return }
        for key in dirtyPendingPayloadKeys {
            setSyncMetadata(pendingPayloadsCache[key] ?? [:], forKey: key)
        }
        dirtyPendingPayloadKeys.removeAll()
    }

    func deviceCache() -> [String: [String: Any]] {
        Self.syncMetadataValue(forKey: Self.deviceCacheKey) as? [String: [String: Any]] ?? [:]
    }

    func updateDeviceCache(with payload: [String: Any]) {
        guard let id = payload["deviceID"] as? String, !id.isEmpty else { return }
        var cache = deviceCache()
        cache[id] = payload
        setSyncMetadata(cache, forKey: Self.deviceCacheKey)
        postDevicesChanged()
    }

    func removeDeviceFromCache(_ deviceID: String) {
        var cache = deviceCache()
        guard cache.removeValue(forKey: deviceID) != nil else { return }
        setSyncMetadata(cache, forKey: Self.deviceCacheKey)
        postDevicesChanged()
    }

    // Removes a stale device entry — every (re-)installation registers under a fresh
    // device ID, so old installs linger in everyone's device list forever. Deletes the
    // ICDevice record from CloudKit; the other devices clean up their cached entry when
    // the deletion arrives in their next fetch. The CURRENT device cannot be removed.
    @objc func deleteDevice(withID targetDeviceID: String) {
        guard !targetDeviceID.isEmpty, targetDeviceID != deviceID else { return }
        initializeSyncEngineIfNeeded()
        syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(deviceRecordID(for: targetDeviceID))])
        removeDeviceFromCache(targetDeviceID)
        logSyncEvent("Geräte-Eintrag wird entfernt", metadata: ["targetDeviceID": targetDeviceID])
        scheduleLowPrioritySync()
    }

    func deviceParticipates(_ payload: [String: Any]) -> Bool {
        ((payload["episodesEnabled"] as? Bool) ?? false)
        || ((payload["subscriptionsEnabled"] as? Bool) ?? false)
        || ((payload["settingsEnabled"] as? Bool) ?? false)
    }

    func subscriptionRecordURLs() -> [String: String] {
        Self.syncMetadataValue(forKey: Self.subscriptionRecordURLsKey) as? [String: String] ?? [:]
    }

    func subscriptionRecordURL(for recordName: String) -> String? {
        subscriptionRecordURLs()[recordName]
    }

    func setSubscriptionRecordURL(_ feedURL: String, for recordName: String) {
        var urls = subscriptionRecordURLs()
        urls[recordName] = feedURL
        setSyncMetadata(urls, forKey: Self.subscriptionRecordURLsKey)
    }

    func episodeLocalModifiedDates() -> [String: TimeInterval] {
        if let episodeLocalModifiedDatesCache {
            return episodeLocalModifiedDatesCache
        }
        let dates = Self.syncMetadataValue(forKey: Self.episodeLocalModifiedDatesKey) as? [String: TimeInterval] ?? [:]
        episodeLocalModifiedDatesCache = dates
        return dates
    }

    func episodeLocalModifiedDate(for objectHash: String) -> Date? {
        guard let time = episodeLocalModifiedDates()[objectHash], time > 0 else { return nil }
        return Date(timeIntervalSince1970: time)
    }

    func setEpisodeLocalModifiedDate(_ date: Date, for objectHash: String) {
        var dates = episodeLocalModifiedDates()
        dates[objectHash] = date.timeIntervalSince1970
        episodeLocalModifiedDatesCache = dates
        scheduleEpisodeLocalModifiedDatesWrite()
    }

    func setEpisodeLocalModifiedDates(_ updates: [String: Date]) {
        guard !updates.isEmpty else { return }
        var dates = episodeLocalModifiedDates()
        for (objectHash, date) in updates {
            dates[objectHash] = date.timeIntervalSince1970
        }
        episodeLocalModifiedDatesCache = dates
        scheduleEpisodeLocalModifiedDatesWrite()
    }

    func scheduleEpisodeLocalModifiedDatesWrite() {
        episodeLocalModifiedDatesWriteWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushEpisodeLocalModifiedDates()
            }
        }
        episodeLocalModifiedDatesWriteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    func flushEpisodeLocalModifiedDates() {
        guard let dates = episodeLocalModifiedDatesCache else { return }
        setSyncMetadata(dates, forKey: Self.episodeLocalModifiedDatesKey)
    }

    func subscriptionLocalModifiedDates() -> [String: TimeInterval] {
        Self.syncMetadataValue(forKey: Self.subscriptionLocalModifiedDatesKey) as? [String: TimeInterval] ?? [:]
    }

    func subscriptionLocalModifiedDate(for feedURL: String) -> Date? {
        guard let time = subscriptionLocalModifiedDates()[feedURL], time > 0 else { return nil }
        return Date(timeIntervalSince1970: time)
    }

    func setSubscriptionLocalModifiedDate(_ date: Date, for feedURL: String) {
        var dates = subscriptionLocalModifiedDates()
        dates[feedURL] = date.timeIntervalSince1970
        setSyncMetadata(dates, forKey: Self.subscriptionLocalModifiedDatesKey)
    }

    // Batches the record-URL, modified-date and payload-hash bookkeeping for a set of
    // locally changed subscriptions into one disk write each, instead of one per feed.
    func applySubscriptionLocalChanges(feedURLs: [String], hashes: [String: String]) {
        guard !feedURLs.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        var urls = subscriptionRecordURLs()
        var dates = subscriptionLocalModifiedDates()
        for feedURL in feedURLs {
            urls[Self.subscriptionRecordName(forFeedURL: feedURL)] = feedURL
            dates[feedURL] = now
        }
        setSyncMetadata(urls, forKey: Self.subscriptionRecordURLsKey)
        setSyncMetadata(dates, forKey: Self.subscriptionLocalModifiedDatesKey)
        mergeSubscriptionPayloadHashes(hashes)
    }

    func subscriptionPayloadHashes() -> [String: String] {
        if let subscriptionPayloadHashesCache {
            return subscriptionPayloadHashesCache
        }
        let hashes = Self.syncMetadataValue(forKey: Self.subscriptionPayloadHashesKey) as? [String: String] ?? [:]
        subscriptionPayloadHashesCache = hashes
        return hashes
    }

    func mergeSubscriptionPayloadHashes(_ updates: [String: String]) {
        guard !updates.isEmpty else { return }
        var hashes = subscriptionPayloadHashes()
        for (feedURL, hash) in updates {
            hashes[feedURL] = hash
        }
        subscriptionPayloadHashesCache = hashes
        setSyncMetadata(hashes, forKey: Self.subscriptionPayloadHashesKey)
    }

    // Drops every local sync-bookkeeping entry (record-URL mapping, modified date, payload
    // hash) for the given unsubscribed feeds, with one write per mapping. Without this the
    // mappings grew without bound for feeds that were long gone.
    func removeSubscriptionLocalSyncState(forFeedURLs feedURLs: [String]) {
        guard !feedURLs.isEmpty else { return }
        var urls = subscriptionRecordURLs()
        var dates = subscriptionLocalModifiedDates()
        var hashes = subscriptionPayloadHashes()
        var urlsChanged = false
        var datesChanged = false
        var hashesChanged = false
        for feedURL in feedURLs {
            if urls.removeValue(forKey: Self.subscriptionRecordName(forFeedURL: feedURL)) != nil {
                urlsChanged = true
            }
            if dates.removeValue(forKey: feedURL) != nil {
                datesChanged = true
            }
            if hashes.removeValue(forKey: feedURL) != nil {
                hashesChanged = true
            }
        }
        if urlsChanged {
            setSyncMetadata(urls, forKey: Self.subscriptionRecordURLsKey)
        }
        if datesChanged {
            setSyncMetadata(dates, forKey: Self.subscriptionLocalModifiedDatesKey)
        }
        if hashesChanged {
            subscriptionPayloadHashesCache = hashes
            setSyncMetadata(hashes, forKey: Self.subscriptionPayloadHashesKey)
        }
    }

    func subscriptionPayloadHash(for feed: CDFeed) -> String {
        Self.subscriptionPayloadHash(for: feed)
    }

    // Stable fingerprint of the fields that actually go into a synced subscription
    // record (title, rank, parked, credentials, non-internal properties). Excludes
    // refresh-only fields like lastUpdate/etag/contentHash so a feed refresh that only
    // updates those does not look like a change. `nonisolated` so the backfill plan can
    // compute it on its background context.
    nonisolated static func subscriptionPayloadHash(for feed: CDFeed) -> String {
        var components: [String] = [
            feed.title ?? "",
            String(feed.rank),
            feed.parked ? "1" : "0",
            feed.username ?? "",
            feed.password ?? "",
        ]
        var propertyComponents: [String] = []
        for property in feed.properties as? Set<CDFeedProperty> ?? [] {
            guard let key = property.key, !internalFeedPropertyKeys.contains(key) else { continue }
            propertyComponents.append("\(key)\u{1}\(Self.feedPropertyValueType(for: property))\u{1}\(property.boolValue ? 1 : 0)\u{1}\(property.int32Value)\u{1}\(property.doubleValue)\u{1}\(property.stringValue ?? "")")
        }
        components.append(contentsOf: propertyComponents.sorted())
        return Self.sha256Hex(components.joined(separator: "\u{2}"))
    }

    func settingsLocalModifiedDate() -> Date? {
        defaults.object(forKey: Self.settingsLocalModifiedDateKey) as? Date
    }

    func setSettingsLocalModifiedDate(_ date: Date) {
        setSyncMetadata(date, forKey: Self.settingsLocalModifiedDateKey)
    }

    func scrollPositionsLocalModifiedDate() -> Date? {
        defaults.object(forKey: Self.scrollPositionsLocalModifiedDateKey) as? Date
    }

    func setScrollPositionsLocalModifiedDate(_ date: Date) {
        setSyncMetadata(date, forKey: Self.scrollPositionsLocalModifiedDateKey)
    }

    func deviceRecordID(for deviceID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.device + deviceID, zoneID: zoneID)
    }

    func episodeRecordID(forObjectHash objectHash: String) -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.episode + objectHash, zoneID: zoneID)
    }

    func subscriptionRecordID(forFeedURL feedURL: String) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.subscriptionRecordName(forFeedURL: feedURL), zoneID: zoneID)
    }

    func appSettingsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.appSettings, zoneID: zoneID)
    }

    func listScrollPositionsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.listScrollPositions, zoneID: zoneID)
    }

    func subscriptionListSettingsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.subscriptionListSettings, zoneID: zoneID)
    }

    nonisolated static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func refreshAccountStatus() async {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                clearError()
                setStatus(anySyncEnabled ? NSLocalizedString("Bereit", comment: "") : NSLocalizedString("Aus", comment: ""))
            case .noAccount:
                setStatus(NSLocalizedString("Kein iCloud Account verfügbar.", comment: ""))
            case .restricted:
                setStatus(NSLocalizedString("iCloud ist auf diesem Gerät eingeschränkt.", comment: ""))
            case .couldNotDetermine:
                setStatus(NSLocalizedString("iCloud Status unbekannt.", comment: ""))
            case .temporarilyUnavailable:
                setStatus(NSLocalizedString("iCloud ist vorübergehend nicht verfügbar.", comment: ""))
            @unknown default:
                setStatus(NSLocalizedString("iCloud Status unbekannt.", comment: ""))
            }
        } catch {
            setError(error)
        }
    }

    func markSyncCompleted() {
        // A send finishing while the fetch-apply loop is still running must not flip the
        // status to "complete" and wipe the download progress (that was the per-second
        // status flicker). The fetch path calls this again when it actually finishes.
        guard !isApplyingRemoteChange else {
            postStateChanged()
            return
        }
        guard verifyNoExpectedUserDataWasSkippedBeforeCompleting() else { return }
        let shouldRefreshCloudInventory = syncedUserDataInCurrentRun
        clearSyncActivity()
        if syncedUserDataInCurrentRun {
            let now = Date()
            setSyncMetadata(now, forKey: Self.lastSyncDateKey)
            var payload = localDevicePayload()
            payload["lastSyncDate"] = now
            updateDeviceCache(with: payload)
            postDevicesChanged()
        }
        clearError()
        resetSyncRetryBackoff()
        deviceRecordShouldStampSyncDate = false
        setSyncMetadata(false, forKey: Self.deviceRecordShouldStampSyncDateKey)
        var completionMetadata = syncDiagnosticsMetadata()
        completionMetadata["shouldRefreshCloudInventory"] = shouldRefreshCloudInventory
        logSyncEvent("iCloud Sync abgeschlossen", metadata: completionMetadata)
        if hasInitialUploadBackfillWork {
            // The backfill continues page by page — keep showing upload progress instead
            // of flipping to "complete" and back once per page.
            setStatus(backfillProgressStatusText())
            postStateChanged()
            scheduleCurrentEnabledDataForUpload()
        } else {
            setStatus(NSLocalizedString("Synchronisation vollständig", comment: ""))
            postStateChanged()
            if shouldRefreshCloudInventory {
                refreshCloudInventory(reason: "syncCompletedWithUserData")
            }
            pruneEpisodeLocalModifiedDatesIfNeeded()
        }
        syncedUserDataInCurrentRun = false
    }

    func verifyNoExpectedUserDataWasSkippedBeforeCompleting() -> Bool {
        if syncedUserDataInCurrentRun {
            return true
        }

        if let batch = pendingInitialUploadBatch,
           !batch.episodeRecordNames.isEmpty || !batch.subscriptionRecordNames.isEmpty {
            blockCompletionAndRequeue(reason: "pendingInitialUploadBatchNotSaved", metadata: [
                "pendingInitialEpisodeRecords": batch.episodeRecordNames.count,
                "pendingInitialSubscriptionRecords": batch.subscriptionRecordNames.count,
            ])
            return false
        }

        guard cachedSyncTotalCounts != nil else {
            refreshSyncTotalCountsInBackground()
            blockCompletionAndRequeue(reason: "localSyncCountsUnavailable", metadata: [:])
            return false
        }

        let counts = syncTotalCounts()
        let expectsEpisodes = episodesSyncEnabled && counts.episodes > 0
        let expectsSubscriptions = subscriptionsSyncEnabled && counts.subscriptions > 0
        let expectsSettings = settingsSyncEnabled && counts.settings > 0
        guard expectsEpisodes || expectsSubscriptions || expectsSettings else {
            return true
        }

        let inventory = cloudInventory
        let cloudHasExpectedData = (!expectsEpisodes || (inventory?.episodeStates ?? 0) > 0)
            && (!expectsSubscriptions || (inventory?.subscriptions ?? 0) > 0)
            && (!expectsSettings || (inventory?.settings ?? 0) > 0)
        if cloudHasExpectedData {
            return true
        }

        if expectsEpisodes {
            resetInitialEpisodeBackfillCursor()
        }
        if expectsSubscriptions {
            resetInitialSubscriptionBackfillCursor()
        }
        if expectsSettings {
            defaults.set(true, forKey: Self.initialSettingsBackfillPendingKey)
        }
        blockCompletionAndRequeue(reason: "localDataExpectedButCloudInventoryEmpty", metadata: [
            "localEpisodeCount": counts.episodes,
            "localSubscriptionCount": counts.subscriptions,
            "localSettingsCount": counts.settings,
            "cloudInventoryEpisodeStates": inventory?.episodeStates ?? -1,
            "cloudInventorySubscriptions": inventory?.subscriptions ?? -1,
            "cloudInventorySettings": inventory?.settings ?? -1,
        ])
        refreshCloudInventory(reason: "completionBlockedWithExpectedUserData")
        return false
    }

    func blockCompletionAndRequeue(reason: String, metadata: [String: Any]) {
        hasUnresolvedSyncFailures = true
        clearSyncActivity()
        var details = metadata
        details["reason"] = reason
        details.merge(syncDiagnosticsMetadata()) { current, _ in current }
        logSyncEvent("iCloud Sync Abschluss blockiert", metadata: details)
        setSyncMetadata(NSLocalizedString("iCloud Sync konnte nicht abgeschlossen werden.", comment: ""), forKey: Self.lastErrorKey)
        scheduleCurrentEnabledDataForUpload()
        postStateChanged()
    }

    func backfillProgressStatusText() -> String {
        let counts = syncCounts
        let synced = counts.episodesSynced + counts.subscriptionsSynced
        let total = counts.episodesTotal + counts.subscriptionsTotal
        if total > 0 {
            let format = NSLocalizedString("Lädt hoch… %ld / %ld", comment: "")
            return String(format: format, synced, total)
        }
        return NSLocalizedString("Synchronisation läuft, lädt hoch…", comment: "")
    }

    // Once per session, after a fully completed sync: drop modified-date entries whose
    // episode no longer exists locally (unsubscribed/removed feeds) — the map otherwise
    // grows without bound. If an episode is inserted while the background snapshot is
    // taken, its entry may be dropped once too early; that is benign, the next state
    // change simply re-records it.
    func pruneEpisodeLocalModifiedDatesIfNeeded() {
        guard !didPruneEpisodeLocalModifiedDates, episodesSyncEnabled, !hasInitialUploadBackfillWork else { return }
        didPruneEpisodeLocalModifiedDates = true
        Task.detached(priority: .utility) { [weak self] in
            let existingHashes = await Self.allLocalEpisodeObjectHashes()
            // An empty set means the lookup failed (or the library is empty) — better to
            // skip pruning than to wipe every sync timestamp.
            guard !existingHashes.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                var dates = self.episodeLocalModifiedDates()
                let before = dates.count
                dates = dates.filter { existingHashes.contains($0.key) }
                guard dates.count != before else { return }
                self.episodeLocalModifiedDatesCache = dates
                self.scheduleEpisodeLocalModifiedDatesWrite()
                self.logSyncEvent("Episode-Sync-Metadaten bereinigt", metadata: [
                    "removed": before - dates.count,
                    "remaining": dates.count,
                ])
            }
        }
    }

    nonisolated static func allLocalEpisodeObjectHashes() async -> Set<String> {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else { return [] }
        return await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Episode")
            request.resultType = .dictionaryResultType
            request.includesSubentities = false
            request.propertiesToFetch = ["objectHash"]
            request.predicate = NSPredicate(format: "objectHash != nil")
            let rows = (try? context.fetch(request)) ?? []
            return Set(rows.compactMap { $0["objectHash"] as? String })
        }
    }

    var hasPendingSyncChanges: Bool {
        guard let syncEngine else { return false }
        return !syncEngine.state.pendingDatabaseChanges.isEmpty || !syncEngine.state.pendingRecordZoneChanges.isEmpty
    }

    func syncDiagnosticsMetadata() -> [String: Any] {
        let inventory = cloudInventory
        var metadata: [String: Any] = [
            "pendingDatabaseChanges": syncEngine?.state.pendingDatabaseChanges.count ?? 0,
            "pendingRecordZoneChanges": syncEngine?.state.pendingRecordZoneChanges.count ?? 0,
            "hasInitialUploadBackfillWork": hasInitialUploadBackfillWork,
            "episodeBackfillOffset": (defaults.object(forKey: Self.initialEpisodeBackfillOffsetKey) as? NSNumber)?.intValue ?? -1,
            "subscriptionBackfillOffset": (defaults.object(forKey: Self.initialSubscriptionBackfillOffsetKey) as? NSNumber)?.intValue ?? -1,
            "initialSettingsBackfillPending": defaults.bool(forKey: Self.initialSettingsBackfillPendingKey),
            "syncedUserDataInCurrentRun": syncedUserDataInCurrentRun,
            "hasUnresolvedSyncFailures": hasUnresolvedSyncFailures,
            "syncRetryAttempt": syncRetryAttempt,
            "syncRetryScheduled": syncRetryWorkItem != nil,
            "isFetchingCloudInventory": isFetchingCloudInventory,
            "pendingCloudInventoryRefreshReason": pendingCloudInventoryRefreshReason ?? "",
            "cloudInventoryEpisodeStates": inventory?.episodeStates ?? -1,
            "cloudInventorySubscriptions": inventory?.subscriptions ?? -1,
            "cloudInventorySettings": inventory?.settings ?? -1,
        ]
        if let fetchDate = inventory?.fetchDate {
            metadata["cloudInventoryFetchDate"] = fetchDate
        }
        return metadata
    }

    func beginSyncActivity(_ direction: SyncActivityDirection) {
        if syncActivityDirection != direction {
            syncActivityDirection = direction
            syncActivityStartDate = Date()
            syncActivityRecordCount = 0
            syncActivityExpectedCount = 0
        }
    }

    func recordSyncActivity(_ count: Int) {
        guard count > 0 else { return }
        syncActivityRecordCount += count
    }

    func clearSyncActivity() {
        syncActivityDirection = nil
        syncActivityStartDate = nil
        syncActivityRecordCount = 0
        syncActivityExpectedCount = 0
        syncActivityKindLabel = nil
    }

    nonisolated static func activityKindLabel(forRecordType recordType: String) -> String? {
        switch recordType {
        case RecordKind.episodeState:
            return NSLocalizedString("Episodes", comment: "")
        case RecordKind.subscription:
            return NSLocalizedString("Subscriptions", comment: "")
        case RecordKind.appSettings, RecordKind.listScrollPositions:
            return NSLocalizedString("Settings", comment: "")
        default:
            return nil
        }
    }

    // "Lädt herunter… 6/51" when the total is known (fetch events report it up front),
    // otherwise a throughput estimate ("12/s").
    func syncActivityStatusText() -> String? {
        guard let direction = syncActivityDirection else { return nil }
        let base = direction == .up
            ? NSLocalizedString("Synchronisation läuft, lädt hoch…", comment: "")
            : NSLocalizedString("Synchronisation läuft, lädt herunter…", comment: "")
        if syncActivityExpectedCount > 0 {
            if let kind = syncActivityKindLabel {
                return String(format: NSLocalizedString("%@ %ld/%ld %@", comment: ""), base, syncActivityRecordCount, syncActivityExpectedCount, kind)
            }
            return String(format: NSLocalizedString("%@ %ld/%ld", comment: ""), base, syncActivityRecordCount, syncActivityExpectedCount)
        }
        if let start = syncActivityStartDate, syncActivityRecordCount > 0 {
            let elapsed = max(Date().timeIntervalSince(start), 0.001)
            let rate = Int((Double(syncActivityRecordCount) / elapsed).rounded())
            if rate > 0 {
                return String(format: NSLocalizedString("%@ %ld/s", comment: ""), base, rate)
            }
        }
        // An activity that hasn't moved a single record (e.g. the empty fetch pass of
        // every sync run) shows nothing — flashing "lädt herunter…" although iCloud
        // was empty confused more than it informed.
        return nil
    }

    func markSyncCompletedIfFinished() {
        guard !hasUnresolvedSyncFailures else {
            postStateChanged()
            return
        }
        guard !hasPendingSyncChanges else {
            postStateChanged()
            return
        }
        markSyncCompleted()
    }

    func setStatus(_ status: String) {
        clearError()
        setSyncMetadata(status, forKey: Self.lastStatusKey)
    }

    func setError(_ error: Error) {
        clearSyncActivity()
        deviceRecordShouldStampSyncDate = false
        setSyncMetadata(false, forKey: Self.deviceRecordShouldStampSyncDateKey)
        syncedUserDataInCurrentRun = false
        let status = displayStatus(for: error)
        let nsError = error as NSError
        var metadata = cloudKitErrorMetadata(error)
        metadata["domain"] = nsError.domain
        metadata["code"] = nsError.code
        metadata["status"] = status
        metadata.merge(syncDiagnosticsMetadata()) { current, _ in current }
        logSyncEvent("iCloud Sync Fehler", metadata: metadata)
        setSyncMetadata(status, forKey: Self.lastErrorKey)
        postStateChanged()
    }

    func cloudKitErrorMetadata(_ error: Error) -> [String: Any] {
        let nsError = error as NSError
        var metadata: [String: Any] = [
            "domain": nsError.domain,
            "code": nsError.code,
            "description": nsError.localizedDescription,
        ]
        if let ckError = error as? CKError {
            metadata["ckCode"] = ckError.code.rawValue
            if let retryAfterSeconds = ckError.retryAfterSeconds {
                metadata["retryAfterSeconds"] = Int(retryAfterSeconds.rounded(.up))
            }
            if let partialErrors = ckError.partialErrorsByItemID, !partialErrors.isEmpty {
                metadata["partialErrorCount"] = partialErrors.count
            }
        }
        return metadata
    }

    func displayStatus(for error: Error) -> String {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited:
                return NSLocalizedString("iCloud ist vorübergehend nicht verfügbar.", comment: "")
            case .notAuthenticated:
                return NSLocalizedString("Kein iCloud Account verfügbar.", comment: "")
            case .permissionFailure:
                return NSLocalizedString("iCloud ist auf diesem Gerät eingeschränkt.", comment: "")
            case .limitExceeded:
                return NSLocalizedString("iCloud Sync will continue in smaller batches.", comment: "")
            default:
                break
            }
        }

        let description = (error as NSError).localizedDescription.lowercased()
        if description.contains("request contains") && description.contains("maximum number") {
            return NSLocalizedString("iCloud Sync will continue in smaller batches.", comment: "")
        }
        return NSLocalizedString("iCloud Sync konnte nicht abgeschlossen werden.", comment: "")
    }

    func clearError() {
        setSyncMetadata(nil, forKey: Self.lastErrorKey)
    }

    nonisolated static func isFileBackedSyncMetadataKey(_ key: String) -> Bool {
        fileBackedSyncMetadataKeys.contains(key)
    }

    nonisolated static func syncMetadataDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directoryURL = baseURL.appendingPathComponent(syncMetadataDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var excludedURL = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedURL.setResourceValues(resourceValues)
        return directoryURL
    }

    nonisolated static func syncMetadataFileURL(forKey key: String) -> URL {
        syncMetadataDirectoryURL().appendingPathComponent(key).appendingPathExtension("plist")
    }

    nonisolated static func knownRecordSystemFieldsDirectoryURL() -> URL {
        let directoryURL = syncMetadataDirectoryURL().appendingPathComponent(knownRecordSystemFieldsDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var excludedURL = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedURL.setResourceValues(resourceValues)
        return directoryURL
    }

    nonisolated static func knownRecordSystemFieldsFileURL(forRecordName recordName: String) -> URL {
        knownRecordSystemFieldsDirectoryURL().appendingPathComponent(sha256Hex(recordName)).appendingPathExtension("record")
    }

    nonisolated static func knownRecordSystemFieldsData(forRecordName recordName: String) -> Data? {
        try? Data(contentsOf: knownRecordSystemFieldsFileURL(forRecordName: recordName))
    }

    nonisolated static func writeKnownRecordSystemFields(_ data: Data, forRecordName recordName: String) {
        try? data.write(to: knownRecordSystemFieldsFileURL(forRecordName: recordName), options: .atomic)
    }

    nonisolated static func removeKnownRecordSystemFields(forRecordName recordName: String) {
        try? FileManager.default.removeItem(at: knownRecordSystemFieldsFileURL(forRecordName: recordName))
    }

    nonisolated static func removeAllKnownRecordSystemFields() {
        let directoryURL = knownRecordSystemFieldsDirectoryURL()
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { return }
        for fileURL in fileURLs {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    @objc nonisolated static func purgeLegacyDefaultsBackedSyncMetadata() {
        let defaults = UserDefaults.standard
        let keys = fileBackedSyncMetadataKeys
            .union([
                initialEpisodeBackfillOffsetKey,
                initialSubscriptionBackfillOffsetKey,
                initialSettingsBackfillPendingKey,
            ])
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        removeSyncMetadataValue(forKey: knownRecordsKey)
    }

    nonisolated static func syncMetadataValue(forKey key: String) -> Any? {
        if key == knownRecordsKey {
            return nil
        }
        if isFileBackedSyncMetadataKey(key) {
            let url = syncMetadataFileURL(forKey: key)
            if let data = try? Data(contentsOf: url),
               let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                return value
            }
            return nil
        }
        return UserDefaults.standard.object(forKey: key)
    }

    nonisolated static func writeSyncMetadataValue(_ value: Any, forKey key: String) throws -> Int {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        try data.write(to: syncMetadataFileURL(forKey: key), options: .atomic)
        return data.count
    }

    nonisolated static func removeSyncMetadataValue(forKey key: String) {
        try? FileManager.default.removeItem(at: syncMetadataFileURL(forKey: key))
    }

    nonisolated static func syncMetadataSummary(for value: Any?) -> [String: String] {
        guard let value else { return ["valueType": "nil"] }

        var summary: [String: String] = ["valueType": String(describing: type(of: value))]
        if let data = value as? Data {
            summary["valueBytes"] = "\(data.count)"
        } else if let data = value as? NSData {
            summary["valueBytes"] = "\(data.length)"
        } else if let dictionary = value as? NSDictionary {
            summary["entryCount"] = "\(dictionary.count)"
        } else if let array = value as? NSArray {
            summary["entryCount"] = "\(array.count)"
        }
        if let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) {
            summary["plistBytes"] = "\(data.count)"
        }
        return summary
    }

    nonisolated static func syncMetadataStorageSnapshot(reason: String) -> [String: String] {
        var metadata: [String: String] = [
            "reason": reason,
            "isMainThread": Thread.isMainThread ? "1" : "0",
            "threadID": "\(pthread_mach_thread_np(pthread_self()))",
        ]

        let fileManager = FileManager.default
        for key in fileBackedSyncMetadataKeys.sorted() {
            let fileURL = syncMetadataFileURL(forKey: key)
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let fileSize = attributes[.size] as? NSNumber {
                metadata["file.\(key).bytes"] = "\(fileSize.intValue)"
            } else {
                metadata["file.\(key).bytes"] = "0"
            }
        }

        let knownRecordDirectory = knownRecordSystemFieldsDirectoryURL()
        let knownRecordFiles = (try? fileManager.contentsOfDirectory(at: knownRecordDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let knownRecordBytes = knownRecordFiles.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + size
        }
        metadata["knownRecords.fileCount"] = "\(knownRecordFiles.count)"
        metadata["knownRecords.totalBytes"] = "\(knownRecordBytes)"

        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        var encodedSizes: [(key: String, bytes: Int)] = []
        for (key, value) in domain {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { continue }
            encodedSizes.append((key: key, bytes: data.count))
            if fileBackedSyncMetadataKeys.contains(key) || nonSettingsUserDefaultsKeysForSyncEngineCallback().contains(key) || key.hasPrefix("ICiCloudSync") {
                metadata["defaults.\(key).bytes"] = "\(data.count)"
            }
        }

        metadata["defaults.keyCount"] = "\(domain.count)"
        metadata["defaults.totalEncodedBytes"] = "\(encodedSizes.reduce(0) { $0 + $1.bytes })"
        for (index, entry) in encodedSizes.sorted(by: { $0.bytes > $1.bytes }).prefix(12).enumerated() {
            metadata["defaults.top\(index + 1)"] = "\(entry.key):\(entry.bytes)"
        }
        return metadata
    }

    func logSyncMetadataDiagnostic(operation: String, key: String, storage: String, bytes: Int?, value: Any?, error: Error? = nil) {
        var metadata = Self.syncMetadataSummary(for: value)
        metadata["operation"] = operation
        metadata["key"] = key
        metadata["storage"] = storage
        metadata["isMainThread"] = Thread.isMainThread ? "1" : "0"
        metadata["threadID"] = "\(pthread_mach_thread_np(pthread_self()))"
        if let bytes {
            metadata["bytes"] = "\(bytes)"
        }
        if let error {
            metadata["error"] = String(describing: error)
        }
        ICDiagnosticLogger.shared.logEvent("icloud-sync-metadata",
                                           message: "iCloud-Sync-Metadaten \(operation)",
                                           metadata: metadata as NSDictionary)
    }

    func setSyncMetadata(_ value: Any?, forKey key: String) {
        // No per-write logging here: metadata writes are far too frequent to log each one
        // (this once flooded the diagnostics log to 26 MB). Only genuine write failures are
        // logged, which are the actionable cases.
        isWritingSyncMetadata = true
        if Self.isFileBackedSyncMetadataKey(key) {
            if let value {
                do {
                    _ = try Self.writeSyncMetadataValue(value, forKey: key)
                    defaults.removeObject(forKey: key)
                } catch {
                    logSyncMetadataDiagnostic(operation: "write-failed", key: key, storage: "file", bytes: nil, value: value, error: error)
                }
            } else {
                Self.removeSyncMetadataValue(forKey: key)
                defaults.removeObject(forKey: key)
            }
        } else if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        isWritingSyncMetadata = false
    }

    func postStateChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: NSNotification.Name.ICiCloudSyncStateDidChange, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name.ICiCloudSyncStateDidChange, object: self)
            }
        }
    }

    func postDevicesChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: NSNotification.Name.ICiCloudSyncDevicesDidChange, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name.ICiCloudSyncDevicesDidChange, object: self)
            }
        }
    }
}

private protocol OptionalProtocol {
    var isNil: Bool { get }
}

extension Optional: OptionalProtocol {
    var isNil: Bool { self == nil }
}
