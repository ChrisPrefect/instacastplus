//
//  ICiCloudSyncManager.swift
//  Instacast
//

@preconcurrency import CloudKit
import CoreData
import CryptoKit
import Darwin
import Foundation
import UIKit

@available(iOS 17.0, *)
@MainActor
@objcMembers final class ICiCloudSyncManager: NSObject, CKSyncEngineDelegate {
    @objc(sharedManager) static let shared = ICiCloudSyncManager()

    @objc static var isAvailable: Bool {
        if #available(iOS 17.0, *) {
            return true
        }
        return false
    }

    nonisolated static let containerIdentifier = "iCloud.com.iteconomy.instacastplus"
    nonisolated static let zoneName = "InstacastSync"
    nonisolated static let schemaVersion = 1

    nonisolated static let deviceIDKey = "ICiCloudSyncDeviceID"
    nonisolated static let engineStateKey = "ICiCloudSyncEngineState"
    nonisolated static let knownRecordsKey = "ICiCloudSyncKnownRecords"
    nonisolated static let deviceCacheKey = "ICiCloudSyncDeviceCache"
    nonisolated static let subscriptionRecordURLsKey = "ICiCloudSyncSubscriptionRecordURLs"
    nonisolated static let pendingEpisodeStatesKey = "ICiCloudSyncPendingEpisodeStates"
    nonisolated static let pendingSubscriptionPayloadsKey = "ICiCloudSyncPendingSubscriptionPayloads"
    nonisolated static let episodeLocalModifiedDatesKey = "ICiCloudSyncEpisodeLocalModifiedDates"
    nonisolated static let subscriptionLocalModifiedDatesKey = "ICiCloudSyncSubscriptionLocalModifiedDates"
    nonisolated static let subscriptionPayloadHashesKey = "ICiCloudSyncSubscriptionPayloadHashes"
    nonisolated static let initialEpisodeBackfillOffsetKey = "ICiCloudSyncInitialEpisodeBackfillOffset"
    nonisolated static let initialSubscriptionBackfillOffsetKey = "ICiCloudSyncInitialSubscriptionBackfillOffset"
    nonisolated static let initialSettingsBackfillPendingKey = "ICiCloudSyncInitialSettingsBackfillPending"
    nonisolated static let pendingInitialSettingsPayloadKey = "ICiCloudSyncPendingInitialSettingsPayload"
    @objc static let initialSettingsChoiceNeededNotification = "ICiCloudSyncInitialSettingsChoiceNeeded"
    nonisolated static let settingsLocalModifiedDateKey = "ICiCloudSyncSettingsLocalModifiedDate"
    nonisolated static let settingsSyncedHashKey = "ICiCloudSyncSettingsSyncedHash"
    nonisolated static let suppressSubscriptionDeletionsKey = "ICiCloudSyncSuppressSubscriptionDeletions"
    nonisolated static let cloudInventoryKey = "ICiCloudSyncCloudInventory"
    nonisolated static let subscriptionListSettingsLocalModifiedDateKey = "ICiCloudSyncSubscriptionListSettingsLocalModifiedDate"
    nonisolated static let subscriptionListSettingsBaselineKey = "ICiCloudSyncSubscriptionListSettingsBaseline"
    // Mirrors the file-private kManualFeedOrderKey in DatabaseManager.m.
    nonisolated static let manualFeedOrderDefaultsKey = "ManualFeedOrder"
    nonisolated static let scrollPositionsLocalModifiedDateKey = "ICiCloudSyncScrollPositionsLocalModifiedDate"
    nonisolated static let lastSyncDateKey = "ICiCloudSyncLastSyncDate"
    nonisolated static let lastStatusKey = "ICiCloudSyncLastStatus"
    nonisolated static let lastErrorKey = "ICiCloudSyncLastError"
    nonisolated static let deviceRecordShouldStampSyncDateKey = "ICiCloudSyncDeviceRecordShouldStampSyncDate"
    // CloudKit allows up to 400 record operations per batch. Keeping it well above the backfill
    // page size (200) means a page of episodes + the device record ship in ONE batch instead of
    // a 200-record batch plus a 2-record leftover round-trip.
    nonisolated static let maximumRecordZoneChangesPerBatch = 400
    nonisolated static let pendingChangeQueueChunkSize = 200
    nonisolated static let syncMetadataDirectoryName = "iCloudSyncMetadata"
    nonisolated static let knownRecordSystemFieldsDirectoryName = "KnownRecords"

    nonisolated static var fileBackedSyncMetadataKeys: Set<String> {
        [
            Self.engineStateKey,
            Self.knownRecordsKey,
            Self.deviceCacheKey,
            Self.subscriptionRecordURLsKey,
            Self.pendingEpisodeStatesKey,
            Self.pendingSubscriptionPayloadsKey,
            Self.episodeLocalModifiedDatesKey,
            Self.subscriptionLocalModifiedDatesKey,
            Self.subscriptionPayloadHashesKey,
        ]
    }

    enum RecordKind {
        static let device = "ICDevice"
        static let episodeState = "ICEpisodeState"
        static let subscription = "ICSubscription"
        static let appSettings = "ICAppSettings"
        static let listScrollPositions = "ICListScrollPositions"
        static let subscriptionListSettings = "ICSubscriptionListSettings"
    }

    enum RecordPrefix {
        static let device = "device_"
        static let episode = "episode_"
        static let subscription = "subscription_"
        static let appSettings = "settings_app"
        static let listScrollPositions = "settings_listScrollPositions"
        static let subscriptionListSettings = "settings_subscriptionList"
    }

    let defaults = UserDefaults.standard
    let container = CKContainer(identifier: ICiCloudSyncManager.containerIdentifier)
    let zoneID = CKRecordZone.ID(zoneName: ICiCloudSyncManager.zoneName)
    var syncEngine: CKSyncEngine?
    var isStarted = false
    var isApplyingRemoteChange = false
    var isWritingSyncMetadata = false
    var hasUnresolvedSyncFailures = false
    var settingsDebounceWorkItem: DispatchWorkItem?
    var scrollDebounceWorkItem: DispatchWorkItem?
    var applyPendingDebounceWorkItem: DispatchWorkItem?
    var episodeLocalModifiedDatesCache: [String: TimeInterval]?
    var episodeLocalModifiedDatesWriteWorkItem: DispatchWorkItem?
    var subscriptionPayloadHashesCache: [String: String]?
    var cachedSyncTotalCounts: (episodes: Int, subscriptions: Int, settings: Int, timestamp: Date)?
    var isRefreshingSyncTotalCounts = false
    // Object IDs that were just mutated by applying remote records. The objects-did-change
    // notification for those mutations arrives in batches (at processPendingChanges time),
    // possibly only after the whole fetch-apply pass is over — a time-window flag like
    // `isApplyingRemoteChange` cannot tell remote applies from genuine local edits there,
    // which systematically echoed the last batch of every fetch back up (with a fresh
    // `updatedAt`, weakening last-writer-wins). Only IDs whose apply REALLY changed a value
    // are recorded, and each ID absolves exactly one observer pass, so a later genuine
    // local edit of the same object still syncs.
    var remoteAppliedObjectIDs: Set<NSManagedObjectID> = []
    var lastForegroundSyncDate: Date?
    var didPruneEpisodeLocalModifiedDates = false
    // In-memory cache for the two pending-payload stores. A single fetch can store
    // thousands of payloads (episode states arriving while episode sync is off) —
    // re-reading and re-writing the whole plist per record was quadratic disk I/O on
    // the main thread and froze the device for the duration of the download.
    var pendingPayloadsCache: [String: [String: [String: Any]]] = [:]
    var dirtyPendingPayloadKeys: Set<String> = []
    var pendingPayloadsWriteWorkItem: DispatchWorkItem?
    var syncActivityExpectedCount = 0
    var syncActivityKindLabel: String?
    var isFetchingCloudInventory = false
    var pendingCloudInventoryRefreshReason: String?
    var isHydratingStubFeeds = false
    var hydrationCompletedCount = 0
    var hydrationTotalCount = 0
    var hydrationFailedFeedIDs: Set<NSManagedObjectID> = []
    var isWaitingForEpisodeLoader = false
    var episodeLoaderWaitGeneration = 0
    var needsSubscriptionListSortApply = false
    var pendingInitialUploadBatch: InitialUploadBatch?
    var initialQueueTask: Task<Void, Never>?
    var lowPrioritySyncTask: Task<Void, Never>?
    var syncRetryAttempt = 0
    var syncRetryWorkItem: DispatchWorkItem?
    enum SyncActivityDirection { case up, down }
    var syncActivityDirection: SyncActivityDirection?
    var syncActivityStartDate: Date?
    var syncActivityRecordCount = 0
    var deviceRecordShouldStampSyncDate = false
    var syncedUserDataInCurrentRun = false

    var databaseManager: DatabaseManager {
        DatabaseManager.shared()!
    }

    var subscriptionManager: SubscriptionManager {
        SubscriptionManager.shared()!
    }

    @objc var episodesSyncEnabled: Bool {
        defaults.bool(forKey: ICiCloudSyncEpisodesEnabled)
    }

    @objc var subscriptionsSyncEnabled: Bool {
        defaults.bool(forKey: ICiCloudSyncSubscriptionsEnabled)
    }

    @objc var settingsSyncEnabled: Bool {
        defaults.bool(forKey: ICiCloudSyncSettingsEnabled)
    }

    @objc var anySyncEnabled: Bool {
        episodesSyncEnabled || subscriptionsSyncEnabled || settingsSyncEnabled
    }

    @objc var lastSyncDate: Date? {
        defaults.object(forKey: Self.lastSyncDateKey) as? Date
    }

    @objc var syncCounts: ICiCloudSyncCounts {
        let totals = syncTotalCounts()
        return ICiCloudSyncCounts(
            episodesSynced: episodesSyncEnabled ? syncedCount(backfillKey: Self.initialEpisodeBackfillOffsetKey, total: totals.episodes) : 0,
            episodesTotal: episodesSyncEnabled ? totals.episodes : 0,
            subscriptionsSynced: subscriptionsSyncEnabled ? syncedCount(backfillKey: Self.initialSubscriptionBackfillOffsetKey, total: totals.subscriptions) : 0,
            subscriptionsTotal: subscriptionsSyncEnabled ? totals.subscriptions : 0,
            settings: settingsSyncEnabled ? totals.settings : 0,
            countsAvailable: cachedSyncTotalCounts != nil)
    }

    // How many of `total` are already synced: while the initial backfill runs, its persisted
    // page cursor is how far we've gotten; once it's cleared the whole set is synced.
    func syncedCount(backfillKey: String, total: Int) -> Int {
        guard let offset = (defaults.object(forKey: backfillKey) as? NSNumber)?.intValue else {
            return total
        }
        return min(max(offset, 0), total)
    }

    // Stable totals of what's kept in iCloud, counted directly in Core Data so the number is
    // the real total (e.g. "4490 episodes with play state") instead of a sync-progress figure.
    // The count itself runs on a BACKGROUND context — never the main thread — because a
    // count on the main context can block for seconds waiting on the SQLite store lock that
    // the background backfill/refresh holds (this was a multi-second UI freeze when toggling a
    // switch). The UI shows the last computed value and refreshes when a new one is ready.
    func syncTotalCounts() -> (episodes: Int, subscriptions: Int, settings: Int) {
        let cached = cachedSyncTotalCounts
        // 15 s TTL: the settings screen reloads on a 10 s timer plus every state change;
        // a 2 s TTL re-ran the COUNT queries (a full episode-table scan) almost every time.
        if cached == nil || Date().timeIntervalSince(cached!.timestamp) >= 15.0 {
            refreshSyncTotalCountsInBackground()
        }
        return (cached?.episodes ?? 0, cached?.subscriptions ?? 0, cached?.settings ?? 0)
    }

    func refreshSyncTotalCountsInBackground() {
        guard !isRefreshingSyncTotalCounts else { return }
        isRefreshingSyncTotalCounts = true
        let episodesEnabled = episodesSyncEnabled
        let subscriptionsEnabled = subscriptionsSyncEnabled
        let settingsEnabled = settingsSyncEnabled
        Task.detached(priority: .utility) { [weak self] in
            let counts = await Self.computeSyncTotalCounts(episodesEnabled: episodesEnabled, subscriptionsEnabled: subscriptionsEnabled, settingsEnabled: settingsEnabled)
            await MainActor.run {
                guard let self else { return }
                self.cachedSyncTotalCounts = (counts.episodes, counts.subscriptions, counts.settings, Date())
                self.isRefreshingSyncTotalCounts = false
                self.postStateChanged()
            }
        }
    }

    nonisolated static func computeSyncTotalCounts(episodesEnabled: Bool, subscriptionsEnabled: Bool, settingsEnabled: Bool) async -> (episodes: Int, subscriptions: Int, settings: Int) {
        // The settings count copies and filters the whole defaults domain — do that here,
        // off the main thread, together with the Core Data counts.
        let settings = settingsEnabled ? syncedSettingsValueCount() : 0
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else { return (0, 0, settings) }
        return await context.perform {
            var episodes = 0
            var subscriptions = 0
            if episodesEnabled {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Episode")
                request.predicate = NSPredicate(format: "feed.subscribed == YES AND archived == NO AND objectHash != nil AND (consumed == YES OR starred == YES OR position > 0)")
                episodes = (try? context.count(for: request)) ?? 0
            }
            if subscriptionsEnabled {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Feed")
                request.predicate = NSPredicate(format: "subscribed == YES AND sourceURL_ != nil")
                subscriptions = (try? context.count(for: request)) ?? 0
            }
            return (episodes, subscriptions, settings)
        }
    }

    nonisolated static func syncedSettingsValueCount() -> Int {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        var count = 0
        for (key, value) in domain where shouldSyncSettingsKeyForSyncEngineCallback(key) && isValidSettingsValueForSyncEngineCallback(value) {
            count += 1
        }
        return count
    }

    @objc var statusText: String {
        guard anySyncEnabled else { return NSLocalizedString("Aus", comment: "") }
        if let error = defaults.string(forKey: Self.lastErrorKey), !error.isEmpty {
            return error
        }
        if isHydratingStubFeeds, hydrationTotalCount > 0 {
            return String(format: NSLocalizedString("Lade Podcast-Folgen… %ld/%ld", comment: ""), hydrationCompletedCount, hydrationTotalCount)
        }
        // While the initial backfill pages through, the stable "Lädt hoch… X / Y"
        // (lastStatus, updated per page) wins over the per-batch activity counter —
        // alternating between the two number formats read as status "flickering".
        if !hasInitialUploadBackfillWork, let activity = syncActivityStatusText() {
            return activity
        }
        if let status = defaults.string(forKey: Self.lastStatusKey), !status.isEmpty {
            return status
        }
        return NSLocalizedString("Bereit", comment: "")
    }

    @objc var devices: [ICiCloudSyncDeviceInfo] {
        deviceCache().compactMap { key, value in
            let value = key == deviceID ? value.merging(localDevicePayload()) { _, current in current } : value
            guard deviceParticipates(value) else { return nil }
            let name = value["name"] as? String ?? NSLocalizedString("Unbekanntes Gerät", comment: "")
            let model = value["model"] as? String ?? ""
            let systemVersion = value["systemVersion"] as? String ?? ""
            let appVersion = value["appVersion"] as? String ?? ""
            let lastSyncDate = value["lastSyncDate"] as? Date
            return ICiCloudSyncDeviceInfo(deviceID: key,
                                          name: name,
                                          model: model,
                                          systemVersion: systemVersion,
                                          appVersion: appVersion,
                                          lastSyncDate: lastSyncDate,
                                          episodesEnabled: (value["episodesEnabled"] as? Bool) ?? false,
                                          subscriptionsEnabled: (value["subscriptionsEnabled"] as? Bool) ?? false,
                                          settingsEnabled: (value["settingsEnabled"] as? Bool) ?? false,
                                          isCurrentDevice: key == deviceID)
        }.sorted { first, second in
            if first.isCurrentDevice != second.isCurrentDevice {
                return first.isCurrentDevice
            }
            let firstDate = first.lastSyncDate ?? Date(timeIntervalSince1970: 0)
            let secondDate = second.lastSyncDate ?? Date(timeIntervalSince1970: 0)
            return firstDate.compare(secondDate) == .orderedDescending
        }
    }

    override init() {
        super.init()
    }

    @objc nonisolated static func logSyncMetadataStorageSnapshot(_ reason: String) {
        Task.detached(priority: .utility) {
            let metadata = syncMetadataStorageSnapshot(reason: reason)
            ICDiagnosticLogger.shared.logEvent("icloud-sync-metadata",
                                               message: "iCloud-Sync-Metadaten-Snapshot",
                                               metadata: metadata as NSDictionary)
        }
    }

    @objc func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(defaultsDidChange(_:)), name: UserDefaults.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(coreDataDidChange(_:)), name: .NSManagedObjectContextObjectsDidChange, object: databaseManager.objectContext)
        center.addObserver(self, selector: #selector(listScrollPositionsDidChange(_:)), name: NSNotification.Name.ICListScrollPositionsDidChange, object: nil)
        center.addObserver(self, selector: #selector(episodesWereAdded(_:)), name: NSNotification.Name.SubscriptionManagerDidAddEpisodes, object: nil)
        center.addObserver(self, selector: #selector(episodeLoadingDidFinish(_:)), name: NSNotification.Name.EpisodeLoadingManagerDidFinishLoading, object: nil)

        if anySyncEnabled {
            initializeSyncEngineIfNeeded()
            queueDeviceRecordForPendingUserDataIfNeeded()
            if hasInitialUploadBackfillWork {
                scheduleCurrentEnabledDataForUpload()
            }
            // Retry payloads that arrived before their episode/feed existed locally and
            // whose normal trigger (new episodes added) didn't fire again before the app
            // was quit — without this they could sit in the pending store indefinitely.
            scheduleApplyPendingPayloads()
            // Publishes the sort mode/settings if their fingerprint baseline is missing
            // (devices that enabled subscription sync before this record type existed).
            scheduleSettingsChangeCheck()
            hydrateStubFeedsIfNeeded()
            Task { @MainActor in
                await refreshAccountStatus()
            }
        }
    }

    // CKSyncEngine runs with automaticallySync = false, so nothing syncs on its own:
    // remote changes only arrive via push (best effort — often dropped after a force
    // quit), after a local change, or via manual sync. Without this hook a device could
    // stay on a stale state indefinitely while showing "Bereit". Called on launch and on
    // foreground entry, throttled like the feed auto-refresh.
    @objc func performForegroundSyncIfNeeded() {
        guard isStarted, anySyncEnabled else { return }
        let now = Date()
        if let last = lastForegroundSyncDate, now.timeIntervalSince(last) < 15 * 60 {
            return
        }
        lastForegroundSyncDate = now
        logSyncEvent("Foreground-Sync angestoßen")
        scheduleLowPrioritySync()
        // Resume any interrupted episode loading for stub feeds; feeds that failed in
        // the previous session/run get one fresh attempt per foreground entry.
        hydrationFailedFeedIDs.removeAll()
        hydrateStubFeedsIfNeeded()
    }

    @objc func setEpisodesSyncEnabled(_ enabled: Bool) {
        guard episodesSyncEnabled != enabled else { return }
        defaults.set(enabled, forKey: ICiCloudSyncEpisodesEnabled)
        if enabled {
            resetInitialEpisodeBackfillCursor()
        } else {
            clearInitialEpisodeBackfillCursor()
        }
        logSyncEvent("Episode Sync-Schalter geändert", metadata: ["enabled": enabled])
        syncOptionsChanged()
    }

    @objc func setSubscriptionsSyncEnabled(_ enabled: Bool) {
        guard subscriptionsSyncEnabled != enabled else { return }
        defaults.set(enabled, forKey: ICiCloudSyncSubscriptionsEnabled)
        if enabled {
            resetInitialSubscriptionBackfillCursor()
            // Enabling must NEVER delete local subscriptions: deletions that piled up in
            // the cloud while sync was off arrive in the catch-up fetch and are suppressed
            // until the first complete fetch has run (union semantics — the local copy is
            // re-uploaded by the backfill). Only live deletions after that are applied.
            defaults.set(true, forKey: Self.suppressSubscriptionDeletionsKey)
        } else {
            clearInitialSubscriptionBackfillCursor()
            defaults.removeObject(forKey: Self.suppressSubscriptionDeletionsKey)
        }
        logSyncEvent("Abo Sync-Schalter geändert", metadata: ["enabled": enabled])
        syncOptionsChanged()
    }

    @objc func setSettingsSyncEnabled(_ enabled: Bool) {
        guard settingsSyncEnabled != enabled else { return }
        defaults.set(enabled, forKey: ICiCloudSyncSettingsEnabled)
        if enabled {
            defaults.set(true, forKey: Self.initialSettingsBackfillPendingKey)
        } else {
            defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
            setSyncMetadata(nil, forKey: Self.pendingInitialSettingsPayloadKey)
            setStoredSyncedSettingsHash(nil)
        }
        logSyncEvent("Einstellungs-Sync-Schalter geändert", metadata: ["enabled": enabled])
        syncOptionsChanged()
    }

    @objc func syncOptionsChanged() {
        guard isStarted else { return }

        logSyncEvent("Sync-Optionen geändert")
        if anySyncEnabled {
            // The device record (option flags for the other devices' lists) is queued by
            // the plan task — never synchronously in the switch tap (engine-state access
            // is queue-sensitive; that was part of the toggle freeze).
            scheduleCurrentEnabledDataForUpload()
            // Apply payloads that were stored while the category was off (debounced,
            // enabled-gated — no engine access in the switch tap).
            scheduleApplyPendingPayloads()
            setStatus(NSLocalizedString("iCloud prüfen…", comment: ""))
            Task { @MainActor in
                await refreshAccountStatus()
            }
        } else if syncEngine != nil {
            logSyncEvent("iCloud Sync deaktiviert")
            clearError()
            cancelInitialQueueTask()
            cancelLowPrioritySyncTask()
            clearInitialUploadCursors()
            queueDeviceRecord()
            // One final send: scheduleLowPrioritySync refuses to run with every category
            // off, so the device record (now flagged all-off) would stay pending forever
            // and other devices would keep showing this device as actively syncing.
            sendFinalDeviceRecordUpdate()
            setStatus(NSLocalizedString("Aus", comment: ""))
        }

        postStateChanged()
    }

    func sendFinalDeviceRecordUpdate() {
        guard let syncEngine else { return }
        Task(priority: .background) {
            try? await syncEngine.sendChanges()
        }
    }

    @objc func performManualSyncWithCompletion(_ completion: @escaping (NSError?) -> Void) {
        Task { @MainActor in
            do {
                try await performManualSync()
                completion(nil)
            } catch {
                setError(error)
                completion(error as NSError)
            }
        }
    }

    // Deletes the entire CloudKit sync zone (all synced data, for every device) and wipes all
    // local sync bookkeeping. If any category is still enabled, a fresh full re-upload starts.
    @objc func deleteAllICloudDataWithCompletion(_ completion: @escaping (NSError?) -> Void) {
        Task { @MainActor in
            cancelInitialQueueTask()
            cancelLowPrioritySyncTask()
            setStatus(NSLocalizedString("Lösche iCloud-Daten…", comment: ""))
            postStateChanged()

            do {
                _ = try await database.deleteRecordZone(withID: zoneID)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                // Already gone — treat as success.
            } catch {
                setError(error)
                completion(error as NSError)
                return
            }

            syncEngine = nil
            resetAllLocalSyncMetadata()
            // The "On iCloud" rows kept showing the pre-delete counts (stale cache,
            // refreshed only every 30s) — reflect the now-empty zone immediately.
            storeCloudInventory([:], reason: "deleteAllICloudData")

            if anySyncEnabled {
                initializeSyncEngineIfNeeded()
                resetInitialBackfillCursorsForEnabledOptions()
                if settingsSyncEnabled {
                    defaults.set(true, forKey: Self.initialSettingsBackfillPendingKey)
                }
                scheduleCurrentEnabledDataForUpload()
                setStatus(NSLocalizedString("iCloud-Daten gelöscht.", comment: ""))
            } else {
                setStatus(NSLocalizedString("Aus", comment: ""))
            }
            postStateChanged()
            postDevicesChanged()
            completion(nil)
        }
    }

    func resetAllLocalSyncMetadata() {
        setSyncMetadata(nil, forKey: Self.engineStateKey)
        Self.removeSyncMetadataValue(forKey: Self.knownRecordsKey)
        Self.removeAllKnownRecordSystemFields()
        for key in [Self.subscriptionRecordURLsKey, Self.subscriptionLocalModifiedDatesKey,
                    Self.subscriptionPayloadHashesKey, Self.episodeLocalModifiedDatesKey,
                    Self.deviceCacheKey, Self.pendingEpisodeStatesKey, Self.pendingSubscriptionPayloadsKey,
                    Self.pendingInitialSettingsPayloadKey] {
            setSyncMetadata(nil, forKey: key)
        }
        for key in [Self.settingsLocalModifiedDateKey, Self.settingsSyncedHashKey,
                    Self.scrollPositionsLocalModifiedDateKey, Self.suppressSubscriptionDeletionsKey,
                    Self.subscriptionListSettingsLocalModifiedDateKey, Self.subscriptionListSettingsBaselineKey,
                    Self.lastSyncDateKey, Self.deviceRecordShouldStampSyncDateKey] {
            defaults.removeObject(forKey: key)
        }
        episodeLocalModifiedDatesCache = nil
        subscriptionPayloadHashesCache = nil
        pendingPayloadsCache = [:]
        dirtyPendingPayloadKeys = []
        cachedSyncTotalCounts = nil
        deviceRecordShouldStampSyncDate = false
        syncedUserDataInCurrentRun = false
        clearInitialUploadCursors()
        clearSyncActivity()
        clearError()
    }

    @objc func shouldHandleRemoteNotification(_ userInfo: NSDictionary) -> Bool {
        guard let notification = userInfo as? [AnyHashable: Any] else { return false }
        return CKNotification(fromRemoteNotificationDictionary: notification) != nil
    }

    @objc func performBackgroundSyncWithCompletion(_ completion: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            guard anySyncEnabled else {
                completion(.noData)
                return
            }

            initializeSyncEngineIfNeeded()
            hasUnresolvedSyncFailures = false

            do {
                if let syncEngine {
                    try await syncEngine.fetchChanges()
                }
                if !hasUnresolvedSyncFailures {
                    markSyncCompletedIfFinished()
                    completion(.newData)
                } else {
                    postStateChanged()
                    completion(.failed)
                }
            } catch {
                setError(error)
                completion(.failed)
            }
        }
    }

    // Last known hard cloud inventory (persisted, so the screen can show the previous
    // state right away — even before sync is ever enabled).
    @objc var cloudInventory: ICiCloudSyncCloudInventory? {
        guard let stored = defaults.dictionary(forKey: Self.cloudInventoryKey),
              let fetchDate = stored["fetchDate"] as? Date else { return nil }
        return ICiCloudSyncCloudInventory(episodeStates: (stored["episodeStates"] as? NSNumber)?.intValue ?? 0,
                                          subscriptions: (stored["subscriptions"] as? NSNumber)?.intValue ?? 0,
                                          settings: (stored["settings"] as? NSNumber)?.intValue ?? 0,
                                          fetchDate: fetchDate)
    }

    // Counts the records that are actually ON iCloud, by type, with a full zone listing
    // (metadata only, no payloads). Deliberately not a CKQuery: recordName is not
    // queryable without dashboard-managed indexes. Runs independently of the sync engine
    // and of the enabled switches.
    @objc func refreshCloudInventory() {
        refreshCloudInventory(reason: "settingsView")
    }

    func refreshCloudInventory(reason: String) {
        guard !isFetchingCloudInventory else {
            // A refresh is already in flight; remember the reason so it re-runs afterwards.
            // No diagnostics line here — this "skipped" path fired 253× in one capture (pure noise).
            pendingCloudInventoryRefreshReason = reason
            return
        }
        pendingCloudInventoryRefreshReason = nil
        isFetchingCloudInventory = true
        var metadata: [String: Any] = ["reason": reason]
        metadata.merge(syncDiagnosticsMetadata()) { current, _ in current }
        logSyncEvent("Cloud-Inventar-Abfrage gestartet", metadata: metadata)

        let box = ICCloudInventoryCountsBox()
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.desiredKeys = []
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID],
                                                          configurationsByRecordZoneID: [zoneID: configuration])
        operation.fetchAllChanges = true
        operation.qualityOfService = .utility
        operation.recordWasChangedBlock = { _, result in
            if case .success(let record) = result {
                box.record(record)
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            box.remove(recordName: recordID.recordName)
        }
        operation.fetchRecordZoneChangesResultBlock = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFetchingCloudInventory = false
                switch result {
                case .success:
                    self.storeCloudInventory(box.snapshot(), reason: reason)
                    self.fetchDeviceRecordsForInventory(box.deviceIDs())
                case .failure(let error):
                    if let ckError = error as? CKError, ckError.code == .zoneNotFound || ckError.code == .userDeletedZone {
                        self.storeCloudInventory([:], reason: reason)
                    } else {
                        var metadata = self.cloudKitErrorMetadata(error)
                        metadata["reason"] = reason
                        metadata.merge(self.syncDiagnosticsMetadata()) { current, _ in current }
                        self.logSyncEvent("Cloud-Inventar-Abfrage fehlgeschlagen", metadata: metadata)
                    }
                }
                self.runPendingCloudInventoryRefreshIfNeeded()
            }
        }
        database.add(operation)
    }

    // The device list used to stay empty ("Noch keine synchronisierten Geräte") until a
    // category was enabled, because the cache only fills via sync engine events. The
    // inventory fetch above carries no payloads (desiredKeys = []), so fetch the handful
    // of ICDevice records separately and feed the cache — the list is then correct as
    // soon as the sync page opens, even before anything is enabled.
    func fetchDeviceRecordsForInventory(_ recordIDs: [CKRecord.ID]) {
        guard !recordIDs.isEmpty else { return }
        let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
        operation.qualityOfService = .utility
        operation.fetchRecordsResultBlock = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.postDevicesChanged()
            }
        }
        operation.perRecordResultBlock = { [weak self] _, result in
            guard case .success(let record) = result else { return }
            Task { @MainActor [weak self] in
                guard let self, let payload = self.payloadDictionary(from: record) else { return }
                self.updateDeviceCache(with: payload)
            }
        }
        database.add(operation)
    }

    func storeCloudInventory(_ countsByType: [String: Int], reason: String) {
        // The three rows count USER objects only. Helper records (scroll positions,
        // the sort-order singleton, device entries) must not leak into them — they
        // showed "Einstellungen: 1" although settings sync was never enabled.
        let fetchDate = Date()
        let stored: [String: Any] = [
            "episodeStates": countsByType[RecordKind.episodeState] ?? 0,
            "subscriptions": countsByType[RecordKind.subscription] ?? 0,
            "settings": countsByType[RecordKind.appSettings] ?? 0,
            "fetchDate": fetchDate,
        ]
        setSyncMetadata(stored, forKey: Self.cloudInventoryKey)
        logSyncEvent("Cloud-Inventar aktualisiert", metadata: [
            "reason": reason,
            "episodeStates": stored["episodeStates"] ?? 0,
            "subscriptions": stored["subscriptions"] ?? 0,
            "settings": stored["settings"] ?? 0,
            "fetchDate": fetchDate,
            "byType": countsByType.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","),
        ])
        postStateChanged()
    }

    func runPendingCloudInventoryRefreshIfNeeded() {
        guard let reason = pendingCloudInventoryRefreshReason else { return }
        pendingCloudInventoryRefreshReason = nil
        refreshCloudInventory(reason: reason)
    }

    func performManualSync() async throws {
        guard anySyncEnabled else {
            clearError()
            setStatus(NSLocalizedString("Keine Sync-Kategorie aktiviert.", comment: ""))
            return
        }

        cancelLowPrioritySyncTask()
        initializeSyncEngineIfNeeded()
        hasUnresolvedSyncFailures = false
        setStatus(NSLocalizedString("Synchronisiere…", comment: ""))
        postStateChanged()
        await initialQueueTask?.value
        queueDeviceRecordForPendingUserDataIfNeeded()
        postStateChanged()

        if let syncEngine {
            try await syncEngine.sendChanges()
            try await syncEngine.fetchChanges()
        }

        if !hasUnresolvedSyncFailures {
            markSyncCompletedIfFinished()
        } else {
            postStateChanged()
        }
    }

    var database: CKDatabase {
        container.privateCloudDatabase
    }

    var deviceID: String {
        if let stored = defaults.string(forKey: Self.deviceIDKey), !stored.isEmpty {
            return stored
        }
        let newID = UUID().uuidString
        setSyncMetadata(newID, forKey: Self.deviceIDKey)
        return newID
    }

    func initializeSyncEngineIfNeeded() {
        guard syncEngine == nil else { return }

        var configuration = CKSyncEngine.Configuration(database: database,
                                                       stateSerialization: loadStateSerialization(),
                                                       delegate: self)
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        syncEngine = engine
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = Self.syncMetadataValue(forKey: Self.engineStateKey) as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    func persistStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        if let data = try? JSONEncoder().encode(serialization) {
            setSyncMetadata(data, forKey: Self.engineStateKey)
        }
    }

    func logSyncEvent(_ message: String, metadata: [String: Any] = [:]) {
        var details = metadata
        details["episodesSyncEnabled"] = episodesSyncEnabled
        details["subscriptionsSyncEnabled"] = subscriptionsSyncEnabled
        details["settingsSyncEnabled"] = settingsSyncEnabled
        details["anySyncEnabled"] = anySyncEnabled
        details["actor"] = "MainActor"
        details["syncEngineInitialized"] = syncEngine != nil
        details["initialQueueTaskActive"] = initialQueueTask != nil
        details["lowPrioritySyncTaskActive"] = lowPrioritySyncTask != nil
        details["isMainThread"] = Thread.isMainThread
        details["threadID"] = pthread_mach_thread_np(pthread_self())
        ICDiagnosticLogger.shared.logEvent("icloud-sync", message: message, metadata: details as NSDictionary)
    }

    func scheduleCurrentEnabledDataForUpload() {
        cancelInitialQueueTask()
        let snapshot = initialUploadSnapshot()
        logSyncEvent("Initiale iCloud-Queue geplant", metadata: [
            "snapshotEpisodesSyncEnabled": snapshot.episodesSyncEnabled,
            "snapshotSubscriptionsSyncEnabled": snapshot.subscriptionsSyncEnabled,
            "snapshotSettingsSyncEnabled": snapshot.settingsSyncEnabled,
        ])
        initialQueueTask = Task.detached(priority: .utility) { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.logSyncEvent("Initiale iCloud-Queue gestartet")
            }
            let plan = await Self.buildInitialUploadPlan(from: snapshot)
            guard !Task.isCancelled else { return }
            await self.applyInitialUploadPlan(plan)
        }
    }

    func cancelInitialQueueTask() {
        if initialQueueTask != nil {
            logSyncEvent("Initiale iCloud-Queue abgebrochen")
        }
        initialQueueTask?.cancel()
        initialQueueTask = nil
    }

    func scheduleLowPrioritySync() {
        guard anySyncEnabled, lowPrioritySyncTask == nil else { return }
        // No "scheduled" diagnostics line — it fired 171× in one capture and only brackets the
        // "started"/"completed" events that already mark real sync activity.
        // CKSyncEngine asserts when sendChanges recurses from one of its delegate tasks.
        // Detached scheduling drops that callback task context before the manager syncs.
        lowPrioritySyncTask = Task.detached(priority: .background) { [weak self] in
            await Task.yield()
            guard let self else { return }
            await self.performLowPrioritySync()
        }
    }

    func performLowPrioritySync() async {
        guard anySyncEnabled, !Task.isCancelled else {
            lowPrioritySyncTask = nil
            return
        }

        initializeSyncEngineIfNeeded()
        hasUnresolvedSyncFailures = false
        logSyncEvent("iCloud Sync mit niedriger Priorität gestartet", metadata: syncDiagnosticsMetadata())
        postStateChanged()

        do {
            if let syncEngine = syncEngine {
                try await syncEngine.sendChanges()
                // While the initial backfill still has pages to upload, only send — defer the
                // fetch until everything is up. The last page clears the cursor before it
                // syncs, so that run still fetches. This stops the status flipping up/down
                // every page and saves a network round-trip per page.
                if !hasInitialUploadBackfillWork {
                    try await syncEngine.fetchChanges()
                }
            }
            lowPrioritySyncTask = nil
            if !hasUnresolvedSyncFailures {
                markSyncCompletedIfFinished()
            } else {
                postStateChanged()
            }
            if anySyncEnabled, hasPendingSyncChanges {
                scheduleLowPrioritySync()
            }
        } catch {
            lowPrioritySyncTask = nil
            setError(error)
            scheduleSyncRetryAfterFailure(error: error, reason: "lowPrioritySync")
        }
    }

    func cancelLowPrioritySyncTask() {
        if lowPrioritySyncTask != nil {
            logSyncEvent("iCloud Sync mit niedriger Priorität abgebrochen")
        }
        lowPrioritySyncTask?.cancel()
        lowPrioritySyncTask = nil
    }

    // CKSyncEngine runs with automaticallySync = false and never retries on its own.
    // Without this, a failed first sync (flaky network or zone setup right after
    // enabling a category) left "could not complete" standing indefinitely — nothing
    // ran again until the user tapped manual sync. Transient failures are retried
    // with exponential backoff (or the server-provided retry-after) while the app
    // is running; the backoff resets on the next completed sync.
    func scheduleSyncRetryAfterFailure(error: Error, reason: String) {
        let ckError = error as? CKError
        scheduleSyncRetryAfterFailure(code: ckError?.code,
                                      retryAfter: ckError?.retryAfterSeconds,
                                      reason: reason,
                                      error: ckError)
    }

    func scheduleSyncRetryAfterFailure(code: CKError.Code?, retryAfter: TimeInterval? = nil, reason: String, error: CKError? = nil) {
        guard isStarted, anySyncEnabled else { return }
        if let error, !Self.isTransientCloudKitError(error) {
            return
        }
        if error == nil, let code, !Self.isTransientCloudKitErrorCode(code) {
            return
        }
        guard syncRetryWorkItem == nil else { return }
        syncRetryAttempt += 1
        let backoff = min(300.0, 15.0 * pow(2.0, Double(syncRetryAttempt - 1)))
        let delay = retryAfter ?? backoff
        logSyncEvent("Sync-Wiederholung geplant", metadata: [
            "delaySeconds": Int(delay),
            "attempt": syncRetryAttempt,
            "reason": reason,
            "errorCode": code?.rawValue ?? -1,
        ])
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncRetryWorkItem = nil
                guard self.isStarted, self.anySyncEnabled else { return }
                self.scheduleLowPrioritySync()
            }
        }
        syncRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func resetSyncRetryBackoff() {
        syncRetryAttempt = 0
        syncRetryWorkItem?.cancel()
        syncRetryWorkItem = nil
    }

    nonisolated static func isTransientCloudKitError(_ error: CKError) -> Bool {
        if error.code == .partialFailure, let partialErrors = error.partialErrorsByItemID, !partialErrors.isEmpty {
            return partialErrors.values.contains { partialError in
                guard let partialCKError = partialError as? CKError else { return true }
                return isTransientCloudKitError(partialCKError)
            }
        }
        return isTransientCloudKitErrorCode(error.code)
    }

    // Retrying cannot fix a missing account, parental restrictions, a full quota, invalid
    // request/schema arguments or a record format from a newer app version.
    nonisolated static func isTransientCloudKitErrorCode(_ code: CKError.Code) -> Bool {
        switch code {
        case .notAuthenticated, .permissionFailure, .managedAccountRestricted, .quotaExceeded, .invalidArguments, .incompatibleVersion:
            return false
        default:
            return true
        }
    }

    struct InitialUploadSnapshot {
        let episodesSyncEnabled: Bool
        let subscriptionsSyncEnabled: Bool
        let settingsSyncEnabled: Bool
        let episodeBackfillOffset: Int?
        let subscriptionBackfillOffset: Int?
        let settingsBackfillPending: Bool
    }

    struct InitialUploadPlan {
        let snapshot: InitialUploadSnapshot
        let createdAt: Date
        let episodeObjectHashes: [String]
        let nextEpisodeBackfillOffset: Int?
        let subscribedFeedURLs: [String]
        let nextSubscriptionBackfillOffset: Int?
        let subscriptionRecordURLs: [String: String]
        let subscriptionLocalModifiedDates: [String: TimeInterval]
        let subscriptionPayloadHashes: [String: String]
    }

    struct InitialUploadBatch {
        var episodeRecordNames: Set<String>
        var subscriptionRecordNames: Set<String>
        let nextEpisodeBackfillOffset: Int?
        let nextSubscriptionBackfillOffset: Int?
        let hasEpisodeBackfill: Bool
        let hasSubscriptionBackfill: Bool
    }

    struct InitialUploadPage {
        let values: [String]
        let nextOffset: Int?
    }

    struct InitialSubscriptionPage {
        let values: [String]
        let payloadHashes: [String: String]
        let nextOffset: Int?
    }

    func initialUploadSnapshot() -> InitialUploadSnapshot {
        let episodeOffset = episodesSyncEnabled ? (defaults.object(forKey: Self.initialEpisodeBackfillOffsetKey) as? NSNumber)?.intValue : nil
        let subscriptionOffset = subscriptionsSyncEnabled ? (defaults.object(forKey: Self.initialSubscriptionBackfillOffsetKey) as? NSNumber)?.intValue : nil
        let settingsPending = settingsSyncEnabled && defaults.bool(forKey: Self.initialSettingsBackfillPendingKey)
        return InitialUploadSnapshot(episodesSyncEnabled: episodesSyncEnabled,
                                     subscriptionsSyncEnabled: subscriptionsSyncEnabled,
                                     settingsSyncEnabled: settingsSyncEnabled,
                                     episodeBackfillOffset: episodeOffset,
                                     subscriptionBackfillOffset: subscriptionOffset,
                                     settingsBackfillPending: settingsPending)
    }

    nonisolated static func buildInitialUploadPlan(from snapshot: InitialUploadSnapshot) async -> InitialUploadPlan {
        let createdAt = Date()
        Self.logSyncEvent("Initialer iCloud Upload-Plan gestartet", metadata: [
            "snapshotEpisodesSyncEnabled": snapshot.episodesSyncEnabled,
            "snapshotSubscriptionsSyncEnabled": snapshot.subscriptionsSyncEnabled,
            "snapshotSettingsSyncEnabled": snapshot.settingsSyncEnabled,
            "episodeBackfillOffset": snapshot.episodeBackfillOffset ?? -1,
            "subscriptionBackfillOffset": snapshot.subscriptionBackfillOffset ?? -1,
            "settingsBackfillPending": snapshot.settingsBackfillPending,
        ])
        async let episodePage = episodeObjectHashesForInitialUploadPlan(offset: snapshot.episodeBackfillOffset)
        async let subscriptionPage = subscribedFeedURLsForInitialUploadPlan(offset: snapshot.subscriptionBackfillOffset)

        let episodes = await episodePage
        let subscriptions = await subscriptionPage
        let objectHashes = episodes.values
        let feedURLs = subscriptions.values
        var recordURLs = Self.syncMetadataValue(forKey: Self.subscriptionRecordURLsKey) as? [String: String] ?? [:]
        var modifiedDates = Self.syncMetadataValue(forKey: Self.subscriptionLocalModifiedDatesKey) as? [String: TimeInterval] ?? [:]
        if snapshot.subscriptionBackfillOffset != nil {
            for feedURL in feedURLs {
                recordURLs[subscriptionRecordName(forFeedURL: feedURL)] = feedURL
                modifiedDates[feedURL] = createdAt.timeIntervalSince1970
            }
        }

        Self.logSyncEvent("Initialer iCloud Upload-Plan fertig", metadata: [
            "episodeObjectHashCount": objectHashes.count,
            "subscribedFeedURLCount": feedURLs.count,
            "subscriptionRecordURLCount": recordURLs.count,
            "nextEpisodeBackfillOffset": episodes.nextOffset ?? -1,
            "nextSubscriptionBackfillOffset": subscriptions.nextOffset ?? -1,
        ])
        return InitialUploadPlan(snapshot: snapshot,
                                 createdAt: createdAt,
                                 episodeObjectHashes: objectHashes,
                                 nextEpisodeBackfillOffset: episodes.nextOffset,
                                 subscribedFeedURLs: feedURLs,
                                 nextSubscriptionBackfillOffset: subscriptions.nextOffset,
                                 subscriptionRecordURLs: recordURLs,
                                 subscriptionLocalModifiedDates: modifiedDates,
                                 subscriptionPayloadHashes: subscriptions.payloadHashes)
    }

    nonisolated static func episodeObjectHashesForInitialUploadPlan(offset: Int?) async -> InitialUploadPage {
        guard let offset else { return InitialUploadPage(values: [], nextOffset: nil) }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else { return InitialUploadPage(values: [], nextOffset: nil) }
        return await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Episode")
            request.resultType = .dictionaryResultType
            request.includesSubentities = false
            request.fetchLimit = Self.pendingChangeQueueChunkSize + 1
            request.fetchOffset = offset
            request.propertiesToFetch = ["objectHash"]
            request.predicate = NSPredicate(format: "feed.subscribed == YES AND archived == NO AND objectHash != nil AND (consumed == YES OR starred == YES OR position > 0)")
            let rows = (try? context.fetch(request)) ?? []
            let objectHashes = rows.prefix(Self.pendingChangeQueueChunkSize).compactMap { $0["objectHash"] as? String }
            let nextOffset = rows.count > Self.pendingChangeQueueChunkSize ? offset + objectHashes.count : nil
            Self.logSyncEvent("Initialer iCloud Episode-Plan Fetch-Seite", metadata: [
                "offset": offset,
                "rowCount": rows.count,
                "objectHashCount": objectHashes.count,
                "nextOffset": nextOffset ?? -1,
            ])
            return InitialUploadPage(values: objectHashes, nextOffset: nextOffset)
        }
    }

    nonisolated static func subscribedFeedURLsForInitialUploadPlan(offset: Int?) async -> InitialSubscriptionPage {
        guard let offset else { return InitialSubscriptionPage(values: [], payloadHashes: [:], nextOffset: nil) }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else { return InitialSubscriptionPage(values: [], payloadHashes: [:], nextOffset: nil) }
        return await context.perform {
            let request = NSFetchRequest<CDFeed>(entityName: "Feed")
            request.includesSubentities = false
            request.fetchLimit = Self.pendingChangeQueueChunkSize + 1
            request.fetchOffset = offset
            request.relationshipKeyPathsForPrefetching = ["properties"]
            request.predicate = NSPredicate(format: "subscribed == YES AND sourceURL_ != nil")
            let rows = (try? context.fetch(request)) ?? []
            var feedURLs: [String] = []
            var payloadHashes: [String: String] = [:]
            for feed in rows.prefix(Self.pendingChangeQueueChunkSize) {
                guard let feedURL = feed.value(forKey: "sourceURL_") as? String else { continue }
                feedURLs.append(feedURL)
                // Record the payload hash at queue time so the change-gate matches right away.
                // Without it the first refresh after enabling subscription sync saw every feed
                // as "changed" and re-uploaded the whole list once more.
                payloadHashes[feedURL] = subscriptionPayloadHash(for: feed)
            }
            let nextOffset = rows.count > Self.pendingChangeQueueChunkSize ? offset + feedURLs.count : nil
            Self.logSyncEvent("Initialer iCloud Abo-Plan Fetch-Seite", metadata: [
                "offset": offset,
                "rowCount": rows.count,
                "feedURLCount": feedURLs.count,
                "nextOffset": nextOffset ?? -1,
            ])
            return InitialSubscriptionPage(values: feedURLs, payloadHashes: payloadHashes, nextOffset: nextOffset)
        }
    }

    nonisolated static func logSyncEvent(_ message: String, metadata: [String: Any] = [:]) {
        let defaults = UserDefaults.standard
        let episodesEnabled = defaults.bool(forKey: ICiCloudSyncEpisodesEnabled)
        let subscriptionsEnabled = defaults.bool(forKey: ICiCloudSyncSubscriptionsEnabled)
        let settingsEnabled = defaults.bool(forKey: ICiCloudSyncSettingsEnabled)
        var details = metadata
        details["episodesSyncEnabled"] = episodesEnabled
        details["subscriptionsSyncEnabled"] = subscriptionsEnabled
        details["settingsSyncEnabled"] = settingsEnabled
        details["anySyncEnabled"] = episodesEnabled || subscriptionsEnabled || settingsEnabled
        details["actor"] = "nonisolated"
        details["isMainThread"] = Thread.isMainThread
        details["threadID"] = pthread_mach_thread_np(pthread_self())
        ICDiagnosticLogger.shared.logEvent("icloud-sync", message: message, metadata: details as NSDictionary)
    }

    nonisolated static func subscriptionRecordName(forFeedURL feedURL: String) -> String {
        RecordPrefix.subscription + sha256Hex(feedURL)
    }

    func applyInitialUploadPlan(_ plan: InitialUploadPlan) async {
        guard anySyncEnabled, !Task.isCancelled else { return }
        logSyncEvent("iCloud Upload-Queue baut Daten auf", metadata: [
            "episodeObjectHashCount": plan.episodeObjectHashes.count,
            "subscribedFeedURLCount": plan.subscribedFeedURLs.count,
            "snapshotEpisodesSyncEnabled": plan.snapshot.episodesSyncEnabled,
            "snapshotSubscriptionsSyncEnabled": plan.snapshot.subscriptionsSyncEnabled,
            "snapshotSettingsSyncEnabled": plan.snapshot.settingsSyncEnabled,
        ])
        let hasInitialWork = plan.snapshot.episodeBackfillOffset != nil
        || plan.snapshot.subscriptionBackfillOffset != nil
        guard hasInitialWork else {
            // Still publish the device record: turning a category OFF queues no backfill
            // work, but the other devices' lists must see the new option flags. This runs
            // inside the asynchronous plan task, not in the switch tap.
            queueDeviceRecord()
            logSyncEvent("Initiale iCloud-Queue ohne Arbeit beendet")
            return
        }
        initializeSyncEngineIfNeeded()
        var pendingKeys = pendingRecordZoneChangeKeys()
        addPendingSaves([deviceRecordID(for: deviceID)], pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
        var queuedUserData = false

        if plan.snapshot.episodeBackfillOffset != nil, episodesSyncEnabled {
            queuedUserData = await applyInitialEpisodeQueue(plan.episodeObjectHashes, pendingKeys: &pendingKeys) || queuedUserData
            guard !Task.isCancelled else { return }
            if plan.snapshot.episodeBackfillOffset == 0 {
                addPendingSaves([listScrollPositionsRecordID()], pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
                queuedUserData = true
            }
            await Task.yield()
        }

        if plan.snapshot.subscriptionBackfillOffset != nil, subscriptionsSyncEnabled {
            setSyncMetadata(plan.subscriptionRecordURLs, forKey: Self.subscriptionRecordURLsKey)
            setSyncMetadata(plan.subscriptionLocalModifiedDates, forKey: Self.subscriptionLocalModifiedDatesKey)
            mergeSubscriptionPayloadHashes(plan.subscriptionPayloadHashes)
            if plan.snapshot.subscriptionBackfillOffset == 0, Self.hasLocalSubscriptionListSettingsForInitialBackfill() {
                // The list sort mode, saved manual order, episode-list filters and sidebar
                // visibility travel with the subscriptions. Still do not publish a
                // sort-mode-only state during initial backfill: it can race the real manual
                // order under last-writer-wins. Local list/menu customizations are real
                // durable user data and must seed the singleton on first upload.
                setSyncMetadata(plan.createdAt, forKey: Self.subscriptionListSettingsLocalModifiedDateKey)
                setSyncMetadata(Self.subscriptionListSettingsFingerprint(), forKey: Self.subscriptionListSettingsBaselineKey)
                addPendingSaves([subscriptionListSettingsRecordID()], pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
                queuedUserData = true
            }
            queuedUserData = await applyInitialSubscriptionQueue(plan.subscribedFeedURLs, pendingKeys: &pendingKeys) || queuedUserData
            guard !Task.isCancelled else { return }
            await Task.yield()
        }

        // Settings deliberately NOT queued here. The old eager publish stamped a fresh
        // localModifiedDate before the first fetch — the enabling device then won
        // last-writer-wins against the REAL cloud settings and silently discarded them
        // (the "iPad never received the iPhone settings" bug). The initial settings
        // publish now happens in didFetchChanges, only if no remote settings arrived.

        if queuedUserData {
            queueDeviceRecord(stampLastSyncDate: true)
        }
        if !Task.isCancelled {
            recordInitialUploadBatchQueued(plan)
            logSyncEvent("Initiale iCloud-Queue abgeschlossen", metadata: [
                "queuedUserData": queuedUserData,
                "knownPendingKeyCount": pendingKeys.count,
                "nextEpisodeBackfillOffset": plan.nextEpisodeBackfillOffset ?? -1,
                "nextSubscriptionBackfillOffset": plan.nextSubscriptionBackfillOffset ?? -1,
            ])
            logSyncEvent("iCloud Upload-Queue fertig")
            if queuedUserData {
                scheduleLowPrioritySync()
            } else if hasInitialUploadBackfillWork {
                scheduleCurrentEnabledDataForUpload()
            } else {
                // Nothing to upload (e.g. a fresh device with no local data enabling a
                // category) — sync anyway: the FETCH is what brings the other devices'
                // data in. Without this a fresh device sat on "Bereit" with nothing
                // until the user tapped manual sync.
                scheduleLowPrioritySync()
            }
            postStateChanged()
        }
    }

    // The settings marker is NOT upload-backfill work anymore: the initial settings
    // publish is fetch-gated (didFetchChanges) so an enabling device first adopts an
    // existing cloud state instead of displacing it under last-writer-wins.
    var hasInitialUploadBackfillWork: Bool {
        (episodesSyncEnabled && defaults.object(forKey: Self.initialEpisodeBackfillOffsetKey) != nil)
        || (subscriptionsSyncEnabled && defaults.object(forKey: Self.initialSubscriptionBackfillOffsetKey) != nil)
    }

    func recordInitialUploadBatchQueued(_ plan: InitialUploadPlan) {
        let hasEpisodeBackfill = plan.snapshot.episodeBackfillOffset != nil && episodesSyncEnabled
        let hasSubscriptionBackfill = plan.snapshot.subscriptionBackfillOffset != nil && subscriptionsSyncEnabled
        let episodeRecordNames = hasEpisodeBackfill
            ? Set(plan.episodeObjectHashes.map { RecordPrefix.episode + $0 })
            : []
        let subscriptionRecordNames = hasSubscriptionBackfill
            ? Set(plan.subscribedFeedURLs.map { Self.subscriptionRecordName(forFeedURL: $0) })
            : []

        if hasEpisodeBackfill, episodeRecordNames.isEmpty {
            updateInitialEpisodeBackfillCursor(nextOffset: plan.nextEpisodeBackfillOffset)
        }
        if hasSubscriptionBackfill, subscriptionRecordNames.isEmpty {
            updateInitialSubscriptionBackfillCursor(nextOffset: plan.nextSubscriptionBackfillOffset)
        }

        guard !episodeRecordNames.isEmpty || !subscriptionRecordNames.isEmpty else {
            pendingInitialUploadBatch = nil
            return
        }

        pendingInitialUploadBatch = InitialUploadBatch(episodeRecordNames: episodeRecordNames,
                                                       subscriptionRecordNames: subscriptionRecordNames,
                                                       nextEpisodeBackfillOffset: plan.nextEpisodeBackfillOffset,
                                                       nextSubscriptionBackfillOffset: plan.nextSubscriptionBackfillOffset,
                                                       hasEpisodeBackfill: hasEpisodeBackfill,
                                                       hasSubscriptionBackfill: hasSubscriptionBackfill)
        logSyncEvent("Initiale iCloud-Queue wartet auf CloudKit-Bestätigung", metadata: [
            "episodeRecordCount": episodeRecordNames.count,
            "subscriptionRecordCount": subscriptionRecordNames.count,
            "nextEpisodeBackfillOffset": plan.nextEpisodeBackfillOffset ?? -1,
            "nextSubscriptionBackfillOffset": plan.nextSubscriptionBackfillOffset ?? -1,
        ])
    }

    func recordInitialUploadRecordsSaved(_ recordIDs: [CKRecord.ID]) {
        guard var batch = pendingInitialUploadBatch else { return }
        let savedNames = Set(recordIDs.map { $0.recordName })
        batch.episodeRecordNames.subtract(savedNames)
        batch.subscriptionRecordNames.subtract(savedNames)
        pendingInitialUploadBatch = batch

        guard batch.episodeRecordNames.isEmpty, batch.subscriptionRecordNames.isEmpty else { return }
        if batch.hasEpisodeBackfill {
            updateInitialEpisodeBackfillCursor(nextOffset: batch.nextEpisodeBackfillOffset)
        }
        if batch.hasSubscriptionBackfill {
            updateInitialSubscriptionBackfillCursor(nextOffset: batch.nextSubscriptionBackfillOffset)
        }
        pendingInitialUploadBatch = nil
        logSyncEvent("Initiale iCloud-Queue von CloudKit bestätigt", metadata: [
            "nextEpisodeBackfillOffset": batch.nextEpisodeBackfillOffset ?? -1,
            "nextSubscriptionBackfillOffset": batch.nextSubscriptionBackfillOffset ?? -1,
        ])
    }

    func updateInitialEpisodeBackfillCursor(nextOffset: Int?) {
        if let nextOffset {
            defaults.set(nextOffset, forKey: Self.initialEpisodeBackfillOffsetKey)
        } else {
            clearInitialEpisodeBackfillCursor()
        }
    }

    func updateInitialSubscriptionBackfillCursor(nextOffset: Int?) {
        if let nextOffset {
            defaults.set(nextOffset, forKey: Self.initialSubscriptionBackfillOffsetKey)
        } else {
            clearInitialSubscriptionBackfillCursor()
        }
    }

    func resetInitialEpisodeBackfillCursor() {
        defaults.set(0, forKey: Self.initialEpisodeBackfillOffsetKey)
    }

    func clearInitialEpisodeBackfillCursor() {
        defaults.removeObject(forKey: Self.initialEpisodeBackfillOffsetKey)
    }

    func resetInitialSubscriptionBackfillCursor() {
        defaults.set(0, forKey: Self.initialSubscriptionBackfillOffsetKey)
    }

    func clearInitialSubscriptionBackfillCursor() {
        defaults.removeObject(forKey: Self.initialSubscriptionBackfillOffsetKey)
    }

    func clearInitialUploadCursors() {
        clearInitialEpisodeBackfillCursor()
        clearInitialSubscriptionBackfillCursor()
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
    }

    func resetInitialBackfillCursorsForEnabledOptions() {
        if episodesSyncEnabled {
            resetInitialEpisodeBackfillCursor()
        }
        if subscriptionsSyncEnabled {
            resetInitialSubscriptionBackfillCursor()
        }
    }

    func applyInitialEpisodeQueue(_ objectHashes: [String], pendingKeys: inout Set<String>) async -> Bool {
        var queuedRecords = false
        var index = objectHashes.startIndex
        var chunkIndex = 0
        while index < objectHashes.endIndex {
            let end = objectHashes.index(index, offsetBy: Self.pendingChangeQueueChunkSize, limitedBy: objectHashes.endIndex) ?? objectHashes.endIndex
            guard episodesSyncEnabled, !Task.isCancelled else { return queuedRecords }
            let chunk = objectHashes[index..<end]
            addPendingSaves(chunk.map { episodeRecordID(forObjectHash: $0) }, pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
            queuedRecords = true
            logSyncEvent("Initiale iCloud Episode-Queue Chunk angewendet", metadata: [
                "chunkIndex": chunkIndex,
                "chunkRecordCount": chunk.count,
                "knownPendingKeyCount": pendingKeys.count,
            ])
            index = end
            chunkIndex += 1
            await Task.yield()
        }
        return queuedRecords
    }

    func applyInitialSubscriptionQueue(_ feedURLs: [String], pendingKeys: inout Set<String>) async -> Bool {
        var queuedRecords = false
        var index = feedURLs.startIndex
        var chunkIndex = 0
        while index < feedURLs.endIndex {
            let end = feedURLs.index(index, offsetBy: Self.pendingChangeQueueChunkSize, limitedBy: feedURLs.endIndex) ?? feedURLs.endIndex
            guard subscriptionsSyncEnabled, !Task.isCancelled else { return queuedRecords }
            let chunk = feedURLs[index..<end]
            addPendingSaves(chunk.map { subscriptionRecordID(forFeedURL: $0) }, pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
            queuedRecords = true
            logSyncEvent("Initiale iCloud Abo-Queue Chunk angewendet", metadata: [
                "chunkIndex": chunkIndex,
                "chunkRecordCount": chunk.count,
                "knownPendingKeyCount": pendingKeys.count,
            ])
            index = end
            chunkIndex += 1
            await Task.yield()
        }
        return queuedRecords
    }

    func queueDeviceRecord(stampLastSyncDate: Bool = false) {
        if stampLastSyncDate {
            deviceRecordShouldStampSyncDate = true
            setSyncMetadata(true, forKey: Self.deviceRecordShouldStampSyncDateKey)
        }
        addPendingSave(deviceRecordID(for: deviceID))
    }

    func addPendingSave(_ recordID: CKRecord.ID) {
        addPendingSaves([recordID])
    }

    func addPendingSaves(_ recordIDs: [CKRecord.ID]) {
        var pendingKeys = pendingRecordZoneChangeKeys()
        addPendingSaves(recordIDs, pendingKeys: &pendingKeys, stampDeviceRecordForUserData: true, scheduleSync: true)
    }

    func addPendingSaves(_ recordIDs: [CKRecord.ID], pendingKeys: inout Set<String>, stampDeviceRecordForUserData: Bool, scheduleSync: Bool = false) {
        guard !recordIDs.isEmpty else { return }
        let containsUserData = containsUserDataRecordID(recordIDs)
        initializeSyncEngineIfNeeded()
        let changes = recordIDs.compactMap { recordID -> CKSyncEngine.PendingRecordZoneChange? in
            let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID)
            let key = pendingChangeKey(change)
            guard !pendingKeys.contains(key) else { return nil }
            pendingKeys.insert(key)
            return change
        }
        if !changes.isEmpty {
            syncEngine?.state.add(pendingRecordZoneChanges: changes)
        }
        if containsUserData, stampDeviceRecordForUserData {
            queueDeviceRecord(stampLastSyncDate: true)
        }
        if scheduleSync {
            scheduleLowPrioritySync()
        }
    }

    func pendingRecordZoneChangeKeys() -> Set<String> {
        Set(syncEngine?.state.pendingRecordZoneChanges.map { pendingChangeKey($0) } ?? [])
    }

    func pendingChangeKey(_ change: CKSyncEngine.PendingRecordZoneChange) -> String {
        switch change {
        case .saveRecord(let recordID):
            return "save:\(recordID.recordName)"
        case .deleteRecord(let recordID):
            return "delete:\(recordID.recordName)"
        @unknown default:
            return "unknown"
        }
    }

    func containsUserDataRecordID(_ recordIDs: [CKRecord.ID]) -> Bool {
        recordIDs.contains { isUserDataRecordID($0) }
    }

    func isUserDataRecordID(_ recordID: CKRecord.ID) -> Bool {
        Self.isUserDataRecordName(recordID.recordName)
    }

    nonisolated static func isUserDataRecordName(_ recordName: String) -> Bool {
        recordName.hasPrefix(RecordPrefix.episode)
        || recordName.hasPrefix(RecordPrefix.subscription)
        || recordName == RecordPrefix.appSettings
        || recordName == RecordPrefix.listScrollPositions
        || recordName == RecordPrefix.subscriptionListSettings
    }

    func hasPendingUserDataChanges() -> Bool {
        guard let syncEngine else { return false }
        return syncEngine.state.pendingRecordZoneChanges.contains { change in
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID):
                return isUserDataRecordID(recordID)
            @unknown default:
                return false
            }
        }
    }

    func queueDeviceRecordForPendingUserDataIfNeeded() {
        guard hasPendingUserDataChanges() else { return }
        queueDeviceRecord(stampLastSyncDate: true)
    }
}
