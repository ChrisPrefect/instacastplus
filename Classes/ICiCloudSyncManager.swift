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

    private static let containerIdentifier = "iCloud.com.iteconomy.instacastplus"
    private static let zoneName = "InstacastSync"
    private static let schemaVersion = 1

    private static let deviceIDKey = "ICiCloudSyncDeviceID"
    private static let engineStateKey = "ICiCloudSyncEngineState"
    private static let knownRecordsKey = "ICiCloudSyncKnownRecords"
    private static let deviceCacheKey = "ICiCloudSyncDeviceCache"
    private static let subscriptionRecordURLsKey = "ICiCloudSyncSubscriptionRecordURLs"
    private static let pendingEpisodeStatesKey = "ICiCloudSyncPendingEpisodeStates"
    private static let pendingSubscriptionPayloadsKey = "ICiCloudSyncPendingSubscriptionPayloads"
    private static let episodeLocalModifiedDatesKey = "ICiCloudSyncEpisodeLocalModifiedDates"
    private static let subscriptionLocalModifiedDatesKey = "ICiCloudSyncSubscriptionLocalModifiedDates"
    private static let settingsLocalModifiedDateKey = "ICiCloudSyncSettingsLocalModifiedDate"
    private static let scrollPositionsLocalModifiedDateKey = "ICiCloudSyncScrollPositionsLocalModifiedDate"
    private static let lastSyncDateKey = "ICiCloudSyncLastSyncDate"
    private static let lastStatusKey = "ICiCloudSyncLastStatus"
    private static let lastErrorKey = "ICiCloudSyncLastError"
    private static let maximumRecordZoneChangesPerBatch = 200
    private static let pendingChangeQueueChunkSize = 200

    private enum RecordKind {
        static let device = "ICDevice"
        static let episodeState = "ICEpisodeState"
        static let subscription = "ICSubscription"
        static let appSettings = "ICAppSettings"
        static let listScrollPositions = "ICListScrollPositions"
    }

    private enum RecordPrefix {
        static let device = "device_"
        static let episode = "episode_"
        static let subscription = "subscription_"
        static let appSettings = "settings_app"
        static let listScrollPositions = "settings_listScrollPositions"
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
    private var episodeLocalModifiedDatesCache: [String: TimeInterval]?
    private var episodeLocalModifiedDatesWriteWorkItem: DispatchWorkItem?
    private var initialQueueTask: Task<Void, Never>?
    private var syncProgressTotal = 0
    private var syncProgressCompleted = 0
    private var syncProgressActive = false
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

    @objc var statusText: String {
        guard anySyncEnabled else { return NSLocalizedString("Aus", comment: "") }
        if let error = defaults.string(forKey: Self.lastErrorKey), !error.isEmpty {
            return error
        }
        if let progress = syncProgressStatusText() {
            return progress
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

    @objc func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(defaultsDidChange(_:)), name: UserDefaults.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(coreDataDidChange(_:)), name: .NSManagedObjectContextObjectsDidChange, object: databaseManager.objectContext)
        center.addObserver(self, selector: #selector(listScrollPositionsDidChange(_:)), name: NSNotification.Name.ICListScrollPositionsDidChange, object: nil)
        center.addObserver(self, selector: #selector(episodesWereAdded(_:)), name: NSNotification.Name.SubscriptionManagerDidAddEpisodes, object: nil)

        if anySyncEnabled {
            initializeSyncEngineIfNeeded()
            queueDeviceRecordForPendingUserDataIfNeeded()
            Task { @MainActor in
                await refreshAccountStatus()
            }
        }
    }

    @objc func setEpisodesSyncEnabled(_ enabled: Bool) {
        guard episodesSyncEnabled != enabled else { return }
        defaults.set(enabled, forKey: ICiCloudSyncEpisodesEnabled)
        logSyncEvent("Episode Sync-Schalter geändert", metadata: ["enabled": enabled])
        syncOptionsChanged()
    }

    @objc func setSubscriptionsSyncEnabled(_ enabled: Bool) {
        guard subscriptionsSyncEnabled != enabled else { return }
        defaults.set(enabled, forKey: ICiCloudSyncSubscriptionsEnabled)
        logSyncEvent("Abo Sync-Schalter geändert", metadata: ["enabled": enabled])
        syncOptionsChanged()
    }

    @objc func setSettingsSyncEnabled(_ enabled: Bool) {
        guard settingsSyncEnabled != enabled else { return }
        defaults.set(enabled, forKey: ICiCloudSyncSettingsEnabled)
        logSyncEvent("Einstellungs-Sync-Schalter geändert", metadata: ["enabled": enabled])
        syncOptionsChanged()
    }

    @objc func syncOptionsChanged() {
        guard isStarted else { return }

        logSyncEvent("Sync-Optionen geändert")
        if anySyncEnabled {
            initializeSyncEngineIfNeeded()
            queueDeviceRecord()
            scheduleCurrentEnabledDataForUpload()
            setStatus(NSLocalizedString("iCloud prüfen…", comment: ""))
            Task { @MainActor in
                await refreshAccountStatus()
            }
        } else if syncEngine != nil {
            logSyncEvent("iCloud Sync deaktiviert")
            clearError()
            cancelInitialQueueTask()
            queueDeviceRecord()
            setStatus(NSLocalizedString("Aus", comment: ""))
        }

        postStateChanged()
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

    @objc func shouldHandleRemoteNotification(_ userInfo: NSDictionary) -> Bool {
        guard let notification = userInfo as? [AnyHashable: Any] else { return false }
        return CKNotification(fromRemoteNotificationDictionary: notification) != nil
    }

    @objc func performBackgroundSyncWithCompletion(_ completion: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            let engine: CKSyncEngine? = await MainActor.run {
                guard anySyncEnabled else {
                    return nil
                }
                initializeSyncEngineIfNeeded()
                hasUnresolvedSyncFailures = false
                return syncEngine
            }

            guard let engine else {
                completion(.noData)
                return
            }

            do {
                try await engine.fetchChanges()
                await MainActor.run {
                    if !hasUnresolvedSyncFailures {
                        markSyncCompletedIfFinished()
                        completion(.newData)
                    } else {
                        postStateChanged()
                        completion(.failed)
                    }
                }
            } catch {
                await MainActor.run {
                    setError(error)
                    completion(.failed)
                }
            }
        }
    }

    private func performManualSync() async throws {
        guard anySyncEnabled else {
            clearError()
            setStatus(NSLocalizedString("Keine Sync-Kategorie aktiviert.", comment: ""))
            return
        }

        initializeSyncEngineIfNeeded()
        hasUnresolvedSyncFailures = false
        setStatus(NSLocalizedString("Synchronisiere…", comment: ""))
        postStateChanged()
        await initialQueueTask?.value
        queueDeviceRecordForPendingUserDataIfNeeded()
        beginSyncProgress()
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
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        syncEngine = engine
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = defaults.data(forKey: Self.engineStateKey) else {
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
        details["pendingRecordZoneChanges"] = syncEngine?.state.pendingRecordZoneChanges.count ?? 0
        details["isMainThread"] = Thread.isMainThread
        ICDiagnosticLogger.shared.logEvent("icloud-sync", message: message, metadata: details as NSDictionary)
    }

    private func scheduleCurrentEnabledDataForUpload() {
        cancelInitialQueueTask()
        logSyncEvent("Initiale iCloud-Queue geplant")
        initialQueueTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.logSyncEvent("Initiale iCloud-Queue gestartet")
            await self.queueCurrentEnabledDataForUpload()
            if !Task.isCancelled {
                self.logSyncEvent("Initiale iCloud-Queue abgeschlossen")
                self.postStateChanged()
            }
        }
    }

    private func cancelInitialQueueTask() {
        if initialQueueTask != nil {
            logSyncEvent("Initiale iCloud-Queue abgebrochen")
        }
        initialQueueTask?.cancel()
        initialQueueTask = nil
    }

    private func queueCurrentEnabledDataForUpload() async {
        logSyncEvent("iCloud Upload-Queue baut Daten auf")
        queueDeviceRecord()

        if episodesSyncEnabled {
            await queueAllEpisodeStateRecords()
            guard !Task.isCancelled else { return }
            queueListScrollPositionsRecord()
            await Task.yield()
        }
        if subscriptionsSyncEnabled {
            await queueAllSubscriptionRecords()
            guard !Task.isCancelled else { return }
            await Task.yield()
        }
        if settingsSyncEnabled {
            queueSettingsRecord()
            await Task.yield()
        }
        logSyncEvent("iCloud Upload-Queue fertig")
    }

    private func queueDeviceRecord(stampLastSyncDate: Bool = false) {
        if stampLastSyncDate {
            deviceRecordShouldStampSyncDate = true
        }
        addPendingSave(deviceRecordID(for: deviceID))
    }

    private func queueAllEpisodeStateRecords() async {
        let objectHashes = await episodeObjectHashesForInitialSync()
        guard episodesSyncEnabled, !objectHashes.isEmpty, !Task.isCancelled else { return }

        let now = Date()
        setEpisodeLocalModifiedDates(objectHashes.reduce(into: [String: Date]()) { partialResult, objectHash in
            partialResult[objectHash] = now
        })
        for chunk in chunked(objectHashes, size: Self.pendingChangeQueueChunkSize) {
            guard episodesSyncEnabled, !Task.isCancelled else { return }
            addPendingSaves(chunk.map { episodeRecordID(forObjectHash: $0) })
            await Task.yield()
        }
    }

    private func episodeObjectHashesForInitialSync() async -> [String] {
        guard let context = databaseManager.newBackgroundContext() else { return [] }
        let fetchBatchSize = Self.pendingChangeQueueChunkSize
        return await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Episode")
            request.resultType = .dictionaryResultType
            request.includesSubentities = false
            request.fetchBatchSize = fetchBatchSize
            request.propertiesToFetch = ["objectHash"]
            request.predicate = NSPredicate(format: "feed.subscribed == YES AND archived == NO AND objectHash != nil AND (consumed == YES OR starred == YES OR position > 0)")
            guard let rows = try? context.fetch(request) else { return [] }
            return rows.compactMap { $0["objectHash"] as? String }
        }
    }

    private func queueAllSubscriptionRecords() async {
        let feedURLs = await subscribedFeedURLsForInitialSync()
        guard subscriptionsSyncEnabled, !feedURLs.isEmpty, !Task.isCancelled else { return }

        let now = Date()
        var recordURLs = subscriptionRecordURLs()
        var modifiedDates = subscriptionLocalModifiedDates()
        for feedURL in feedURLs {
            recordURLs[subscriptionRecordID(forFeedURL: feedURL).recordName] = feedURL
            modifiedDates[feedURL] = now.timeIntervalSince1970
        }
        setSyncMetadata(recordURLs, forKey: Self.subscriptionRecordURLsKey)
        setSyncMetadata(modifiedDates, forKey: Self.subscriptionLocalModifiedDatesKey)

        for chunk in chunked(feedURLs, size: Self.pendingChangeQueueChunkSize) {
            guard subscriptionsSyncEnabled, !Task.isCancelled else { return }
            addPendingSaves(chunk.map { subscriptionRecordID(forFeedURL: $0) })
            await Task.yield()
        }
    }

    private func subscribedFeedURLsForInitialSync() async -> [String] {
        guard let context = databaseManager.newBackgroundContext() else { return [] }
        let fetchBatchSize = Self.pendingChangeQueueChunkSize
        return await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Feed")
            request.resultType = .dictionaryResultType
            request.includesSubentities = false
            request.fetchBatchSize = fetchBatchSize
            request.propertiesToFetch = ["sourceURL"]
            request.predicate = NSPredicate(format: "subscribed == YES AND sourceURL != nil")
            guard let rows = try? context.fetch(request) else { return [] }
            return rows.compactMap { row in
                if let url = row["sourceURL"] as? URL {
                    return url.absoluteString
                }
                if let url = row["sourceURL"] as? NSURL {
                    return url.absoluteString
                }
                return nil
            }
        }
    }

    private func chunked<T>(_ values: [T], size: Int) -> [[T]] {
        guard size > 0, !values.isEmpty else { return [] }
        var chunks: [[T]] = []
        var index = values.startIndex
        while index < values.endIndex {
            let end = values.index(index, offsetBy: size, limitedBy: values.endIndex) ?? values.endIndex
            chunks.append(Array(values[index..<end]))
            index = end
        }
        return chunks
    }

    private func addPendingSave(_ recordID: CKRecord.ID) {
        addPendingSaves([recordID])
    }

    private func addPendingSaves(_ recordIDs: [CKRecord.ID]) {
        guard !recordIDs.isEmpty else { return }
        let containsUserData = containsUserDataRecordID(recordIDs)
        initializeSyncEngineIfNeeded()
        let pendingKeys = Set(syncEngine?.state.pendingRecordZoneChanges.map { pendingChangeKey($0) } ?? [])
        let changes = recordIDs.compactMap { recordID -> CKSyncEngine.PendingRecordZoneChange? in
            let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID)
            return pendingKeys.contains(pendingChangeKey(change)) ? nil : change
        }
        if !changes.isEmpty {
            syncEngine?.state.add(pendingRecordZoneChanges: changes)
        }
        if containsUserData {
            queueDeviceRecord(stampLastSyncDate: true)
        }
    }

    private func addPendingDelete(_ recordID: CKRecord.ID) {
        initializeSyncEngineIfNeeded()
        let change = CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID)
        let pendingKeys = Set(syncEngine?.state.pendingRecordZoneChanges.map { pendingChangeKey($0) } ?? [])
        if !pendingKeys.contains(pendingChangeKey(change)) {
            syncEngine?.state.add(pendingRecordZoneChanges: [change])
        }
        if isUserDataRecordID(recordID) {
            queueDeviceRecord(stampLastSyncDate: true)
        }
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
        recordID.recordName.hasPrefix(RecordPrefix.episode)
        || recordID.recordName.hasPrefix(RecordPrefix.subscription)
        || recordID.recordName == RecordPrefix.appSettings
        || recordID.recordName == RecordPrefix.listScrollPositions
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

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
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
            await handleSentRecordZoneChanges(event)

        case .willFetchChanges, .willFetchRecordZoneChanges:
            clearSyncProgress()
            setStatus(NSLocalizedString("Empfange Änderungen…", comment: ""))
            postStateChanged()

        case .willSendChanges:
            hasUnresolvedSyncFailures = false
            beginSyncProgressIfNeeded()
            setStatus(NSLocalizedString("Sende Änderungen…", comment: ""))
            postStateChanged()

        case .didFetchChanges:
            markSyncCompletedIfFinished()

        case .didFetchRecordZoneChanges(let event):
            if let error = event.error {
                hasUnresolvedSyncFailures = true
                setError(error)
            } else {
                markSyncCompletedIfFinished()
            }

        case .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scopedChanges = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !scopedChanges.isEmpty else { return nil }

        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var staleSaveChanges: [CKSyncEngine.PendingRecordZoneChange] = []

        var validChangeCount = 0
        for change in scopedChanges {
            if validChangeCount >= Self.maximumRecordZoneChangesPerBatch { break }

            switch change {
            case .saveRecord(let recordID):
                if let record = await recordToSave(for: recordID) {
                    recordsToSave.append(record)
                    validChangeCount += 1
                } else {
                    staleSaveChanges.append(change)
                }
            case .deleteRecord(let recordID):
                recordIDsToDelete.append(recordID)
                validChangeCount += 1

            @unknown default:
                break
            }
        }

        if !staleSaveChanges.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: staleSaveChanges)
        }

        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }
        logSyncEvent("CKSyncEngine-Send-Batch materialisiert", metadata: [
            "scopedChanges": scopedChanges.count,
            "recordsToSave": recordsToSave.count,
            "recordIDsToDelete": recordIDsToDelete.count,
            "staleSaveChanges": staleSaveChanges.count,
            "validChangeCount": validChangeCount,
        ])
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: recordsToSave,
                                                  recordIDsToDelete: recordIDsToDelete,
                                                  atomicByZone: false)
    }

    private func recordToSave(for recordID: CKRecord.ID) async -> CKRecord? {
        if recordID.recordName.hasPrefix(RecordPrefix.device) {
            return deviceRecord(for: recordID)
        }
        if recordID.recordName.hasPrefix(RecordPrefix.episode) {
            guard episodesSyncEnabled else { return nil }
            return await episodeRecord(for: recordID)
        }
        if recordID.recordName.hasPrefix(RecordPrefix.subscription) {
            guard subscriptionsSyncEnabled else { return nil }
            return await subscriptionRecord(for: recordID)
        }
        if recordID.recordName == RecordPrefix.appSettings {
            guard settingsSyncEnabled else { return nil }
            return appSettingsRecord(for: recordID)
        }
        if recordID.recordName == RecordPrefix.listScrollPositions {
            guard episodesSyncEnabled else { return nil }
            return listScrollPositionsRecord(for: recordID)
        }
        return nil
    }

    private func deviceRecord(for recordID: CKRecord.ID) -> CKRecord {
        let record = mutableRecord(recordType: RecordKind.device, recordID: recordID)
        let now = Date()
        var payload = localDevicePayload()
        if deviceRecordShouldStampSyncDate {
            payload["lastSyncDate"] = now
        }
        payload["updatedAt"] = now
        populate(record, payload: payload, updatedAt: now)
        record["deviceID"] = deviceID as CKRecordValue
        updateDeviceCache(with: payload)
        return record
    }

    private func episodeRecord(for recordID: CKRecord.ID) async -> CKRecord? {
        let objectHash = String(recordID.recordName.dropFirst(RecordPrefix.episode.count))
        let updatedAt = episodeLocalModifiedDate(for: objectHash) ?? Date()
        guard let payload = await episodeStatePayload(forObjectHash: objectHash, updatedAt: updatedAt) else { return nil }

        let record = mutableRecord(recordType: RecordKind.episodeState, recordID: recordID)
        populate(record, payload: payload, updatedAt: updatedAt)
        return record
    }

    private func episodeStatePayload(forObjectHash objectHash: String, updatedAt: Date) async -> [String: Any]? {
        guard let context = databaseManager.newBackgroundContext() else { return nil }
        let currentDeviceID = deviceID
        return await context.perform {
            let request = NSFetchRequest<CDEpisode>(entityName: "Episode")
            request.fetchLimit = 1
            request.includesSubentities = false
            request.predicate = NSPredicate(format: "objectHash == %@", objectHash)
            guard let episode = try? context.fetch(request).first else { return nil }
            return [
                "objectHash": objectHash,
                "guid": episode.guid ?? "",
                "feedURL": episode.feed.sourceURL?.absoluteString ?? "",
                "played": episode.consumed,
                "position": Int(episode.position),
                "starred": episode.starred,
                "duration": Int(episode.duration),
                "deviceID": currentDeviceID,
                "updatedAt": updatedAt,
            ]
        }
    }

    private func subscriptionRecord(for recordID: CKRecord.ID) async -> CKRecord? {
        guard let feedURL = subscriptionRecordURL(for: recordID.recordName) else {
            return nil
        }

        let updatedAt = subscriptionLocalModifiedDate(for: feedURL) ?? Date()
        guard let payload = await subscriptionPayload(forFeedURL: feedURL, updatedAt: updatedAt) else { return nil }
        let record = mutableRecord(recordType: RecordKind.subscription, recordID: recordID)
        populate(record, payload: payload, updatedAt: updatedAt)
        return record
    }

    private func subscriptionPayload(forFeedURL feedURL: String, updatedAt: Date) async -> [String: Any]? {
        guard let context = databaseManager.newBackgroundContext() else { return nil }
        let currentDeviceID = deviceID
        let internalKeys = internalFeedPropertyKeys
        return await context.perform {
            let request = NSFetchRequest<CDFeed>(entityName: "Feed")
            request.fetchLimit = 1
            request.includesSubentities = false
            request.predicate = NSPredicate(format: "sourceURL_ == %@ AND subscribed == YES", feedURL)
            guard let feed = try? context.fetch(request).first else { return nil }

            var properties: [[String: Any]] = []
            for property in feed.properties as? Set<CDFeedProperty> ?? [] {
                guard let key = property.key, !internalKeys.contains(key) else { continue }
                var propertyPayload: [String: Any] = [
                    "key": key,
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
                "deviceID": currentDeviceID,
                "updatedAt": updatedAt,
            ]
        }
    }

    private func appSettingsRecord(for recordID: CKRecord.ID) -> CKRecord {
        let updatedAt = settingsLocalModifiedDate() ?? Date()
        let record = mutableRecord(recordType: RecordKind.appSettings, recordID: recordID)
        populate(record, payload: appSettingsPayload(updatedAt: updatedAt), updatedAt: updatedAt)
        return record
    }

    private func listScrollPositionsRecord(for recordID: CKRecord.ID) -> CKRecord {
        let updatedAt = scrollPositionsLocalModifiedDate() ?? ICListScrollPositionsLastModifiedDate() ?? Date()
        let record = mutableRecord(recordType: RecordKind.listScrollPositions, recordID: recordID)
        let payload: [String: Any] = [
            "positions": ICListScrollPositionsSnapshot() ?? [:],
            "lastModified": updatedAt,
            "deviceID": deviceID,
            "updatedAt": updatedAt,
        ]
        populate(record, payload: payload, updatedAt: updatedAt)
        return record
    }

    private func populate(_ record: CKRecord, payload: [String: Any], updatedAt: Date) {
        record["schemaVersion"] = Self.schemaVersion as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
        record["deviceID"] = deviceID as CKRecordValue
        if let data = propertyListData(from: payload) {
            record.encryptedValues["payload"] = data as CKRecordValue
        }
    }

    private func mutableRecord(recordType: CKRecord.RecordType, recordID: CKRecord.ID) -> CKRecord {
        if let knownRecord = knownRecord(for: recordID), knownRecord.recordType == recordType {
            return knownRecord
        }
        return CKRecord(recordType: recordType, recordID: recordID)
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
            setSyncMetadata([String: Data](), forKey: Self.knownRecordsKey)
            syncEngine = nil
            initializeSyncEngineIfNeeded()
            scheduleCurrentEnabledDataForUpload()
            setStatus(NSLocalizedString("iCloud Account gewechselt.", comment: ""))
        @unknown default:
            setStatus(NSLocalizedString("iCloud Account geändert.", comment: ""))
        }
    }

    private func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for deletion in event.deletions where deletion.zoneID == zoneID {
            setSyncMetadata([String: Data](), forKey: Self.knownRecordsKey)
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

        isApplyingRemoteChange = true
        defer {
            isApplyingRemoteChange = false
            postStateChanged()
            postDevicesChanged()
        }

        for modification in event.modifications {
            let record = modification.record
            rememberServerRecord(record)
            await applyRemoteRecord(record)
        }

        for deletion in event.deletions {
            forgetServerRecord(for: deletion.recordID)
            applyRemoteDeletion(deletion)
        }

        databaseManager.save()
        markSyncCompletedIfFinished()
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
        } else if !hasUnresolvedSyncFailures {
            markSyncCompletedIfFinished()
        }
    }

    private func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) async {
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

        for recordID in event.deletedRecordIDs {
            forgetServerRecord(for: recordID)
        }

        var retryRecords: [CKSyncEngine.PendingRecordZoneChange] = []
        var retryZones: [CKSyncEngine.PendingDatabaseChange] = []
        var hasFailedRecordChanges = false

        for failedSave in event.failedRecordSaves {
            if !(await handleFailedRecordSave(failedSave, retryRecords: &retryRecords, retryZones: &retryZones)) {
                hasFailedRecordChanges = true
            }
        }

        for (recordID, error) in event.failedRecordDeletes {
            if !handleFailedRecordDelete(recordID: recordID, error: error) {
                hasFailedRecordChanges = true
            }
        }

        if !retryZones.isEmpty {
            syncEngine?.state.add(pendingDatabaseChanges: retryZones)
        }
        if !retryRecords.isEmpty {
            syncEngine?.state.add(pendingRecordZoneChanges: retryRecords)
        }

        updateSyncProgressFromPendingChanges()

        if hasFailedRecordChanges {
            hasUnresolvedSyncFailures = true
            postStateChanged()
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
            }

        case RecordKind.subscription:
            if subscriptionsSyncEnabled {
                await applyRemoteSubscription(payload, recordName: record.recordID.recordName)
            }

        case RecordKind.appSettings:
            if settingsSyncEnabled {
                applyRemoteAppSettings(payload)
            }

        case RecordKind.listScrollPositions:
            if episodesSyncEnabled {
                applyRemoteListScrollPositions(payload)
            }

        default:
            break
        }
    }

    private func applyRemoteDeletion(_ deletion: CKDatabase.RecordZoneChange.Deletion) {
        if deletion.recordType == RecordKind.subscription && subscriptionsSyncEnabled {
            let recordName = deletion.recordID.recordName
            guard let feedURL = subscriptionRecordURL(for: recordName),
                  let url = URL(string: feedURL),
                  let feed = databaseManager.feed(withSourceURL: url) else {
                removeSubscriptionRecordURL(for: recordName)
                return
            }
            databaseManager.unsubscribeFeed(feed)
            removeSubscriptionRecordURL(for: recordName)
        }
    }

    private func applyRemoteEpisodeState(_ payload: [String: Any], recordName: String) {
        guard let objectHash = payload["objectHash"] as? String, !objectHash.isEmpty else { return }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = episodeLocalModifiedDate(for: objectHash),
           localDate.compare(remoteDate) == .orderedDescending {
            addPendingSave(episodeRecordID(forObjectHash: objectHash))
            return
        }

        guard let episode = episode(for: payload) else {
            storePendingEpisodeState(payload, recordName: recordName)
            return
        }

        let played = (payload["played"] as? Bool) ?? false
        let starred = (payload["starred"] as? Bool) ?? false
        let position = max(0, (payload["position"] as? NSNumber)?.int32Value ?? Int32((payload["position"] as? Int) ?? 0))

        if episode.consumed != played {
            episode.consumed = played
        }
        if episode.starred != starred {
            episode.starred = starred
        }
        if !played && episode.position != position {
            episode.position = position
        }
        if played && episode.position != 0 {
            episode.position = 0
        }

        setEpisodeLocalModifiedDate(remoteDate, for: objectHash)
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
        setSyncMetadata(pending, forKey: Self.pendingEpisodeStatesKey)
    }

    private func applyPendingEpisodeStates() {
        var pending = pendingPayloads(forKey: Self.pendingEpisodeStatesKey)
        guard !pending.isEmpty else { return }

        for (recordName, payload) in pending {
            if episode(for: payload) != nil {
                applyRemoteEpisodeState(payload, recordName: recordName)
                pending.removeValue(forKey: recordName)
            }
        }

        setSyncMetadata(pending, forKey: Self.pendingEpisodeStatesKey)
        databaseManager.save()
    }

    private func applyRemoteSubscription(_ payload: [String: Any], recordName: String) async {
        guard let feedURL = payload["feedURL"] as? String, !feedURL.isEmpty else { return }
        setSubscriptionRecordURL(feedURL, for: recordName)

        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = subscriptionLocalModifiedDate(for: feedURL),
           localDate.compare(remoteDate) == .orderedDescending {
            addPendingSave(subscriptionRecordID(forFeedURL: feedURL))
            return
        }

        guard let feed = await subscribedFeed(for: feedURL) else {
            storePendingSubscription(payload, recordName: recordName)
            return
        }

        applySubscriptionPayload(payload, to: feed)
        setSubscriptionLocalModifiedDate(remoteDate, for: feedURL)
    }

    private func subscribedFeed(for feedURL: String) async -> CDFeed? {
        guard let url = URL(string: feedURL) else { return nil }
        if let feed = databaseManager.feed(withSourceURL: url) {
            if !feed.subscribed {
                feed.subscribed = true
            }
            return feed
        }

        let subscribed = await withCheckedContinuation { continuation in
            subscriptionManager.subscribeFeed(with: url, options: ICSubscribeOptions(rawValue: 0)!) { feed, _ in
                continuation.resume(returning: feed != nil)
            }
        }
        guard subscribed else { return nil }
        return databaseManager.feed(withSourceURL: url)
    }

    private func applySubscriptionPayload(_ payload: [String: Any], to feed: CDFeed) {
        if let title = payload["title"] as? String, !title.isEmpty, feed.title == nil {
            feed.title = title
        }
        if let rank = payload["rank"] as? NSNumber {
            feed.rank = rank.int32Value
        } else if let rank = payload["rank"] as? Int {
            feed.rank = Int32(rank)
        }
        if let parked = payload["parked"] as? Bool {
            feed.parked = parked
        }
        if let username = payload["username"] as? String, !username.isEmpty {
            feed.username = username
        }
        if let password = payload["password"] as? String, !password.isEmpty {
            feed.password = password
        }

        if let properties = payload["properties"] as? [[String: Any]] {
            for property in properties {
                applyFeedPropertyPayload(property, to: feed)
            }
        }
    }

    private func applyFeedPropertyPayload(_ property: [String: Any], to feed: CDFeed) {
        guard let key = property["key"] as? String, !key.isEmpty else { return }

        switch property["valueType"] as? String ?? Self.defaultFeedPropertyValueType(for: key) {
        case "string":
            feed.setString(property["stringValue"] as? String ?? "", forKey: key)
        case "double":
            let value = (property["doubleValue"] as? NSNumber)?.doubleValue ?? (property["doubleValue"] as? Double) ?? 0
            feed.setDouble(value, forKey: key)
        case "integer":
            let value = (property["int32Value"] as? NSNumber)?.intValue ?? (property["int32Value"] as? Int) ?? 0
            feed.setInteger(value, forKey: key)
        case "bool":
            let value = (property["boolValue"] as? NSNumber)?.boolValue ?? (property["boolValue"] as? Bool) ?? false
            feed.setBool(value, forKey: key)
        default:
            break
        }
    }

    private func storePendingSubscription(_ payload: [String: Any], recordName: String) {
        var pending = pendingPayloads(forKey: Self.pendingSubscriptionPayloadsKey)
        pending[recordName] = payload
        setSyncMetadata(pending, forKey: Self.pendingSubscriptionPayloadsKey)
    }

    private func applyPendingSubscriptions() async {
        var pending = pendingPayloads(forKey: Self.pendingSubscriptionPayloadsKey)
        guard !pending.isEmpty else { return }

        for (recordName, payload) in pending {
            guard let feedURL = payload["feedURL"] as? String else { continue }
            if let feed = await subscribedFeed(for: feedURL) {
                applySubscriptionPayload(payload, to: feed)
                pending.removeValue(forKey: recordName)
            }
        }

        setSyncMetadata(pending, forKey: Self.pendingSubscriptionPayloadsKey)
        databaseManager.save()
    }

    private func applyRemoteAppSettings(_ payload: [String: Any]) {
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = settingsLocalModifiedDate(), localDate.compare(remoteDate) == .orderedDescending {
            addPendingSave(appSettingsRecordID())
            return
        }

        guard let values = payload["values"] as? [String: Any] else { return }
        for (key, value) in values where isValidSettingsValue(value) {
            defaults.set(value, forKey: key)
        }

        if let credentials = payload["credentials"] as? NSDictionary {
            ICRemoteChapterCredentialStore.restoreBackupCredentialValues(credentials)
        }

        setSettingsLocalModifiedDate(remoteDate)
        defaults.synchronize()
        ICAppearanceManager.shared()?.updateAppearance()
        NotificationCenter.default.post(name: NSNotification.Name("MainMenuListUIDsDidChangeNotification"), object: nil)
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

    @objc private func defaultsDidChange(_ notification: Notification) {
        guard isStarted, settingsSyncEnabled, !isApplyingRemoteChange, !isWritingSyncMetadata else { return }
        markSettingsLocallyChangedAndQueue()
    }

    @objc private func coreDataDidChange(_ notification: Notification) {
        guard isStarted, !isApplyingRemoteChange else { return }

        let inserted = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
        let updated = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
        let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []

        if episodesSyncEnabled {
            for object in inserted.union(updated) {
                guard let episode = object as? CDEpisode else { continue }
                let changed = object.changedValues()
                if inserted.contains(object) || changed["consumed"] != nil || changed["starred"] != nil || changed["position"] != nil {
                    markEpisodeLocallyChanged(episode)
                }
            }
        }

        if subscriptionsSyncEnabled {
            for object in inserted.union(updated) {
                if let feed = object as? CDFeed, let urlString = feed.sourceURL?.absoluteString {
                    if feed.subscribed {
                        setSubscriptionRecordURL(urlString, for: subscriptionRecordID(forFeedURL: urlString).recordName)
                        markSubscriptionLocallyChanged(feedURL: urlString)
                    } else {
                        addPendingDelete(subscriptionRecordID(forFeedURL: urlString))
                    }
                } else if let property = object as? CDFeedProperty,
                          let feed = property.feed,
                          let urlString = feed.sourceURL?.absoluteString,
                          feed.subscribed {
                    markSubscriptionLocallyChanged(feedURL: urlString)
                }
            }

            for object in deleted {
                if let feed = object as? CDFeed, let urlString = feed.sourceURL?.absoluteString {
                    addPendingDelete(subscriptionRecordID(forFeedURL: urlString))
                }
            }
        }
    }

    @objc private func listScrollPositionsDidChange(_ notification: Notification) {
        guard isStarted, episodesSyncEnabled, !isApplyingRemoteChange else { return }
        let now = Date()
        setScrollPositionsLocalModifiedDate(now)
        scrollDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.queueListScrollPositionsRecord()
            }
        }
        scrollDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    @objc private func episodesWereAdded(_ notification: Notification) {
        guard isStarted else { return }
        applyPendingEpisodeStates()
        Task { @MainActor in
            await applyPendingSubscriptions()
        }
    }

    private func markEpisodeLocallyChanged(_ episode: CDEpisode) {
        guard let objectHash = episode.objectHash, !objectHash.isEmpty else { return }
        markEpisodeObjectHashLocallyChanged(objectHash)
    }

    private func markEpisodeObjectHashLocallyChanged(_ objectHash: String) {
        setEpisodeLocalModifiedDate(Date(), for: objectHash)
        addPendingSave(episodeRecordID(forObjectHash: objectHash))
    }

    private func markSubscriptionLocallyChanged(feedURL: String) {
        let now = Date()
        setSubscriptionLocalModifiedDate(now, for: feedURL)
        addPendingSave(subscriptionRecordID(forFeedURL: feedURL))
    }

    private func markSettingsLocallyChangedAndQueue() {
        let now = Date()
        setSettingsLocalModifiedDate(now)
        settingsDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.queueSettingsRecord()
            }
        }
        settingsDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func queueSettingsRecord() {
        setSettingsLocalModifiedDate(Date())
        addPendingSave(appSettingsRecordID())
    }

    private func queueListScrollPositionsRecord() {
        addPendingSave(listScrollPositionsRecordID())
    }

    private func localDevicePayload() -> [String: Any] {
        let marketingName = deviceMarketingName()
        var payload: [String: Any] = [
            "deviceID": deviceID,
            "name": marketingName,
            "model": marketingName,
            "systemVersion": UIDevice.current.systemVersion,
            "appVersion": appVersionString(),
            "episodesEnabled": episodesSyncEnabled,
            "subscriptionsEnabled": subscriptionsSyncEnabled,
            "settingsEnabled": settingsSyncEnabled,
        ]
        if let lastSyncDate {
            payload["lastSyncDate"] = lastSyncDate
        }
        return payload
    }

    private func deviceHardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? ""
            }
        }
    }

    private func deviceMarketingName() -> String {
        let identifier = deviceHardwareIdentifier()
        if let name = deviceMarketingNames[identifier] {
            return name
        }
        return UIDevice.current.model
    }

    private var deviceMarketingNames: [String: String] {
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

    private func appVersionString() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if version.isEmpty { return build }
        if build.isEmpty { return version }
        return "\(version) (\(build))"
    }

    private func subscriptionPayload(for feed: CDFeed, updatedAt: Date) -> [String: Any] {
        var properties: [[String: Any]] = []
        for property in feed.properties as? Set<CDFeedProperty> ?? [] {
            guard let key = property.key, !internalFeedPropertyKeys.contains(key) else { continue }
            var propertyPayload: [String: Any] = [
                "key": key,
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
            "feedURL": feed.sourceURL?.absoluteString ?? "",
            "title": feed.title ?? "",
            "rank": Int(feed.rank),
            "parked": feed.parked,
            "username": feed.username ?? "",
            "password": feed.password ?? "",
            "properties": properties,
            "deviceID": deviceID,
            "updatedAt": updatedAt,
        ]
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

    private var internalFeedPropertyKeys: Set<String> {
        [
            "episodeLoadingComplete",
            "loadedEpisodeCount",
            "totalExpectedEpisodes",
            "cachedPlayerTintColor",
        ]
    }

    private func appSettingsPayload(updatedAt: Date) -> [String: Any] {
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        var values: [String: Any] = [:]
        for (key, value) in domain {
            guard shouldSyncSettingsKey(key), isValidSettingsValue(value) else { continue }
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

    private func shouldSyncSettingsKey(_ key: String) -> Bool {
        if syncMetadataKeys.contains(key) { return false }
        if key.hasPrefix("ICiCloudSync") { return false }
        if transientSettingsKeys.contains(key) { return false }
        return true
    }

    private var syncMetadataKeys: Set<String> {
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
            Self.scrollPositionsLocalModifiedDateKey,
            Self.lastSyncDateKey,
            Self.lastStatusKey,
            Self.lastErrorKey,
        ]
    }

    private var transientSettingsKeys: Set<String> {
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
        ]
    }

    private func isValidSettingsValue(_ value: Any) -> Bool {
        switch value {
        case is String, is NSNumber, is Date, is Data:
            return true
        case let array as [Any]:
            return array.allSatisfy { isValidSettingsValue($0) }
        case let dictionary as [String: Any]:
            return dictionary.values.allSatisfy { isValidSettingsValue($0) }
        case let dictionary as NSDictionary:
            for (key, value) in dictionary {
                guard key is String, isValidSettingsValue(value) else { return false }
            }
            return true
        case let array as NSArray:
            return array.allSatisfy { isValidSettingsValue($0) }
        default:
            return false
        }
    }

    private func propertyListData(from dictionary: [String: Any]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
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

    private func knownRecords() -> [String: Data] {
        normalizedDataDictionary(forKey: Self.knownRecordsKey)
    }

    private func normalizedDataDictionary(forKey key: String) -> [String: Data] {
        guard let rawRecords = defaults.dictionary(forKey: key) else { return [:] }
        var records: [String: Data] = [:]
        for (recordName, value) in rawRecords {
            if let data = value as? Data {
                records[recordName] = data
            } else if let data = value as? NSData {
                records[recordName] = data as Data
            }
        }
        return records
    }

    private func knownRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard let data = knownRecords()[recordID.recordName] else { return nil }
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            return CKRecord(coder: unarchiver)
        } catch {
            return nil
        }
    }

    private func rememberServerRecord(_ record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()

        var records = knownRecords()
        records[record.recordID.recordName] = archiver.encodedData
        setSyncMetadata(records, forKey: Self.knownRecordsKey)
    }

    private func forgetServerRecord(for recordID: CKRecord.ID) {
        var records = knownRecords()
        records.removeValue(forKey: recordID.recordName)
        setSyncMetadata(records, forKey: Self.knownRecordsKey)
    }

    private func pendingPayloads(forKey key: String) -> [String: [String: Any]] {
        defaults.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
    }

    private func deviceCache() -> [String: [String: Any]] {
        defaults.dictionary(forKey: Self.deviceCacheKey) as? [String: [String: Any]] ?? [:]
    }

    private func updateDeviceCache(with payload: [String: Any]) {
        guard let id = payload["deviceID"] as? String, !id.isEmpty else { return }
        var cache = deviceCache()
        cache[id] = payload
        setSyncMetadata(cache, forKey: Self.deviceCacheKey)
        postDevicesChanged()
    }

    private func deviceParticipates(_ payload: [String: Any]) -> Bool {
        ((payload["episodesEnabled"] as? Bool) ?? false)
        || ((payload["subscriptionsEnabled"] as? Bool) ?? false)
        || ((payload["settingsEnabled"] as? Bool) ?? false)
    }

    private func subscriptionRecordURLs() -> [String: String] {
        defaults.dictionary(forKey: Self.subscriptionRecordURLsKey) as? [String: String] ?? [:]
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
        let dates = defaults.dictionary(forKey: Self.episodeLocalModifiedDatesKey) as? [String: TimeInterval] ?? [:]
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
        defaults.dictionary(forKey: Self.subscriptionLocalModifiedDatesKey) as? [String: TimeInterval] ?? [:]
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
        CKRecord.ID(recordName: RecordPrefix.subscription + sha256Hex(feedURL), zoneID: zoneID)
    }

    private func appSettingsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.appSettings, zoneID: zoneID)
    }

    private func listScrollPositionsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.listScrollPositions, zoneID: zoneID)
    }

    private func sha256Hex(_ string: String) -> String {
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
        clearSyncProgress()
        if syncedUserDataInCurrentRun {
            let now = Date()
            setSyncMetadata(now, forKey: Self.lastSyncDateKey)
            var payload = localDevicePayload()
            payload["lastSyncDate"] = now
            updateDeviceCache(with: payload)
            clearError()
            setStatus(NSLocalizedString("Synchronisiert", comment: ""))
            postDevicesChanged()
        } else {
            clearError()
            setStatus(NSLocalizedString("Keine Änderungen", comment: ""))
        }
        deviceRecordShouldStampSyncDate = false
        syncedUserDataInCurrentRun = false
        postStateChanged()
    }

    private var hasPendingSyncChanges: Bool {
        guard let syncEngine else { return false }
        return !syncEngine.state.pendingDatabaseChanges.isEmpty || !syncEngine.state.pendingRecordZoneChanges.isEmpty
    }

    private func beginSyncProgress() {
        syncProgressTotal = syncEngine?.state.pendingRecordZoneChanges.count ?? 0
        syncProgressCompleted = 0
        syncProgressActive = syncProgressTotal > 0
    }

    private func beginSyncProgressIfNeeded() {
        if !syncProgressActive {
            beginSyncProgress()
        }
    }

    private func updateSyncProgressFromPendingChanges() {
        guard syncProgressActive, syncProgressTotal > 0 else { return }
        let pendingCount = syncEngine?.state.pendingRecordZoneChanges.count ?? 0
        let completedCount = syncProgressTotal - pendingCount
        syncProgressCompleted = min(syncProgressTotal, max(syncProgressCompleted, completedCount))
    }

    private func clearSyncProgress() {
        syncProgressTotal = 0
        syncProgressCompleted = 0
        syncProgressActive = false
    }

    private func syncProgressStatusText() -> String? {
        guard syncProgressActive, syncProgressTotal > 0 else { return nil }
        return String(format: NSLocalizedString("%ld/%ld Elemente", comment: ""), syncProgressCompleted, syncProgressTotal)
    }

    private func markSyncCompletedIfFinished() {
        guard !hasUnresolvedSyncFailures else {
            postStateChanged()
            return
        }
        guard !hasPendingSyncChanges else {
            beginSyncProgressIfNeeded()
            updateSyncProgressFromPendingChanges()
            setStatus(NSLocalizedString("Synchronisiere…", comment: ""))
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
        clearSyncProgress()
        deviceRecordShouldStampSyncDate = false
        syncedUserDataInCurrentRun = false
        let status = displayStatus(for: error)
        let nsError = error as NSError
        logSyncEvent("iCloud Sync Fehler", metadata: [
            "domain": nsError.domain,
            "code": nsError.code,
            "status": status,
        ])
        setSyncMetadata(status, forKey: Self.lastErrorKey)
        postStateChanged()
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

    private func setSyncMetadata(_ value: Any?, forKey key: String) {
        isWritingSyncMetadata = true
        if let value {
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
