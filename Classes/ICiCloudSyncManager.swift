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

@objcMembers final class ICiCloudSyncDeviceInfo: NSObject {
    let deviceID: String
    let name: String
    let model: String
    let systemVersion: String
    let appVersion: String
    let lastSyncDate: Date?
    let episodesEnabled: Bool
    let subscriptionsEnabled: Bool
    let settingsEnabled: Bool
    let isCurrentDevice: Bool

    init(deviceID: String,
         name: String,
         model: String,
         systemVersion: String,
         appVersion: String,
         lastSyncDate: Date?,
         episodesEnabled: Bool,
         subscriptionsEnabled: Bool,
         settingsEnabled: Bool,
         isCurrentDevice: Bool) {
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.lastSyncDate = lastSyncDate
        self.episodesEnabled = episodesEnabled
        self.subscriptionsEnabled = subscriptionsEnabled
        self.settingsEnabled = settingsEnabled
        self.isCurrentDevice = isCurrentDevice
        super.init()
    }
}

@objcMembers final class ICiCloudSyncCounts: NSObject {
    // "synced" = how many of "total" are already on iCloud; "total" = how many will be synced
    // from this device (e.g. episodes with play state). Shown as "synced / total".
    let episodesSynced: Int
    let episodesTotal: Int
    let subscriptionsSynced: Int
    let subscriptionsTotal: Int
    let settings: Int
    // false while the background count hasn't produced a value yet — the UI shows a
    // placeholder then instead of a misleading "0 / 0".
    let countsAvailable: Bool

    init(episodesSynced: Int,
         episodesTotal: Int,
         subscriptionsSynced: Int,
         subscriptionsTotal: Int,
         settings: Int,
         countsAvailable: Bool) {
        self.episodesSynced = episodesSynced
        self.episodesTotal = episodesTotal
        self.subscriptionsSynced = subscriptionsSynced
        self.subscriptionsTotal = subscriptionsTotal
        self.settings = settings
        self.countsAvailable = countsAvailable
        super.init()
    }
}

// Hard record counts straight from the CloudKit zone — what is actually ON iCloud,
// independent of local state, switches or sync progress.
@objcMembers final class ICiCloudSyncCloudInventory: NSObject {
    let episodeStates: Int
    let subscriptions: Int
    let settings: Int
    let fetchDate: Date

    init(episodeStates: Int, subscriptions: Int, settings: Int, fetchDate: Date) {
        self.episodeStates = episodeStates
        self.subscriptions = subscriptions
        self.settings = settings
        self.fetchDate = fetchDate
        super.init()
    }
}

// Record-type counters shared with the (serially executing) CloudKit operation callbacks.
// Collects the inventory from a change-stream fetch. Deduplicated by record name:
// a nil-token CKFetchRecordZoneChangesOperation streams CHANGES, so a record that is
// modified while the fetch runs can be delivered twice (the phantom "ICDevice=3,
// ICListScrollPositions=2" counts) — and deletions during the stream must subtract.
private final class ICCloudInventoryCountsBox: @unchecked Sendable {
    private var recordNamesByType: [String: Set<String>] = [:]
    private var deviceRecordIDs: [CKRecord.ID] = []
    private let lock = NSLock()

    func record(_ record: CKRecord) {
        lock.lock()
        recordNamesByType[record.recordType, default: []].insert(record.recordID.recordName)
        if record.recordType == "ICDevice", !deviceRecordIDs.contains(record.recordID) {
            deviceRecordIDs.append(record.recordID)
        }
        lock.unlock()
    }

    func remove(recordName: String) {
        lock.lock()
        for type in recordNamesByType.keys {
            recordNamesByType[type]?.remove(recordName)
        }
        deviceRecordIDs.removeAll { $0.recordName == recordName }
        lock.unlock()
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return recordNamesByType.mapValues { $0.count }
    }

    func deviceIDs() -> [CKRecord.ID] {
        lock.lock()
        defer { lock.unlock() }
        return deviceRecordIDs
    }
}

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

    private nonisolated static let containerIdentifier = "iCloud.com.iteconomy.instacastplus"
    private nonisolated static let zoneName = "InstacastSync"
    private nonisolated static let schemaVersion = 1

    private nonisolated static let deviceIDKey = "ICiCloudSyncDeviceID"
    private nonisolated static let engineStateKey = "ICiCloudSyncEngineState"
    private nonisolated static let knownRecordsKey = "ICiCloudSyncKnownRecords"
    private nonisolated static let deviceCacheKey = "ICiCloudSyncDeviceCache"
    private nonisolated static let subscriptionRecordURLsKey = "ICiCloudSyncSubscriptionRecordURLs"
    private nonisolated static let pendingEpisodeStatesKey = "ICiCloudSyncPendingEpisodeStates"
    private nonisolated static let pendingSubscriptionPayloadsKey = "ICiCloudSyncPendingSubscriptionPayloads"
    private nonisolated static let episodeLocalModifiedDatesKey = "ICiCloudSyncEpisodeLocalModifiedDates"
    private nonisolated static let subscriptionLocalModifiedDatesKey = "ICiCloudSyncSubscriptionLocalModifiedDates"
    private nonisolated static let subscriptionPayloadHashesKey = "ICiCloudSyncSubscriptionPayloadHashes"
    private nonisolated static let initialEpisodeBackfillOffsetKey = "ICiCloudSyncInitialEpisodeBackfillOffset"
    private nonisolated static let initialSubscriptionBackfillOffsetKey = "ICiCloudSyncInitialSubscriptionBackfillOffset"
    private nonisolated static let initialSettingsBackfillPendingKey = "ICiCloudSyncInitialSettingsBackfillPending"
    private nonisolated static let pendingInitialSettingsPayloadKey = "ICiCloudSyncPendingInitialSettingsPayload"
    @objc static let initialSettingsChoiceNeededNotification = "ICiCloudSyncInitialSettingsChoiceNeeded"
    private nonisolated static let settingsLocalModifiedDateKey = "ICiCloudSyncSettingsLocalModifiedDate"
    private nonisolated static let settingsSyncedHashKey = "ICiCloudSyncSettingsSyncedHash"
    private nonisolated static let suppressSubscriptionDeletionsKey = "ICiCloudSyncSuppressSubscriptionDeletions"
    private nonisolated static let cloudInventoryKey = "ICiCloudSyncCloudInventory"
    private nonisolated static let subscriptionListSettingsLocalModifiedDateKey = "ICiCloudSyncSubscriptionListSettingsLocalModifiedDate"
    private nonisolated static let subscriptionListSettingsBaselineKey = "ICiCloudSyncSubscriptionListSettingsBaseline"
    // Mirrors the file-private kManualFeedOrderKey in DatabaseManager.m.
    private nonisolated static let manualFeedOrderDefaultsKey = "ManualFeedOrder"
    private nonisolated static let scrollPositionsLocalModifiedDateKey = "ICiCloudSyncScrollPositionsLocalModifiedDate"
    private nonisolated static let lastSyncDateKey = "ICiCloudSyncLastSyncDate"
    private nonisolated static let lastStatusKey = "ICiCloudSyncLastStatus"
    private nonisolated static let lastErrorKey = "ICiCloudSyncLastError"
    private nonisolated static let deviceRecordShouldStampSyncDateKey = "ICiCloudSyncDeviceRecordShouldStampSyncDate"
    // CloudKit allows up to 400 record operations per batch. Keeping it well above the backfill
    // page size (200) means a page of episodes + the device record ship in ONE batch instead of
    // a 200-record batch plus a 2-record leftover round-trip.
    private nonisolated static let maximumRecordZoneChangesPerBatch = 400
    private nonisolated static let pendingChangeQueueChunkSize = 200
    private nonisolated static let syncMetadataDirectoryName = "iCloudSyncMetadata"
    private nonisolated static let knownRecordSystemFieldsDirectoryName = "KnownRecords"

    private nonisolated static var fileBackedSyncMetadataKeys: Set<String> {
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

    private enum RecordKind {
        static let device = "ICDevice"
        static let episodeState = "ICEpisodeState"
        static let subscription = "ICSubscription"
        static let appSettings = "ICAppSettings"
        static let listScrollPositions = "ICListScrollPositions"
        static let subscriptionListSettings = "ICSubscriptionListSettings"
    }

    private enum RecordPrefix {
        static let device = "device_"
        static let episode = "episode_"
        static let subscription = "subscription_"
        static let appSettings = "settings_app"
        static let listScrollPositions = "settings_listScrollPositions"
        static let subscriptionListSettings = "settings_subscriptionList"
    }

    private let defaults = UserDefaults.standard
    private let container = CKContainer(identifier: ICiCloudSyncManager.containerIdentifier)
    private let zoneID = CKRecordZone.ID(zoneName: ICiCloudSyncManager.zoneName)
    private var syncEngine: CKSyncEngine?
    private var isStarted = false
    private var isApplyingRemoteChange = false
    private var isWritingSyncMetadata = false
    private var hasUnresolvedSyncFailures = false
    private var settingsDebounceWorkItem: DispatchWorkItem?
    private var scrollDebounceWorkItem: DispatchWorkItem?
    private var applyPendingDebounceWorkItem: DispatchWorkItem?
    private var episodeLocalModifiedDatesCache: [String: TimeInterval]?
    private var episodeLocalModifiedDatesWriteWorkItem: DispatchWorkItem?
    private var subscriptionPayloadHashesCache: [String: String]?
    private var cachedSyncTotalCounts: (episodes: Int, subscriptions: Int, settings: Int, timestamp: Date)?
    private var isRefreshingSyncTotalCounts = false
    // Object IDs that were just mutated by applying remote records. The objects-did-change
    // notification for those mutations arrives in batches (at processPendingChanges time),
    // possibly only after the whole fetch-apply pass is over — a time-window flag like
    // `isApplyingRemoteChange` cannot tell remote applies from genuine local edits there,
    // which systematically echoed the last batch of every fetch back up (with a fresh
    // `updatedAt`, weakening last-writer-wins). Only IDs whose apply REALLY changed a value
    // are recorded, and each ID absolves exactly one observer pass, so a later genuine
    // local edit of the same object still syncs.
    private var remoteAppliedObjectIDs: Set<NSManagedObjectID> = []
    private var lastForegroundSyncDate: Date?
    private var didPruneEpisodeLocalModifiedDates = false
    // In-memory cache for the two pending-payload stores. A single fetch can store
    // thousands of payloads (episode states arriving while episode sync is off) —
    // re-reading and re-writing the whole plist per record was quadratic disk I/O on
    // the main thread and froze the device for the duration of the download.
    private var pendingPayloadsCache: [String: [String: [String: Any]]] = [:]
    private var dirtyPendingPayloadKeys: Set<String> = []
    private var pendingPayloadsWriteWorkItem: DispatchWorkItem?
    private var syncActivityExpectedCount = 0
    private var syncActivityKindLabel: String?
    private var isFetchingCloudInventory = false
    private var pendingCloudInventoryRefreshReason: String?
    private var isHydratingStubFeeds = false
    private var hydrationCompletedCount = 0
    private var hydrationTotalCount = 0
    private var hydrationFailedFeedIDs: Set<NSManagedObjectID> = []
    private var isWaitingForEpisodeLoader = false
    private var episodeLoaderWaitGeneration = 0
    private var needsSubscriptionListSortApply = false
    private var pendingInitialUploadBatch: InitialUploadBatch?
    private var initialQueueTask: Task<Void, Never>?
    private var lowPrioritySyncTask: Task<Void, Never>?
    private var syncRetryAttempt = 0
    private var syncRetryWorkItem: DispatchWorkItem?
    private enum SyncActivityDirection { case up, down }
    private var syncActivityDirection: SyncActivityDirection?
    private var syncActivityStartDate: Date?
    private var syncActivityRecordCount = 0
    private var deviceRecordShouldStampSyncDate = false
    private var syncedUserDataInCurrentRun = false

    private var databaseManager: DatabaseManager {
        DatabaseManager.shared()!
    }

    private var subscriptionManager: SubscriptionManager {
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
    private func syncedCount(backfillKey: String, total: Int) -> Int {
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
    private func syncTotalCounts() -> (episodes: Int, subscriptions: Int, settings: Int) {
        let cached = cachedSyncTotalCounts
        // 15 s TTL: the settings screen reloads on a 10 s timer plus every state change;
        // a 2 s TTL re-ran the COUNT queries (a full episode-table scan) almost every time.
        if cached == nil || Date().timeIntervalSince(cached!.timestamp) >= 15.0 {
            refreshSyncTotalCountsInBackground()
        }
        return (cached?.episodes ?? 0, cached?.subscriptions ?? 0, cached?.settings ?? 0)
    }

    private func refreshSyncTotalCountsInBackground() {
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

    private nonisolated static func computeSyncTotalCounts(episodesEnabled: Bool, subscriptionsEnabled: Bool, settingsEnabled: Bool) async -> (episodes: Int, subscriptions: Int, settings: Int) {
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

    private nonisolated static func syncedSettingsValueCount() -> Int {
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

    private override init() {
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

    private func sendFinalDeviceRecordUpdate() {
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

    private func resetAllLocalSyncMetadata() {
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

    private func refreshCloudInventory(reason: String) {
        guard !isFetchingCloudInventory else {
            pendingCloudInventoryRefreshReason = reason
            var metadata: [String: Any] = ["reason": reason]
            metadata.merge(syncDiagnosticsMetadata()) { current, _ in current }
            logSyncEvent("Cloud-Inventar-Abfrage übersprungen", metadata: metadata)
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
    private func fetchDeviceRecordsForInventory(_ recordIDs: [CKRecord.ID]) {
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

    private func storeCloudInventory(_ countsByType: [String: Int], reason: String) {
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

    private func runPendingCloudInventoryRefreshIfNeeded() {
        guard let reason = pendingCloudInventoryRefreshReason else { return }
        pendingCloudInventoryRefreshReason = nil
        refreshCloudInventory(reason: reason)
    }

    private func performManualSync() async throws {
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

    private var database: CKDatabase {
        container.privateCloudDatabase
    }

    private var deviceID: String {
        if let stored = defaults.string(forKey: Self.deviceIDKey), !stored.isEmpty {
            return stored
        }
        let newID = UUID().uuidString
        setSyncMetadata(newID, forKey: Self.deviceIDKey)
        return newID
    }

    private func initializeSyncEngineIfNeeded() {
        guard syncEngine == nil else { return }

        var configuration = CKSyncEngine.Configuration(database: database,
                                                       stateSerialization: loadStateSerialization(),
                                                       delegate: self)
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        syncEngine = engine
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = Self.syncMetadataValue(forKey: Self.engineStateKey) as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func persistStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        if let data = try? JSONEncoder().encode(serialization) {
            setSyncMetadata(data, forKey: Self.engineStateKey)
        }
    }

    private func logSyncEvent(_ message: String, metadata: [String: Any] = [:]) {
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

    private func scheduleCurrentEnabledDataForUpload() {
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

    private func cancelInitialQueueTask() {
        if initialQueueTask != nil {
            logSyncEvent("Initiale iCloud-Queue abgebrochen")
        }
        initialQueueTask?.cancel()
        initialQueueTask = nil
    }

    private func scheduleLowPrioritySync() {
        guard anySyncEnabled, lowPrioritySyncTask == nil else { return }
        logSyncEvent("iCloud Sync mit niedriger Priorität geplant")
        // CKSyncEngine asserts when sendChanges recurses from one of its delegate tasks.
        // Detached scheduling drops that callback task context before the manager syncs.
        lowPrioritySyncTask = Task.detached(priority: .background) { [weak self] in
            await Task.yield()
            guard let self else { return }
            await self.performLowPrioritySync()
        }
    }

    private func performLowPrioritySync() async {
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
            let ckError = error as? CKError
            scheduleSyncRetryAfterFailure(code: ckError?.code,
                                          retryAfter: ckError?.retryAfterSeconds,
                                          reason: "lowPrioritySync")
        }
    }

    private func cancelLowPrioritySyncTask() {
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
    private func scheduleSyncRetryAfterFailure(code: CKError.Code?, retryAfter: TimeInterval? = nil, reason: String) {
        guard isStarted, anySyncEnabled else { return }
        if let code, !Self.isTransientCloudKitErrorCode(code) {
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

    private func resetSyncRetryBackoff() {
        syncRetryAttempt = 0
        syncRetryWorkItem?.cancel()
        syncRetryWorkItem = nil
    }

    // Retrying cannot fix a missing account, parental restrictions, a full quota or a
    // record format from a newer app version — everything else is worth another attempt.
    private nonisolated static func isTransientCloudKitErrorCode(_ code: CKError.Code) -> Bool {
        switch code {
        case .notAuthenticated, .permissionFailure, .managedAccountRestricted, .quotaExceeded, .incompatibleVersion:
            return false
        default:
            return true
        }
    }

    private struct InitialUploadSnapshot {
        let episodesSyncEnabled: Bool
        let subscriptionsSyncEnabled: Bool
        let settingsSyncEnabled: Bool
        let episodeBackfillOffset: Int?
        let subscriptionBackfillOffset: Int?
        let settingsBackfillPending: Bool
    }

    private struct InitialUploadPlan {
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

    private struct InitialUploadBatch {
        var episodeRecordNames: Set<String>
        var subscriptionRecordNames: Set<String>
        let nextEpisodeBackfillOffset: Int?
        let nextSubscriptionBackfillOffset: Int?
        let hasEpisodeBackfill: Bool
        let hasSubscriptionBackfill: Bool
    }

    private struct InitialUploadPage {
        let values: [String]
        let nextOffset: Int?
    }

    private struct InitialSubscriptionPage {
        let values: [String]
        let payloadHashes: [String: String]
        let nextOffset: Int?
    }

    private func initialUploadSnapshot() -> InitialUploadSnapshot {
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

    private nonisolated static func buildInitialUploadPlan(from snapshot: InitialUploadSnapshot) async -> InitialUploadPlan {
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

    private nonisolated static func episodeObjectHashesForInitialUploadPlan(offset: Int?) async -> InitialUploadPage {
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

    private nonisolated static func subscribedFeedURLsForInitialUploadPlan(offset: Int?) async -> InitialSubscriptionPage {
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

    private nonisolated static func logSyncEvent(_ message: String, metadata: [String: Any] = [:]) {
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

    private nonisolated static func subscriptionRecordName(forFeedURL feedURL: String) -> String {
        RecordPrefix.subscription + sha256Hex(feedURL)
    }

    private func applyInitialUploadPlan(_ plan: InitialUploadPlan) async {
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
            if plan.snapshot.subscriptionBackfillOffset == 0, Self.hasLocalManualFeedOrder() {
                // The list sort mode + saved manual order travel with the subscriptions.
                // Only published when a manual order exists: a device enabling sync with
                // an empty or sort-mode-only state must never stamp a record with a fresh
                // updatedAt — under last-writer-wins that displaces (and effectively
                // erases) the real sort state of the other devices. A sort-mode-only
                // state publishes when the user actually changes it (checkAndQueue).
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
    private var hasInitialUploadBackfillWork: Bool {
        (episodesSyncEnabled && defaults.object(forKey: Self.initialEpisodeBackfillOffsetKey) != nil)
        || (subscriptionsSyncEnabled && defaults.object(forKey: Self.initialSubscriptionBackfillOffsetKey) != nil)
    }

    private func updateInitialUploadCursors(from plan: InitialUploadPlan) {
        if plan.snapshot.episodeBackfillOffset != nil, episodesSyncEnabled {
            if let nextOffset = plan.nextEpisodeBackfillOffset {
                defaults.set(nextOffset, forKey: Self.initialEpisodeBackfillOffsetKey)
            } else {
                clearInitialEpisodeBackfillCursor()
            }
        }

        if plan.snapshot.subscriptionBackfillOffset != nil, subscriptionsSyncEnabled {
            if let nextOffset = plan.nextSubscriptionBackfillOffset {
                defaults.set(nextOffset, forKey: Self.initialSubscriptionBackfillOffsetKey)
            } else {
                clearInitialSubscriptionBackfillCursor()
            }
        }
    }

    private func recordInitialUploadBatchQueued(_ plan: InitialUploadPlan) {
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

    private func recordInitialUploadRecordsSaved(_ recordIDs: [CKRecord.ID]) {
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

    private func updateInitialEpisodeBackfillCursor(nextOffset: Int?) {
        if let nextOffset {
            defaults.set(nextOffset, forKey: Self.initialEpisodeBackfillOffsetKey)
        } else {
            clearInitialEpisodeBackfillCursor()
        }
    }

    private func updateInitialSubscriptionBackfillCursor(nextOffset: Int?) {
        if let nextOffset {
            defaults.set(nextOffset, forKey: Self.initialSubscriptionBackfillOffsetKey)
        } else {
            clearInitialSubscriptionBackfillCursor()
        }
    }

    private func resetInitialEpisodeBackfillCursor() {
        defaults.set(0, forKey: Self.initialEpisodeBackfillOffsetKey)
    }

    private func clearInitialEpisodeBackfillCursor() {
        defaults.removeObject(forKey: Self.initialEpisodeBackfillOffsetKey)
    }

    private func resetInitialSubscriptionBackfillCursor() {
        defaults.set(0, forKey: Self.initialSubscriptionBackfillOffsetKey)
    }

    private func clearInitialSubscriptionBackfillCursor() {
        defaults.removeObject(forKey: Self.initialSubscriptionBackfillOffsetKey)
    }

    private func clearInitialUploadCursors() {
        clearInitialEpisodeBackfillCursor()
        clearInitialSubscriptionBackfillCursor()
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
    }

    private func resetInitialBackfillCursorsForEnabledOptions() {
        if episodesSyncEnabled {
            resetInitialEpisodeBackfillCursor()
        }
        if subscriptionsSyncEnabled {
            resetInitialSubscriptionBackfillCursor()
        }
    }

    private func applyInitialEpisodeQueue(_ objectHashes: [String], pendingKeys: inout Set<String>) async -> Bool {
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

    private func applyInitialSubscriptionQueue(_ feedURLs: [String], pendingKeys: inout Set<String>) async -> Bool {
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

    private func queueDeviceRecord(stampLastSyncDate: Bool = false) {
        if stampLastSyncDate {
            deviceRecordShouldStampSyncDate = true
            setSyncMetadata(true, forKey: Self.deviceRecordShouldStampSyncDateKey)
        }
        addPendingSave(deviceRecordID(for: deviceID))
    }

    private func addPendingSave(_ recordID: CKRecord.ID) {
        addPendingSaves([recordID])
    }

    private func addPendingSaves(_ recordIDs: [CKRecord.ID]) {
        var pendingKeys = pendingRecordZoneChangeKeys()
        addPendingSaves(recordIDs, pendingKeys: &pendingKeys, stampDeviceRecordForUserData: true, scheduleSync: true)
    }

    private func addPendingSaves(_ recordIDs: [CKRecord.ID], pendingKeys: inout Set<String>, stampDeviceRecordForUserData: Bool, scheduleSync: Bool = false) {
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

    private func pendingRecordZoneChangeKeys() -> Set<String> {
        Set(syncEngine?.state.pendingRecordZoneChanges.map { pendingChangeKey($0) } ?? [])
    }

    private func pendingChangeKey(_ change: CKSyncEngine.PendingRecordZoneChange) -> String {
        switch change {
        case .saveRecord(let recordID):
            return "save:\(recordID.recordName)"
        case .deleteRecord(let recordID):
            return "delete:\(recordID.recordName)"
        @unknown default:
            return "unknown"
        }
    }

    private func containsUserDataRecordID(_ recordIDs: [CKRecord.ID]) -> Bool {
        recordIDs.contains { isUserDataRecordID($0) }
    }

    private func isUserDataRecordID(_ recordID: CKRecord.ID) -> Bool {
        Self.isUserDataRecordName(recordID.recordName)
    }

    private nonisolated static func isUserDataRecordName(_ recordName: String) -> Bool {
        recordName.hasPrefix(RecordPrefix.episode)
        || recordName.hasPrefix(RecordPrefix.subscription)
        || recordName == RecordPrefix.appSettings
        || recordName == RecordPrefix.listScrollPositions
        || recordName == RecordPrefix.subscriptionListSettings
    }

    private func hasPendingUserDataChanges() -> Bool {
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

    private func queueDeviceRecordForPendingUserDataIfNeeded() {
        guard hasPendingUserDataChanges() else { return }
        queueDeviceRecord(stampLastSyncDate: true)
    }

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handleEventOnMain(event, syncEngine: syncEngine)
    }

    private func handleEventOnMain(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
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
                scheduleSyncRetryAfterFailure(code: (error as? CKError)?.code,
                                              retryAfter: (error as? CKError)?.retryAfterSeconds,
                                              reason: "fetchZoneChanges")
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

    private nonisolated static func materializeRecordsForSyncEngineCallback(_ recordIDs: [CKRecord.ID], snapshot: SyncEngineCallbackSnapshot) -> (records: [CKRecord], stale: [CKSyncEngine.PendingRecordZoneChange]) {
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

    private nonisolated static func logStaleUserDataSaveChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange], snapshot: SyncEngineCallbackSnapshot, pendingRecordZoneChanges: Int) {
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
    private nonisolated static func subscriptionPayloadsByFeedURL(_ feedURLs: [String], deviceID: String) -> [String: [String: Any]] {
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
    private nonisolated static func subscriptionPayload(for feed: CDFeed, feedURL: String, deviceID: String) -> [String: Any] {
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

    private nonisolated static func episodeStatesByObjectHash(_ objectHashes: [String]) -> [String: [String: Any]] {
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

    private struct SyncEngineCallbackSnapshot {
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

    private nonisolated static func syncEngineCallbackSnapshot() -> SyncEngineCallbackSnapshot {
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
    private nonisolated static func recordToSaveForSyncEngineCallback(for recordID: CKRecord.ID, snapshot: SyncEngineCallbackSnapshot) -> CKRecord? {
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
    private nonisolated static func subscriptionListSettingsRecordForSyncEngineCallback(for recordID: CKRecord.ID, snapshot: SyncEngineCallbackSnapshot) -> CKRecord {
        let defaults = UserDefaults.standard
        let updatedAt = defaults.object(forKey: Self.subscriptionListSettingsLocalModifiedDateKey) as? Date ?? Date()
        var payload: [String: Any] = [
            "sortMode": defaults.string(forKey: FeedListSortMode) ?? "",
            "updatedAt": updatedAt,
        ]
        if let manualOrder = defaults.array(forKey: Self.manualFeedOrderDefaultsKey) as? [String], !manualOrder.isEmpty {
            payload["manualOrder"] = manualOrder
        }
        let record = mutableRecordForSyncEngineCallback(recordType: RecordKind.subscriptionListSettings, recordID: recordID)
        populateForSyncEngineCallback(record, payload: payload, updatedAt: updatedAt, deviceID: snapshot.deviceID)
        return record
    }

    // The "v2:" format prefix makes migrated baselines recognizable: on a baseline
    // written by an older build, checkAndQueueSettingsChange decides between a one-time
    // repair re-publish (device owns a manual order) and silently recording the baseline
    // (sort-mode-only device — publishing would race the real state under LWW; exactly
    // that race flipped the iPhone off "manual" once).
    private nonisolated static let subscriptionListSettingsFingerprintPrefix = "v2:"

    private nonisolated static func subscriptionListSettingsFingerprint() -> String {
        let defaults = UserDefaults.standard
        let sortMode = defaults.string(forKey: FeedListSortMode) ?? ""
        let manualOrder = (defaults.array(forKey: manualFeedOrderDefaultsKey) as? [String]) ?? []
        return subscriptionListSettingsFingerprintPrefix + sha256Hex(([sortMode] + manualOrder).joined(separator: "\u{1}"))
    }

    // A device without any list sort state (fresh install, sort menu never used) has
    // nothing to publish — and must never defend that emptiness under last-writer-wins.
    private nonisolated static func hasLocalSubscriptionListSettings() -> Bool {
        let defaults = UserDefaults.standard
        if let sortMode = defaults.string(forKey: FeedListSortMode), !sortMode.isEmpty { return true }
        if let manualOrder = defaults.array(forKey: manualFeedOrderDefaultsKey) as? [String], !manualOrder.isEmpty { return true }
        return false
    }

    private nonisolated static func hasLocalManualFeedOrder() -> Bool {
        let manualOrder = UserDefaults.standard.array(forKey: manualFeedOrderDefaultsKey) as? [String]
        return manualOrder?.isEmpty == false
    }

    private nonisolated static func deviceRecordForSyncEngineCallback(for recordID: CKRecord.ID, snapshot: SyncEngineCallbackSnapshot) -> CKRecord {
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
    private nonisolated static let feedUIDKeyMarker = "@@FEEDUID@@"

    private nonisolated static func stableFeedPropertyKey(_ key: String, feedUID: String?) -> String {
        guard let feedUID, !feedUID.isEmpty, key.hasPrefix(feedUID + "_") else { return key }
        return feedUIDKeyMarker + key.dropFirst(feedUID.count)
    }

    private nonisolated static func localFeedPropertyKey(_ key: String, feedUID: String?) -> String {
        guard key.hasPrefix(feedUIDKeyMarker) else { return key }
        let suffix = key.dropFirst(feedUIDKeyMarker.count)
        guard let feedUID, !feedUID.isEmpty else { return String(suffix) }
        return feedUID + suffix
    }

    private nonisolated static func appSettingsRecordForSyncEngineCallback(for recordID: CKRecord.ID, snapshot: SyncEngineCallbackSnapshot) -> CKRecord {
        let updatedAt = snapshot.settingsLocalModifiedDate ?? Date()
        let record = mutableRecordForSyncEngineCallback(recordType: RecordKind.appSettings, recordID: recordID)
        populateForSyncEngineCallback(record, payload: appSettingsPayloadForSyncEngineCallback(updatedAt: updatedAt, deviceID: snapshot.deviceID), updatedAt: updatedAt, deviceID: snapshot.deviceID)
        return record
    }

    private nonisolated static func listScrollPositionsRecordForSyncEngineCallback(for recordID: CKRecord.ID, snapshot: SyncEngineCallbackSnapshot) -> CKRecord {
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

    private nonisolated static func mutableRecordForSyncEngineCallback(recordType: CKRecord.RecordType, recordID: CKRecord.ID) -> CKRecord {
        if let knownRecord = knownRecordForSyncEngineCallback(for: recordID), knownRecord.recordType == recordType {
            return knownRecord
        }
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    private nonisolated static func populateForSyncEngineCallback(_ record: CKRecord, payload: [String: Any], updatedAt: Date, deviceID: String) {
        record["schemaVersion"] = Self.schemaVersion as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
        record["deviceID"] = deviceID as CKRecordValue
        if let data = propertyListDataForSyncEngineCallback(from: payload) {
            record.encryptedValues["payload"] = data as CKRecordValue
        }
    }

    private nonisolated static func localDevicePayloadForSyncEngineCallback(snapshot: SyncEngineCallbackSnapshot) -> [String: Any] {
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
    private nonisolated static func devicePayload(deviceID: String,
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

    private nonisolated static func appSettingsPayloadForSyncEngineCallback(updatedAt: Date, deviceID: String) -> [String: Any] {
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

    private nonisolated static func shouldSyncSettingsKeyForSyncEngineCallback(_ key: String) -> Bool {
        if syncMetadataKeysForSyncEngineCallback().contains(key) { return false }
        if key.hasPrefix("ICiCloudSync") { return false }
        if transientSettingsKeysForSyncEngineCallback().contains(key) { return false }
        if nonSettingsUserDefaultsKeysForSyncEngineCallback().contains(key) { return false }
        return true
    }

    private nonisolated static func syncMetadataKeysForSyncEngineCallback() -> Set<String> {
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

    private nonisolated static func transientSettingsKeysForSyncEngineCallback() -> Set<String> {
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
            // Travels with subscription sync (ICSubscriptionListSettings), not settings sync.
            FeedListSortMode,
        ]
    }

    private nonisolated static func nonSettingsUserDefaultsKeysForSyncEngineCallback() -> Set<String> {
        [
            "DownloadResumeInfos",
            "DownloadResumeInfos_NSURLSession",
            "EpisodeLoadingQueueKey",
            "ICDiagnosticPreviousSessionEndedUnexpectedly",
            "ICDiagnosticPreviousSessionState",
        ]
    }

    // Feed properties that are device-local bookkeeping and never synced.
    private nonisolated static let internalFeedPropertyKeys: Set<String> = [
        "episodeLoadingComplete",
        "loadedEpisodeCount",
        "totalExpectedEpisodes",
        "cachedPlayerTintColor",
        "durationMetadataRefreshAttempted",
    ]

    private nonisolated static func isValidSettingsValueForSyncEngineCallback(_ value: Any) -> Bool {
        switch value {
        case is String, is NSNumber, is Date:
            return true
        default:
            return false
        }
    }

    private nonisolated static func knownRecordForSyncEngineCallback(for recordID: CKRecord.ID) -> CKRecord? {
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

    private nonisolated static func propertyListDataForSyncEngineCallback(from dictionary: [String: Any]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }

    private nonisolated static func deviceIDForSyncEngineCallback() -> String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.deviceIDKey), !stored.isEmpty {
            return stored
        }
        let newID = UUID().uuidString
        defaults.set(newID, forKey: Self.deviceIDKey)
        return newID
    }

    private nonisolated static func deviceMarketingNameForSyncEngineCallback() -> String {
        let identifier = deviceHardwareIdentifierForSyncEngineCallback()
        if let name = deviceMarketingNamesForSyncEngineCallback()[identifier] {
            return name
        }
        return identifier.isEmpty ? "Unknown Device" : identifier
    }

    private nonisolated static func deviceHardwareIdentifierForSyncEngineCallback() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? ""
            }
        }
    }

    private nonisolated static func appVersionStringForSyncEngineCallback() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if version.isEmpty { return build }
        if build.isEmpty { return version }
        return "\(version) (\(build))"
    }

    private nonisolated static func deviceMarketingNamesForSyncEngineCallback() -> [String: String] {
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

    private nonisolated static func date(from timeInterval: TimeInterval?) -> Date? {
        guard let timeInterval, timeInterval > 0 else { return nil }
        return Date(timeIntervalSince1970: timeInterval)
    }

    private nonisolated static func logSyncEvent(_ message: String, snapshot: SyncEngineCallbackSnapshot, pendingRecordZoneChanges: Int, metadata: [String: Any] = [:]) {
        var details = metadata
        details["episodesSyncEnabled"] = snapshot.episodesSyncEnabled
        details["subscriptionsSyncEnabled"] = snapshot.subscriptionsSyncEnabled
        details["settingsSyncEnabled"] = snapshot.settingsSyncEnabled
        details["anySyncEnabled"] = snapshot.anySyncEnabled
        details["pendingRecordZoneChanges"] = pendingRecordZoneChanges
        details["isMainThread"] = Thread.isMainThread
        ICDiagnosticLogger.shared.logEvent("icloud-sync", message: message, metadata: details as NSDictionary)
    }

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
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

    private func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for deletion in event.deletions where deletion.zoneID == zoneID {
            Self.removeSyncMetadataValue(forKey: Self.knownRecordsKey)
            Self.removeAllKnownRecordSystemFields()
            setSyncMetadata([String: [String: Any]](), forKey: Self.deviceCacheKey)
            scheduleCurrentEnabledDataForUpload()
        }
    }

    private func handleFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
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
    private func orderedModifications(_ modifications: [CKDatabase.RecordZoneChange.Modification]) -> [CKDatabase.RecordZoneChange.Modification] {
        guard modifications.contains(where: { $0.record.recordType == RecordKind.subscription }) else {
            return modifications
        }
        var others: [CKDatabase.RecordZoneChange.Modification] = []
        var subscriptions: [(modification: CKDatabase.RecordZoneChange.Modification, rank: Int)] = []
        for modification in modifications {
            if modification.record.recordType == RecordKind.subscription {
                let rank = (payloadDictionary(from: modification.record)?["rank"] as? NSNumber)?.intValue ?? Int.max
                subscriptions.append((modification, rank))
            } else {
                others.append(modification)
            }
        }
        let sortedSubscriptions = subscriptions.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map { $0.element.modification }
        return others + sortedSubscriptions
    }

    private func handleSentDatabaseChanges(_ event: CKSyncEngine.Event.SentDatabaseChanges) {
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

    private func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) async {
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

    private func handleFailedRecordSave(_ failedSave: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
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

    private func handleFailedRecordDelete(recordID: CKRecord.ID, error: CKError) -> Bool {
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

    private func handleCloudKitSendError(_ error: CKError) {
        switch error.code {
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited:
            setStatus(NSLocalizedString("iCloud ist vorübergehend nicht verfügbar.", comment: ""))
        default:
            setError(error)
        }
    }

    private func applyRemoteRecord(_ record: CKRecord) async {
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

    private func applyRemoteSubscriptionListSettings(_ payload: [String: Any]) {
        let remoteSortMode = (payload["sortMode"] as? String) ?? ""
        let remoteManualOrder = (payload["manualOrder"] as? [String]) ?? []
        // An EMPTY record (published by a pre-fix build on a freshly installed device)
        // must not win last-writer-wins against a real local state: ignore it entirely —
        // applying it would re-stamp localModifiedDate/baseline and silence this device
        // forever — and push the real local state back up instead.
        guard !remoteSortMode.isEmpty || !remoteManualOrder.isEmpty else {
            if Self.hasLocalSubscriptionListSettings() {
                addPendingSave(subscriptionListSettingsRecordID())
            }
            return
        }
        // A record WITHOUT a manual order must never displace a local manual-order
        // state, regardless of its timestamp: it carries strictly less information
        // (sort-mode-only devices, e.g. one where the user tried the sort menu while
        // "Manual" was still missing) and would flip the active mode on the device
        // that owns the real order. Push the richer local state back up instead.
        if remoteManualOrder.isEmpty,
           defaults.string(forKey: FeedListSortMode) == "manual",
           databaseManager.hasManualFeedOrder() {
            addPendingSave(subscriptionListSettingsRecordID())
            return
        }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = defaults.object(forKey: Self.subscriptionListSettingsLocalModifiedDateKey) as? Date,
           localDate.compare(remoteDate) == .orderedDescending {
            // Only defend the local state if one actually exists — a pre-fix build may
            // have stamped localModifiedDate on a device that has nothing to defend.
            if Self.hasLocalSubscriptionListSettings() {
                addPendingSave(subscriptionListSettingsRecordID())
                return
            }
        }
        if !remoteSortMode.isEmpty {
            defaults.set(remoteSortMode, forKey: FeedListSortMode)
        }
        if !remoteManualOrder.isEmpty {
            defaults.set(remoteManualOrder, forKey: Self.manualFeedOrderDefaultsKey)
        }
        setSyncMetadata(remoteDate, forKey: Self.subscriptionListSettingsLocalModifiedDateKey)
        // Re-baseline so applying the payload doesn't read as a local change and echo back.
        setSyncMetadata(Self.subscriptionListSettingsFingerprint(), forKey: Self.subscriptionListSettingsBaselineKey)
        // The actual reordering happens once at the end of the apply batch, after all
        // subscription records (and their stub feeds) of this fetch exist.
        needsSubscriptionListSortApply = true
    }

    // Writing the defaults alone changes nothing visible: the feed list orders by the
    // feeds' rank values. Replay the synced manual order onto the ranks once the apply
    // batch is done — that also makes "Manual" appear (and be checked) in the sort menu.
    private func applySubscriptionListSortIfNeeded() {
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

    private func applyRemoteDeletion(_ deletion: CKDatabase.RecordZoneChange.Deletion) {
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

    private func applyRemoteEpisodeState(_ payload: [String: Any], recordName: String, resolvedEpisode: CDEpisode? = nil) {
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

    private func episode(for payload: [String: Any]) -> CDEpisode? {
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

    private func storePendingEpisodeState(_ payload: [String: Any], recordName: String) {
        var pending = pendingPayloads(forKey: Self.pendingEpisodeStatesKey)
        pending[recordName] = payload
        setPendingPayloads(pending, forKey: Self.pendingEpisodeStatesKey)
    }

    private func applyPendingEpisodeStates() {
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

    private func applyRemoteSubscription(_ payload: [String: Any], recordName: String) async {
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

    private func subscribedFeed(for feedURL: String, title: String?) -> CDFeed? {
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
    private func applySubscriptionPayload(_ payload: [String: Any], to feed: CDFeed) {
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
    private func applyFeedPropertyPayload(_ property: [String: Any], to feed: CDFeed) -> Bool {
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

    private func storePendingSubscription(_ payload: [String: Any], recordName: String) {
        var pending = pendingPayloads(forKey: Self.pendingSubscriptionPayloadsKey)
        pending[recordName] = payload
        setPendingPayloads(pending, forKey: Self.pendingSubscriptionPayloadsKey)
    }

    private func applyPendingSubscriptions() async {
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
                applyRemoteSubscriptionListSettings(payload)
                pending.removeValue(forKey: recordName)
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

    private func applyRemoteAppSettings(_ payload: [String: Any]) {
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
    private func adoptSettingsPayload(_ payload: [String: Any]) {
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

    private func applyRemoteListScrollPositions(_ payload: [String: Any]) {
        guard let positions = payload["positions"] as? [String: NSNumber] else { return }
        let remoteDate = payload["lastModified"] as? Date ?? payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = scrollPositionsLocalModifiedDate(), localDate.compare(remoteDate) == .orderedDescending {
            addPendingSave(listScrollPositionsRecordID())
            return
        }

        ICApplySyncedListScrollPositions(positions, remoteDate)
        setScrollPositionsLocalModifiedDate(remoteDate)
    }

    // `nonisolated` so the runtime doesn't assert the main-queue executor at entry if the
    // notification is ever delivered off the main thread (which would crash a MainActor
    // method). Off-main UserDefaults changes aren't user-driven settings edits, so we ignore
    // them. We only arm a debounced content check — see checkAndQueueSettingsChange.
    @objc private nonisolated func defaultsDidChange(_ notification: Notification) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard isStarted, settingsSyncEnabled || subscriptionsSyncEnabled, !isApplyingRemoteChange, !isWritingSyncMetadata else { return }
            scheduleSettingsChangeCheck()
        }
    }

    // MUST stay `nonisolated`. NotificationCenter delivers this synchronously on whatever
    // thread performed the Core Data change. A background feed-refresh merge (a child
    // context saving into the main context) delivers it on that background thread. If this
    // method were MainActor-isolated (the class default), the Swift runtime would assert
    // the main-queue executor at method entry — `dispatch_assert_queue` → EXC_BREAKPOINT —
    // and crash before any of our code runs. So we do only thread-safe work here (extract
    // object IDs) and hop to the main actor for everything that touches our state.
    @objc private nonisolated func coreDataDidChange(_ notification: Notification) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: ICiCloudSyncEpisodesEnabled) || defaults.bool(forKey: ICiCloudSyncSubscriptionsEnabled) else { return }

        // Filter down to sync-relevant changes HERE, synchronously to the notification, where
        // `changedValuesForCurrentEvent` is still populated (it is empty again by the time the
        // main-actor task below runs). A feed refresh rewrites lastUpdate/etag/contentHash on
        // every merged feed and may touch episode metadata (duration/fulltext) — none of which
        // are synced. Dropping those objects by entity and changed-key name avoids resolving
        // them on the main thread later (fault firing that contends with the background
        // merge's writes for the SQLite store lock — the pull-to-refresh stutter).
        let insertedIDs = Self.syncRelevantInsertedObjectIDs(in: notification)
        let updatedIDs = Self.syncRelevantUpdatedObjectIDs(in: notification)
        let deletedIDs = Self.syncRelevantDeletedObjectIDs(in: notification)
        guard !insertedIDs.isEmpty || !updatedIDs.isEmpty || !deletedIDs.isEmpty else { return }

        if !Thread.isMainThread {
            Self.logSyncEvent("Core-Data-Änderung vom Hintergrund-Thread empfangen", metadata: [
                "insertedCount": insertedIDs.count,
                "updatedCount": updatedIDs.count,
                "deletedCount": deletedIDs.count,
            ])
        }

        // NSManagedObjectID is documented as thread-safe; box it so it can cross to the
        // main actor under strict concurrency.
        let changes = CoreDataChangeIDs(inserted: insertedIDs, updated: updatedIDs, deleted: deletedIDs)
        Task { @MainActor [weak self] in
            self?.processSyncObjectIDs(inserted: changes.inserted, updated: changes.updated, deleted: changes.deleted)
        }
    }

    private struct CoreDataChangeIDs: @unchecked Sendable {
        let inserted: [NSManagedObjectID]
        let updated: [NSManagedObjectID]
        let deleted: [NSManagedObjectID]
    }

    // Synced episode state is exactly played/favorite/position; synced feed fields are the ones
    // in the subscription payload, plus `subscribed`/`sourceURL_` for the delete path and
    // `properties` for property removal. Everything else — notably the fields a refresh always
    // rewrites — is irrelevant to the sync and gets dropped at the source.
    private nonisolated static let syncRelevantEpisodeKeys: Set<String> = ["consumed", "starred", "position"]
    private nonisolated static let syncRelevantFeedKeys: Set<String> = [
        "title", "rank", "parked", "username", "password", "subscribed", "sourceURL_", "properties",
    ]

    // Of the freshly-inserted objects keep only the ones the sync cares about (new
    // subscriptions / feed settings). A feed refresh inserts hundreds of episodes plus their
    // chapters/media; those are brand-new and unheard, so they are never uploaded anyway.
    // `objectID.entity.name` is immutable model metadata and fires no fault.
    private nonisolated static func syncRelevantInsertedObjectIDs(in notification: Notification) -> [NSManagedObjectID] {
        guard let objects = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> else { return [] }
        return objects.compactMap { object in
            switch object.objectID.entity.name {
            case "Feed":
                return object.objectID
            case "FeedProperty":
                return isInternalFeedProperty(object) ? nil : object.objectID
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
    private nonisolated static func syncRelevantUpdatedObjectIDs(in notification: Notification) -> [NSManagedObjectID] {
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
            default:
                break
            }
        }
        return ids
    }

    // Only feed deletions matter to the sync (they queue the subscription-record delete).
    private nonisolated static func syncRelevantDeletedObjectIDs(in notification: Notification) -> [NSManagedObjectID] {
        guard let objects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> else { return [] }
        return objects.compactMap { $0.objectID.entity.name == "Feed" ? $0.objectID : nil }
    }

    private nonisolated static func isInternalFeedProperty(_ object: NSManagedObject) -> Bool {
        guard let key = (object as? CDFeedProperty)?.key else { return false }
        return internalFeedPropertyKeys.contains(key)
    }

    private func processSyncObjectIDs(inserted: [NSManagedObjectID], updated: [NSManagedObjectID], deleted: [NSManagedObjectID]) {
        guard isStarted else { return }
        guard episodesSyncEnabled || subscriptionsSyncEnabled else { return }
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
        processSyncObjects(inserted: resolve(inserted),
                           updated: resolve(updated),
                           deleted: resolve(deleted))
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
    private func discardRemoteAppliedObjectIDs(_ ids: [NSManagedObjectID]) -> [NSManagedObjectID] {
        guard !remoteAppliedObjectIDs.isEmpty else { return ids }
        let remaining = ids.filter { !remoteAppliedObjectIDs.contains($0) }
        if remaining.count != ids.count {
            remoteAppliedObjectIDs.subtract(ids)
        }
        return remaining
    }

    private func processSyncObjects(inserted: [NSManagedObject],
                                    updated: [NSManagedObject],
                                    deleted: [NSManagedObject]) {
        guard isStarted else { return }

        var episodeObjectHashes: [String] = []
        var seenEpisodeHashes = Set<String>()
        var feedURLsToQueue: [String] = []
        var feedHashUpdates: [String: String] = [:]
        var feedURLsToDelete: [String] = []
        var seenFeedURLs = Set<String>()

        if episodesSyncEnabled {
            for object in inserted + updated {
                guard let episode = object as? CDEpisode else { continue }
                guard let objectHash = episode.objectHash, !objectHash.isEmpty, !seenEpisodeHashes.contains(objectHash) else { continue }
                // Only episodes with real state (played / favorite / position) are synced.
                // "Unheard" is the implicit default and is never uploaded — unless the
                // episode was synced before, so that resetting it back to unheard still
                // propagates to the other devices.
                let hasState = episode.consumed || episode.starred || episode.position > 0
                let previouslySynced = episodeLocalModifiedDate(for: objectHash) != nil
                guard hasState || previouslySynced else { continue }
                seenEpisodeHashes.insert(objectHash)
                episodeObjectHashes.append(objectHash)
            }
        }

        if subscriptionsSyncEnabled {
            let storedHashes = subscriptionPayloadHashes()
            func consider(_ feed: CDFeed) {
                guard feed.subscribed, let urlString = feed.sourceURL?.absoluteString, !seenFeedURLs.contains(urlString) else { return }
                let hash = subscriptionPayloadHash(for: feed)
                // Skip feeds whose synced payload is unchanged. A feed refresh only touches
                // lastUpdate/etag/contentHash, which aren't part of the payload, so this
                // makes refresh-all a no-op for subscription sync.
                guard storedHashes[urlString] != hash else { return }
                seenFeedURLs.insert(urlString)
                feedURLsToQueue.append(urlString)
                feedHashUpdates[urlString] = hash
            }
            for object in inserted + updated {
                if let feed = object as? CDFeed {
                    if feed.subscribed {
                        consider(feed)
                    } else if let urlString = feed.sourceURL?.absoluteString {
                        feedURLsToDelete.append(urlString)
                    }
                } else if let property = object as? CDFeedProperty,
                          let feed = property.feed,
                          let key = property.key, !Self.internalFeedPropertyKeys.contains(key) {
                    consider(feed)
                }
            }
            for object in deleted {
                if let feed = object as? CDFeed, let urlString = feed.sourceURL?.absoluteString {
                    feedURLsToDelete.append(urlString)
                }
            }
        }

        guard !episodeObjectHashes.isEmpty || !feedURLsToQueue.isEmpty || !feedURLsToDelete.isEmpty else { return }

        // Build the pending-change key set once and thread it through all batches so
        // queueing N changes stays O(N) instead of O(N²).
        var pendingKeys = pendingRecordZoneChangeKeys()
        var queuedUserData = false

        if !episodeObjectHashes.isEmpty {
            let now = Date()
            var updates: [String: Date] = [:]
            for hash in episodeObjectHashes { updates[hash] = now }
            setEpisodeLocalModifiedDates(updates)
            addPendingSaves(episodeObjectHashes.map { episodeRecordID(forObjectHash: $0) }, pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
            queuedUserData = true
        }

        if !feedURLsToQueue.isEmpty {
            applySubscriptionLocalChanges(feedURLs: feedURLsToQueue, hashes: feedHashUpdates)
            addPendingSaves(feedURLsToQueue.map { subscriptionRecordID(forFeedURL: $0) }, pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
            queuedUserData = true
        }

        if !feedURLsToDelete.isEmpty {
            initializeSyncEngineIfNeeded()
            var deleteChanges: [CKSyncEngine.PendingRecordZoneChange] = []
            for urlString in feedURLsToDelete {
                let change = CKSyncEngine.PendingRecordZoneChange.deleteRecord(subscriptionRecordID(forFeedURL: urlString))
                let key = pendingChangeKey(change)
                guard !pendingKeys.contains(key) else { continue }
                pendingKeys.insert(key)
                deleteChanges.append(change)
            }
            if !deleteChanges.isEmpty {
                syncEngine?.state.add(pendingRecordZoneChanges: deleteChanges)
            }
            removeSubscriptionLocalSyncState(forFeedURLs: feedURLsToDelete)
            queuedUserData = true
        }

        if queuedUserData {
            queueDeviceRecord(stampLastSyncDate: true)
            scheduleLowPrioritySync()
        }
    }

    // `nonisolated` (see defaultsDidChange) so an off-main delivery can't trip the MainActor
    // executor assertion at entry. Hops to the main actor for the actual work.
    @objc private nonisolated func listScrollPositionsDidChange(_ notification: Notification) {
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
    @objc private nonisolated func episodesWereAdded(_ notification: Notification) {
        // Fires once PER FEED during a refresh. Applying pending remote states walks the whole
        // pending list (with a main-thread fetch per entry), so doing it per feed is
        // O(feeds × pending) on the main thread. Debounce it to run once after the refresh
        // settles instead.
        Task { @MainActor [weak self] in
            self?.scheduleApplyPendingPayloads()
        }
    }

    private func scheduleApplyPendingPayloads() {
        guard isStarted else { return }
        applyPendingDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isStarted else { return }
                self.applyPendingEpisodeStates()
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
    private func scheduleSettingsChangeCheck() {
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
    private func checkAndQueueSettingsChange() {
        guard isStarted, !isApplyingRemoteChange else { return }
        if settingsSyncEnabled {
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
                if isFormatMigration, !Self.hasLocalManualFeedOrder() {
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
    private func storedSyncedSettingsHash() -> String? {
        defaults.string(forKey: Self.settingsSyncedHashKey)
    }

    private func setStoredSyncedSettingsHash(_ hash: String?) {
        setSyncMetadata(hash, forKey: Self.settingsSyncedHashKey)
    }

    // Fingerprint of the settings values that are actually synced (the same filter used to
    // build the ICAppSettings payload).
    private func syncedSettingsHash() -> String {
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        var components: [String] = []
        for (key, value) in domain where Self.shouldSyncSettingsKeyForSyncEngineCallback(key) && Self.isValidSettingsValueForSyncEngineCallback(value) {
            components.append("\(key)=\(value)")
        }
        return Self.sha256Hex(components.sorted().joined(separator: "\u{1}"))
    }

    private func queueListScrollPositionsRecord() {
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
    private func hydrateStubFeedsIfNeeded() {
        guard isStarted, !isHydratingStubFeeds else { return }
        // Feeds that already failed are excluded from the run AND the count: with them
        // included, every trigger (each fetch batch ends in one) restarted a doomed
        // "Lade Podcast-Folgen… 0/3" run every ~10s — endless requests, status noise
        // and a pending-states sweep per round. They retry on the next foreground entry.
        let pendingStubCount = stubFeedObjectIDs().filter { !hydrationFailedFeedIDs.contains($0) }.count
        guard pendingStubCount > 0 else { return }
        isHydratingStubFeeds = true
        isWaitingForEpisodeLoader = false
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
    private func stubFeedObjectIDs() -> [NSManagedObjectID] {
        guard let context = databaseManager.objectContext else { return [] }
        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Feed")
        request.resultType = .managedObjectIDResultType
        request.predicate = NSPredicate(format: "subscribed == YES AND parked == NO AND lastUpdate == nil AND episodes.@count == 0")
        request.sortDescriptors = [NSSortDescriptor(key: "rank", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    private func hydrateNextStubFeed() {
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
                if EpisodeLoadingManager.shared().isLoading {
                    // The background loader is still working through this feed's older
                    // episodes. Wait for its finish notification: queueing the next stub
                    // now would pile feeds into the loader, whose state persistence
                    // rewrites ALL pending feeds' episode data on every feed finish —
                    // the quadratic-plist trap that froze the iPad.
                    self.waitForEpisodeLoader()
                } else {
                    self.scheduleNextStubHydration()
                }
            }
        }
    }

    private func scheduleNextStubHydration() {
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

    private func waitForEpisodeLoader() {
        isWaitingForEpisodeLoader = true
        episodeLoaderWaitGeneration += 1
        let generation = episodeLoaderWaitGeneration
        // Failsafe: a cancelled load (e.g. unsubscribe mid-hydration) posts no finish
        // notification — don't let the hydration queue hang on it forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            Task { @MainActor in
                guard let self, self.isWaitingForEpisodeLoader,
                      self.episodeLoaderWaitGeneration == generation else { return }
                self.isWaitingForEpisodeLoader = false
                self.scheduleNextStubHydration()
            }
        }
    }

    // `nonisolated` (see defaultsDidChange) so an off-main delivery can't trip the
    // MainActor executor assertion at entry. Hops to the main actor for the actual work.
    @objc private nonisolated func episodeLoadingDidFinish(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, self.isWaitingForEpisodeLoader else { return }
            self.isWaitingForEpisodeLoader = false
            self.scheduleNextStubHydration()
        }
    }

    private func finishStubFeedHydration() {
        guard isHydratingStubFeeds else { return }
        isHydratingStubFeeds = false
        isWaitingForEpisodeLoader = false
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
            applyPendingEpisodeStates()
        }
    }

    private func localDevicePayload() -> [String: Any] {
        Self.devicePayload(deviceID: deviceID,
                           episodesEnabled: episodesSyncEnabled,
                           subscriptionsEnabled: subscriptionsSyncEnabled,
                           settingsEnabled: settingsSyncEnabled,
                           lastSyncDate: lastSyncDate)
    }

    private nonisolated static func feedPropertyValueType(for property: CDFeedProperty) -> String {
        if property.stringValue != nil {
            return "string"
        }
        guard let key = property.key else {
            return "bool"
        }
        return defaultFeedPropertyValueType(for: key)
    }

    private nonisolated static func defaultFeedPropertyValueType(for key: String) -> String {
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

    private func payloadDictionary(from record: CKRecord) -> [String: Any]? {
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

    private func rememberServerRecord(_ record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        Self.writeKnownRecordSystemFields(archiver.encodedData, forRecordName: record.recordID.recordName)
    }

    private func forgetServerRecord(for recordID: CKRecord.ID) {
        Self.removeKnownRecordSystemFields(forRecordName: recordID.recordName)
    }

    private func pendingPayloads(forKey key: String) -> [String: [String: Any]] {
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
    private func setPendingPayloads(_ payloads: [String: [String: Any]], forKey key: String) {
        pendingPayloadsCache[key] = payloads
        dirtyPendingPayloadKeys.insert(key)
        schedulePendingPayloadsWrite()
    }

    private func schedulePendingPayloadsWrite() {
        pendingPayloadsWriteWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushPendingPayloads()
            }
        }
        pendingPayloadsWriteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func flushPendingPayloads() {
        guard !dirtyPendingPayloadKeys.isEmpty else { return }
        for key in dirtyPendingPayloadKeys {
            setSyncMetadata(pendingPayloadsCache[key] ?? [:], forKey: key)
        }
        dirtyPendingPayloadKeys.removeAll()
    }

    private func deviceCache() -> [String: [String: Any]] {
        Self.syncMetadataValue(forKey: Self.deviceCacheKey) as? [String: [String: Any]] ?? [:]
    }

    private func updateDeviceCache(with payload: [String: Any]) {
        guard let id = payload["deviceID"] as? String, !id.isEmpty else { return }
        var cache = deviceCache()
        cache[id] = payload
        setSyncMetadata(cache, forKey: Self.deviceCacheKey)
        postDevicesChanged()
    }

    private func removeDeviceFromCache(_ deviceID: String) {
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

    private func deviceParticipates(_ payload: [String: Any]) -> Bool {
        ((payload["episodesEnabled"] as? Bool) ?? false)
        || ((payload["subscriptionsEnabled"] as? Bool) ?? false)
        || ((payload["settingsEnabled"] as? Bool) ?? false)
    }

    private func subscriptionRecordURLs() -> [String: String] {
        Self.syncMetadataValue(forKey: Self.subscriptionRecordURLsKey) as? [String: String] ?? [:]
    }

    private func subscriptionRecordURL(for recordName: String) -> String? {
        subscriptionRecordURLs()[recordName]
    }

    private func setSubscriptionRecordURL(_ feedURL: String, for recordName: String) {
        var urls = subscriptionRecordURLs()
        urls[recordName] = feedURL
        setSyncMetadata(urls, forKey: Self.subscriptionRecordURLsKey)
    }

    private func removeSubscriptionRecordURL(for recordName: String) {
        var urls = subscriptionRecordURLs()
        urls.removeValue(forKey: recordName)
        setSyncMetadata(urls, forKey: Self.subscriptionRecordURLsKey)
    }

    private func episodeLocalModifiedDates() -> [String: TimeInterval] {
        if let episodeLocalModifiedDatesCache {
            return episodeLocalModifiedDatesCache
        }
        let dates = Self.syncMetadataValue(forKey: Self.episodeLocalModifiedDatesKey) as? [String: TimeInterval] ?? [:]
        episodeLocalModifiedDatesCache = dates
        return dates
    }

    private func episodeLocalModifiedDate(for objectHash: String) -> Date? {
        guard let time = episodeLocalModifiedDates()[objectHash], time > 0 else { return nil }
        return Date(timeIntervalSince1970: time)
    }

    private func setEpisodeLocalModifiedDate(_ date: Date, for objectHash: String) {
        var dates = episodeLocalModifiedDates()
        dates[objectHash] = date.timeIntervalSince1970
        episodeLocalModifiedDatesCache = dates
        scheduleEpisodeLocalModifiedDatesWrite()
    }

    private func setEpisodeLocalModifiedDates(_ updates: [String: Date]) {
        guard !updates.isEmpty else { return }
        var dates = episodeLocalModifiedDates()
        for (objectHash, date) in updates {
            dates[objectHash] = date.timeIntervalSince1970
        }
        episodeLocalModifiedDatesCache = dates
        scheduleEpisodeLocalModifiedDatesWrite()
    }

    private func scheduleEpisodeLocalModifiedDatesWrite() {
        episodeLocalModifiedDatesWriteWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushEpisodeLocalModifiedDates()
            }
        }
        episodeLocalModifiedDatesWriteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func flushEpisodeLocalModifiedDates() {
        guard let dates = episodeLocalModifiedDatesCache else { return }
        setSyncMetadata(dates, forKey: Self.episodeLocalModifiedDatesKey)
    }

    private func subscriptionLocalModifiedDates() -> [String: TimeInterval] {
        Self.syncMetadataValue(forKey: Self.subscriptionLocalModifiedDatesKey) as? [String: TimeInterval] ?? [:]
    }

    private func subscriptionLocalModifiedDate(for feedURL: String) -> Date? {
        guard let time = subscriptionLocalModifiedDates()[feedURL], time > 0 else { return nil }
        return Date(timeIntervalSince1970: time)
    }

    private func setSubscriptionLocalModifiedDate(_ date: Date, for feedURL: String) {
        var dates = subscriptionLocalModifiedDates()
        dates[feedURL] = date.timeIntervalSince1970
        setSyncMetadata(dates, forKey: Self.subscriptionLocalModifiedDatesKey)
    }

    // Batches the record-URL, modified-date and payload-hash bookkeeping for a set of
    // locally changed subscriptions into one disk write each, instead of one per feed.
    private func applySubscriptionLocalChanges(feedURLs: [String], hashes: [String: String]) {
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

    private func subscriptionPayloadHashes() -> [String: String] {
        if let subscriptionPayloadHashesCache {
            return subscriptionPayloadHashesCache
        }
        let hashes = Self.syncMetadataValue(forKey: Self.subscriptionPayloadHashesKey) as? [String: String] ?? [:]
        subscriptionPayloadHashesCache = hashes
        return hashes
    }

    private func mergeSubscriptionPayloadHashes(_ updates: [String: String]) {
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
    private func removeSubscriptionLocalSyncState(forFeedURLs feedURLs: [String]) {
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

    private func subscriptionPayloadHash(for feed: CDFeed) -> String {
        Self.subscriptionPayloadHash(for: feed)
    }

    // Stable fingerprint of the fields that actually go into a synced subscription
    // record (title, rank, parked, credentials, non-internal properties). Excludes
    // refresh-only fields like lastUpdate/etag/contentHash so a feed refresh that only
    // updates those does not look like a change. `nonisolated` so the backfill plan can
    // compute it on its background context.
    private nonisolated static func subscriptionPayloadHash(for feed: CDFeed) -> String {
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

    private func settingsLocalModifiedDate() -> Date? {
        defaults.object(forKey: Self.settingsLocalModifiedDateKey) as? Date
    }

    private func setSettingsLocalModifiedDate(_ date: Date) {
        setSyncMetadata(date, forKey: Self.settingsLocalModifiedDateKey)
    }

    private func scrollPositionsLocalModifiedDate() -> Date? {
        defaults.object(forKey: Self.scrollPositionsLocalModifiedDateKey) as? Date
    }

    private func setScrollPositionsLocalModifiedDate(_ date: Date) {
        setSyncMetadata(date, forKey: Self.scrollPositionsLocalModifiedDateKey)
    }

    private func deviceRecordID(for deviceID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.device + deviceID, zoneID: zoneID)
    }

    private func episodeRecordID(forObjectHash objectHash: String) -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.episode + objectHash, zoneID: zoneID)
    }

    private func subscriptionRecordID(forFeedURL feedURL: String) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.subscriptionRecordName(forFeedURL: feedURL), zoneID: zoneID)
    }

    private func appSettingsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.appSettings, zoneID: zoneID)
    }

    private func listScrollPositionsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.listScrollPositions, zoneID: zoneID)
    }

    private func subscriptionListSettingsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.subscriptionListSettings, zoneID: zoneID)
    }

    private nonisolated static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func refreshAccountStatus() async {
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

    private func markSyncCompleted() {
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

    private func verifyNoExpectedUserDataWasSkippedBeforeCompleting() -> Bool {
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

    private func blockCompletionAndRequeue(reason: String, metadata: [String: Any]) {
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

    private func backfillProgressStatusText() -> String {
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
    private func pruneEpisodeLocalModifiedDatesIfNeeded() {
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

    private nonisolated static func allLocalEpisodeObjectHashes() async -> Set<String> {
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

    private var hasPendingSyncChanges: Bool {
        guard let syncEngine else { return false }
        return !syncEngine.state.pendingDatabaseChanges.isEmpty || !syncEngine.state.pendingRecordZoneChanges.isEmpty
    }

    private func syncDiagnosticsMetadata() -> [String: Any] {
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

    private func beginSyncActivity(_ direction: SyncActivityDirection) {
        if syncActivityDirection != direction {
            syncActivityDirection = direction
            syncActivityStartDate = Date()
            syncActivityRecordCount = 0
            syncActivityExpectedCount = 0
        }
    }

    private func recordSyncActivity(_ count: Int) {
        guard count > 0 else { return }
        syncActivityRecordCount += count
    }

    private func clearSyncActivity() {
        syncActivityDirection = nil
        syncActivityStartDate = nil
        syncActivityRecordCount = 0
        syncActivityExpectedCount = 0
        syncActivityKindLabel = nil
    }

    private nonisolated static func activityKindLabel(forRecordType recordType: String) -> String? {
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
    private func syncActivityStatusText() -> String? {
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

    private func markSyncCompletedIfFinished() {
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

    private func setStatus(_ status: String) {
        clearError()
        setSyncMetadata(status, forKey: Self.lastStatusKey)
    }

    private func setError(_ error: Error) {
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

    private func cloudKitErrorMetadata(_ error: Error) -> [String: Any] {
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

    private func displayStatus(for error: Error) -> String {
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

    private func clearError() {
        setSyncMetadata(nil, forKey: Self.lastErrorKey)
    }

    private nonisolated static func isFileBackedSyncMetadataKey(_ key: String) -> Bool {
        fileBackedSyncMetadataKeys.contains(key)
    }

    private nonisolated static func syncMetadataDirectoryURL() -> URL {
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

    private nonisolated static func syncMetadataFileURL(forKey key: String) -> URL {
        syncMetadataDirectoryURL().appendingPathComponent(key).appendingPathExtension("plist")
    }

    private nonisolated static func knownRecordSystemFieldsDirectoryURL() -> URL {
        let directoryURL = syncMetadataDirectoryURL().appendingPathComponent(knownRecordSystemFieldsDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var excludedURL = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedURL.setResourceValues(resourceValues)
        return directoryURL
    }

    private nonisolated static func knownRecordSystemFieldsFileURL(forRecordName recordName: String) -> URL {
        knownRecordSystemFieldsDirectoryURL().appendingPathComponent(sha256Hex(recordName)).appendingPathExtension("record")
    }

    private nonisolated static func knownRecordSystemFieldsData(forRecordName recordName: String) -> Data? {
        try? Data(contentsOf: knownRecordSystemFieldsFileURL(forRecordName: recordName))
    }

    private nonisolated static func writeKnownRecordSystemFields(_ data: Data, forRecordName recordName: String) {
        try? data.write(to: knownRecordSystemFieldsFileURL(forRecordName: recordName), options: .atomic)
    }

    private nonisolated static func removeKnownRecordSystemFields(forRecordName recordName: String) {
        try? FileManager.default.removeItem(at: knownRecordSystemFieldsFileURL(forRecordName: recordName))
    }

    private nonisolated static func removeAllKnownRecordSystemFields() {
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

    private nonisolated static func syncMetadataValue(forKey key: String) -> Any? {
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

    private nonisolated static func writeSyncMetadataValue(_ value: Any, forKey key: String) throws -> Int {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        try data.write(to: syncMetadataFileURL(forKey: key), options: .atomic)
        return data.count
    }

    private nonisolated static func removeSyncMetadataValue(forKey key: String) {
        try? FileManager.default.removeItem(at: syncMetadataFileURL(forKey: key))
    }

    private nonisolated static func syncMetadataSummary(for value: Any?) -> [String: String] {
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

    private nonisolated static func syncMetadataStorageSnapshot(reason: String) -> [String: String] {
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

    private func logSyncMetadataDiagnostic(operation: String, key: String, storage: String, bytes: Int?, value: Any?, error: Error? = nil) {
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

    private func setSyncMetadata(_ value: Any?, forKey key: String) {
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

    private func postStateChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: NSNotification.Name.ICiCloudSyncStateDidChange, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name.ICiCloudSyncStateDidChange, object: self)
            }
        }
    }

    private func postDevicesChanged() {
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
