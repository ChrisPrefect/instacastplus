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

    // MUST stay `nonisolated`. NotificationCenter delivers this synchronously on whatever
    // thread performed the Core Data change. A background feed-refresh merge (a child
    // context saving into the main context) delivers it on that background thread. If this
    // method were MainActor-isolated (the class default), the Swift runtime would assert
    // the main-queue executor at method entry — `dispatch_assert_queue` → EXC_BREAKPOINT —
    // and crash before any of our code runs. So we do only thread-safe work here (extract
    // object IDs) and hop to the main actor for everything that touches our state.
    @objc nonisolated func coreDataDidChange(_ notification: Notification) {
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

    struct CoreDataChangeIDs: @unchecked Sendable {
        let inserted: [NSManagedObjectID]
        let updated: [NSManagedObjectID]
        let deleted: [NSManagedObjectID]
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

    // Only feed deletions matter to the sync (they queue the subscription-record delete).
    nonisolated static func syncRelevantDeletedObjectIDs(in notification: Notification) -> [NSManagedObjectID] {
        guard let objects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> else { return [] }
        return objects.compactMap { $0.objectID.entity.name == "Feed" ? $0.objectID : nil }
    }

    nonisolated static func isInternalFeedProperty(_ object: NSManagedObject) -> Bool {
        guard let key = (object as? CDFeedProperty)?.key else { return false }
        return internalFeedPropertyKeys.contains(key)
    }

    func processSyncObjectIDs(inserted: [NSManagedObjectID], updated: [NSManagedObjectID], deleted: [NSManagedObjectID]) {
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
    func discardRemoteAppliedObjectIDs(_ ids: [NSManagedObjectID]) -> [NSManagedObjectID] {
        guard !remoteAppliedObjectIDs.isEmpty else { return ids }
        let remaining = ids.filter { !remoteAppliedObjectIDs.contains($0) }
        if remaining.count != ids.count {
            remoteAppliedObjectIDs.subtract(ids)
        }
        return remaining
    }

    func processSyncObjects(inserted: [NSManagedObject],
                                    updated: [NSManagedObject],
                                    deleted: [NSManagedObject]) {
        guard isStarted else { return }

        var episodeObjectHashes: [String] = []
        var seenEpisodeHashes = Set<String>()
        var feedURLsToQueue: [String] = []
        var feedHashUpdates: [String: String] = [:]
        var feedURLsToDelete: [String] = []
        var seenFeedURLs = Set<String>()
        var listSettingsChanged = false

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

        if subscriptionsSyncEnabled {
            listSettingsChanged = (inserted + updated).contains { $0 is CDEpisodeList }
        }

        guard !episodeObjectHashes.isEmpty || !feedURLsToQueue.isEmpty || !feedURLsToDelete.isEmpty || listSettingsChanged else { return }

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

        if listSettingsChanged {
            setSyncMetadata(Date(), forKey: Self.subscriptionListSettingsLocalModifiedDateKey)
            setSyncMetadata(Self.subscriptionListSettingsFingerprint(), forKey: Self.subscriptionListSettingsBaselineKey)
            addPendingSaves([subscriptionListSettingsRecordID()], pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
            queuedUserData = true
        }

        if queuedUserData {
            queueDeviceRecord(stampLastSyncDate: true)
            scheduleLowPrioritySync()
        }
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

    func waitForEpisodeLoader() {
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
    @objc nonisolated func episodeLoadingDidFinish(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, self.isWaitingForEpisodeLoader else { return }
            self.isWaitingForEpisodeLoader = false
            self.scheduleNextStubHydration()
        }
    }

    func finishStubFeedHydration() {
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
}
