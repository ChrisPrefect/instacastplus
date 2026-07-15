#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = "\n".join(
    (ROOT / "Classes" / name).read_text()
    for name in [
        "ICiCloudSyncManager.swift",
        "ICiCloudSyncManager+EngineRecords.swift",
        "ICiCloudSyncManager+RemoteApply.swift",
        "ICiCloudSyncManager+LocalChanges.swift",
        "ICiCloudSyncManager+Metadata.swift",
    ]
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = MANAGER.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = MANAGER.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(MANAGER)):
        if MANAGER[index] == "{":
            depth += 1
        elif MANAGER[index] == "}":
            depth -= 1
            if depth == 0:
                return MANAGER[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


account_change = method_body("func handleAccountChange")
sign_in_branch = account_change.split("case .signIn:", 1)[1].split("case .signOut:", 1)[0]
sign_out_branch = account_change.split("case .signOut:", 1)[1].split("case .switchAccounts:", 1)[0]
switch_branch = account_change.split("case .switchAccounts:", 1)[1].split("@unknown default:", 1)[0]
begin_switch = method_body("func beginICloudAccountSwitch")
require(
    "reconcileAvailableICloudAccount" in sign_in_branch
    and "resetForICloudAccountTransition(reinitializeEngine: false)" in sign_out_branch
    and "try await beginICloudAccountSwitch()" in switch_branch
    and "transferPendingChanges: false" in begin_switch,
    "Direct switches and sign-out/sign-in sequences must all isolate account-bound metadata.",
)
transition_reset = method_body("func resetForICloudAccountTransition")
require(
    "cancelInitialQueueTask()" in transition_reset
    and "cancelLowPrioritySyncTask()" in transition_reset
    and "resetSyncRetryBackoff()" in transition_reset,
    "Old-account queue and retry work must be cancelled before the new account starts.",
)
require(
    transition_reset.find("syncEngine = nil") < transition_reset.find("initializeSyncEngineIfNeeded()")
    and transition_reset.find("resetAllLocalSyncMetadata()") < transition_reset.find("initializeSyncEngineIfNeeded()"),
    "The new CKSyncEngine must be created only after the old engine and all account metadata are gone.",
)
require(
    "resetInitialBackfillCursorsForEnabledOptions()" in transition_reset,
    "Both signed-out edits and the new account must remain behind fresh episode/subscription/settings backfill gates.",
)

# Pending changes belong to the previous CloudKit account. They may cross a sign-out only
# after the stable CloudKit user-record ID proves that the user signed back into the SAME
# account. A direct account switch must never delete matching data in another account.
require(
    "accountUserRecordNameKey" in MANAGER and "userRecordID()" in MANAGER,
    "Account transitions must persist and compare CloudKit's stable account identity.",
)
require(
    "isICloudAccountIdentityVerified" in MANAGER
    and "isAccountIdentityVerified" in MANAGER,
    "CloudKit callbacks need a session-only account-identity gate, not only a persisted account ID.",
)
reconcile_account = method_body("func reconcileAvailableICloudAccount")
require(
    "previousAccountUserRecordName == currentAccountUserRecordName" in reconcile_account
    and "isICloudAccountSignedOut && isSameAccount" in reconcile_account
    and "transferPendingChanges: transferPendingChanges" in reconcile_account,
    "Signed-out pending changes may transfer only when CloudKit proves it is the same account.",
)
require(
    "transferPendingChanges: false" in begin_switch,
    "A direct account switch must never transfer old-account saves or tombstones.",
)

reset = method_body("func resetAllLocalSyncMetadata")
for key in [
    "deviceCacheKey",
    "pendingEpisodeStatesKey",
    "pendingSubscriptionPayloadsKey",
    "pendingInitialSettingsPayloadKey",
    "settingsLocalModifiedDateKey",
    "settingsSyncedHashKey",
    "scrollPositionsLocalModifiedDateKey",
    "subscriptionListSettingsLocalModifiedDateKey",
    "subscriptionListSettingsBaselineKey",
    "lastSyncDateKey",
    "cloudInventoryKey",
]:
    require(key in reset, f"Account reset is missing account-bound state: {key}")

require(
    "deleteSyncItemMetadata" in begin_switch
    and "removeAllLegacySyncItemMetadataSources" in begin_switch,
    "A direct account switch must delete indexed rows for the known old account and its legacy migration sources.",
)
require(
    "deleteSyncItemMetadata" in reconcile_account
    and "migrateLegacySyncItemMetadataIfNeeded" in reconcile_account
    and "bindSyncItemMetadata" in reconcile_account,
    "Reconciliation must clean stale-account rows, bind pending rows, and finish legacy migration before verification.",
)

for state in [
    "pendingInitialUploadBatches.removeAll()",
    "remoteAppliedObjectIDs.removeAll()",
    "needsSubscriptionListSortApply = false",
    "didPruneEpisodeLocalModifiedDates = false",
]:
    require(state in reset, f"Account reset is missing in-memory cleanup: {state}")

require(
    "ICiCloudSyncEpisodesEnabled" not in reset
    and "ICiCloudSyncSubscriptionsEnabled" not in reset
    and "ICiCloudSyncSettingsEnabled" not in reset
    and "deviceIDKey" not in reset,
    "Account reset must preserve the user's category switches and this installation's device identity.",
)

reset_cursors = method_body("func resetInitialBackfillCursorsForEnabledOptions")
require(
    "settingsSyncEnabled" in reset_cursors
    and "initialSettingsBackfillPendingKey" in reset_cursors,
    "A new account must repeat the fetch-gated settings handshake before any local settings publish.",
)
require(
    "subscriptionsSyncEnabled" in reset_cursors
    and "suppressSubscriptionDeletionsKey" in reset_cursors,
    "The first subscription fetch in a new account must retain local subscriptions via union semantics.",
)

# Independent inventory operations and old-engine callbacks can finish after the account
# switch. Generation/identity guards must prevent them from repopulating the reset state.
refresh_inventory = method_body("func refreshCloudInventory(reason:")
fetch_devices = method_body("func fetchDeviceRecordsForInventory")
event_handler = method_body("func handleEventOnMain")
require(
    "cloudAccountGeneration" in MANAGER
    and "generation == self.cloudAccountGeneration" in refresh_inventory
    and "generation == self.cloudAccountGeneration" in fetch_devices,
    "Late inventory/device callbacks from the old iCloud account must be ignored.",
)
require(
    "syncEngine === self.syncEngine" in event_handler,
    "Events arriving from the discarded old CKSyncEngine must not apply old-account data.",
)
require(
    "isICloudAccountSignedOut" in MANAGER
    and "if isICloudAccountSignedOut" in event_handler
    and "case .accountChange, .stateUpdate:" in event_handler,
    "After sign-out, the retained engine may persist local pending changes and receive the future account event, never old remote data events.",
)

batch_callback = method_body("nonisolated func nextRecordZoneChangeBatch")
require(
    batch_callback.count("currentGeneration(for: syncEngine") >= 2,
    "The record-batch delegate must reject the old engine both before and after expensive materialization.",
)
require(
    "pendingChangeIsEnabled" in batch_callback,
    "A send for another category must leave same-account offline saves and tombstones queued while their category is disabled.",
)
change_gate = method_body("nonisolated static func pendingChangeIsEnabled")
require(
    "RecordPrefix.episode" in change_gate
    and "snapshot.episodesSyncEnabled" in change_gate
    and "RecordPrefix.subscription" in change_gate
    and "snapshot.subscriptionsSyncEnabled" in change_gate,
    "The category send gate must cover both saves and deletes by record name.",
)
has_pending_changes = method_body("var hasPendingSyncChanges")
require(
    "pendingChangeIsEnabled" in has_pending_changes,
    "Paused-category entries must not cause an endless low-priority send loop or block completion for enabled categories.",
)

transition_reset = method_body("func resetForICloudAccountTransition")
require(
    "transferablePendingUserChanges" in transition_reset
    and "pendingRecordZoneChanges: transferableChanges" in transition_reset,
    "Offline episode resets and subscription saves/deletes must transfer into the fresh engine after sign-in.",
)
transferable_changes = method_body("func transferablePendingUserChanges")
require(
    "episodesSyncEnabled" not in transferable_changes
    and "subscriptionsSyncEnabled" not in transferable_changes,
    "Same-account offline changes must survive sign-in even if their category was switched off meanwhile.",
)
schedule_low_priority = method_body("func scheduleLowPrioritySync")
require(
    "!isICloudAccountSignedOut" in schedule_low_priority
    and "isICloudAccountIdentityVerified" in schedule_low_priority,
    "Local changes must remain queued until the current iCloud account identity is verified.",
)

refresh_account = method_body("func refreshAccountStatus")
perform_account_refresh = method_body("func performAccountStatusRefresh")
require(
    "let generation = cloudAccountGeneration" in perform_account_refresh
    and "guard generation == cloudAccountGeneration" in perform_account_refresh,
    "A stale account-status lookup must not overwrite the new account's UI state.",
)
require(
    "accountVerificationTask" in MANAGER,
    "Concurrent account checks must share one tracked verification task.",
)
await_low_priority = method_body("func cancelAndAwaitLowPrioritySync")
require(
    "await cancelAndAwaitLowPrioritySync()" in perform_account_refresh
    and "await activeLowPrioritySyncTask.value" in await_low_priority
    and perform_account_refresh.find("await cancelAndAwaitLowPrioritySync()")
        < perform_account_refresh.find("setICloudAccountIdentityVerified(false)"),
    "Account verification must finish a cancelled in-flight sync before closing the event gate.",
)
require(
    "manualSyncTask" in MANAGER
    and "backgroundSyncTask" in MANAGER
    and "await activeManualSyncTask.value" in perform_account_refresh
    and "await activeBackgroundSyncTask.value" in perform_account_refresh,
    "Account verification must also await manual and background fetches before closing their event gate.",
)
require(
    "sendFinalDeviceRecordUpdate()" not in reconcile_account,
    "A read-only account check must not start an untracked final device send.",
)

sync_options_changed = method_body("@objc func syncOptionsChanged")
require(
    "initializeSyncEngineIfNeeded()" in reconcile_account
    and "refreshAccountStatus" in sync_options_changed
    and sync_options_changed.find("refreshAccountStatus") < sync_options_changed.find("resumePendingFinalDeviceRecordUpdateIfNeeded"),
    "Enabling sync after a relaunch must re-check iCloud, then reload persisted pending changes without blocking the switch tap.",
)
manual_sync = method_body("func performManualSync() async throws")
manual_entry = method_body("@objc func performManualSyncWithCompletion")
require(
    "await refreshAccountStatus()" in manual_entry
    and manual_entry.find("await refreshAccountStatus()") < manual_entry.find("let operation = Task"),
    "Manual sync must verify a previously signed-out account before creating its tracked task.",
)
require(
    "Task.isCancelled" in manual_sync
    and "await refreshAccountStatus()" not in manual_sync
    and "!isICloudAccountSignedOut, isICloudAccountIdentityVerified" in manual_sync
    and manual_sync.find("Task.isCancelled") < manual_sync.find("let generation = cloudAccountGeneration"),
    "A cancelled manual task must exit before account refresh so account verification cannot await that same task.",
)
retry = method_body("func scheduleSyncRetryAfterFailure(code:")
require(
    "refreshAccountStatus" in retry,
    "Account/identity retry work must re-check account state rather than being blocked by the signed-out send gate.",
)
require(
    "syncRetryRequiresAccountVerification" in MANAGER
    and "requiresAccountVerification && !syncRetryRequiresAccountVerification" in retry
    and "syncRetryWorkItem?.cancel()" in retry,
    "An account-status retry must replace an already queued ordinary send retry.",
)

startup_recovery = method_body("func startPostInitializationRecoveryLifecycle")
require(
    "self.hasInitialUploadBackfillWork" in startup_recovery
    and "!self.isICloudAccountSignedOut" in startup_recovery
    and "self.isICloudAccountIdentityVerified" in startup_recovery,
    "Cold start must not queue/send old-engine data before the account identity check finishes.",
)

# A persisted CloudKit user ID is not proof that the same Apple ID is active in this
# process. With all categories OFF no account lookup runs at launch, yet episode resets and
# unsubscribes still need durable capture. They must enter a transition-scoped pending
# outbox and bind only after this launch verifies the real account.
capture_scope = method_body("nonisolated static func localOutboxCaptureAccountRecordName")
start = method_body("@objc func start()")
require(
    "verifiedAccountRecordName" in capture_scope
    and "accountUserRecordNameKey" not in capture_scope,
    "Unverified capture must never trust a persisted old account ID.",
)
require(
    "ensurePendingLocalOutboxScope()" in start
    and start.find("ensurePendingLocalOutboxScope()") < start.find("center.addObserver"),
    "Cold start must arm a pending outbox scope before local-change observers are registered, even with sync OFF.",
)
require(
    "verifiedAccountRecordNameForLocalCapture" in MANAGER,
    "Background Core Data notifications need a lock-protected session-verification gate.",
)
require(
    "bindPendingAccountLocalOutboxEntries" in reconcile_account
    and reconcile_account.find("bindPendingAccountLocalOutboxEntries")
        < reconcile_account.find("setICloudAccountIdentityVerified(true)"),
    "Pending cold-start edits must bind to the newly verified account before its drain gate opens.",
)

# The cold-start gate may already have captured local edits in a pending scope before a
# direct CK account event wins the race against refreshAccountStatus. The serialized
# transition must preserve that exact scope until reconciliation binds it; replacing only
# the pointer would leave its durable outbox and indexed-metadata rows orphaned forever.
require(
    "localOutboxPendingScopeKey" in MANAGER
    and "ensurePendingLocalOutboxScope()" in begin_switch
    and "rotatePendingLocalOutboxScope()" not in begin_switch,
    "A direct account switch must preserve an already-armed pending scope instead of orphaning its local edits.",
)


def begin_switch_scope(existing_scope):
    return existing_scope or "pending:new"


# Sequence model: start() arms scope A, a local mutation is written into A, then CK's
# switch event arrives before the first account refresh. Reconciliation can bind the
# mutation only if beginICloudAccountSwitch keeps A as the active source pointer.
armed_scope = "pending:cold-start"
outbox_rows = {armed_scope: {"episode:legacy-duplicate"}}
scope_after_switch = begin_switch_scope(armed_scope)
require(scope_after_switch == armed_scope,
        "The switch transaction must keep the cold-start scope that owns pending rows.")
bound_rows = outbox_rows.pop(scope_after_switch, set())
require(bound_rows == {"episode:legacy-duplicate"} and not outbox_rows,
        "Reconciliation must be able to bind every row from the preserved scope without an orphan bucket.")
bind_pending = method_body("func bindPendingAccountLocalOutboxEntries")
require(
    "pendingScope" in bind_pending
    and "localOutboxPendingAccountRecordName" not in bind_pending,
    "A binder must consume its captured transition scope, never a global pending bucket.",
)
require(
    "pendingScope" in reconcile_account
    and "currentPendingLocalOutboxScope" in reconcile_account,
    "Reconciliation must clear only the exact pending scope it successfully bound.",
)
foreground = method_body("@objc func performForegroundSyncIfNeeded")
require(
    "await self.refreshAccountStatus()" in foreground
    and "await self.continueEnabledSyncAfterAccountVerification()" in foreground
    and foreground.find("await self.refreshAccountStatus()")
        < foreground.find("await self.continueEnabledSyncAfterAccountVerification()"),
    "Foreground sync must verify the current account before starting a send.",
)
require(
    "await acquireICloudAccountTransition()" in account_change
    and account_change.count("transitionToken == iCloudAccountTransitionToken") >= 3,
    "Account-event branches must serialize transitions and attribute failures to the active transition token.",
)

begin_cycle = method_body("func beginSyncCycle")
end_cycle = method_body("func endSyncCycle")
require(
    "activeSyncCycleCounts" in MANAGER
    and "cloudAccountGeneration" in begin_cycle
    and "generation" in end_cycle,
    "Sync-cycle activity must be counted per account generation so an old cycle cannot block new-account completion.",
)

for signature in [
    "@objc func performManualSyncWithCompletion",
    "func performManualSync() async throws",
    "@objc func performBackgroundSyncWithCompletion",
    "func performLowPrioritySync() async",
    "@objc func deleteAllICloudDataWithCompletion",
    "func handleFetchedRecordZoneChanges",
    "func handleSentRecordZoneChanges",
]:
    body = method_body(signature)
    require(
        "cloudAccountGeneration" in body,
        f"Async old-account work must re-check account generation before mutating new state: {signature}",
    )

delete_all = method_body("@objc func deleteAllICloudDataWithCompletion")
require(
    "await refreshAccountStatus()" in delete_all
    and "isICloudAccountIdentityVerified" in delete_all
    and delete_all.find("await refreshAccountStatus()") < delete_all.find("let generation = cloudAccountGeneration"),
    "Deleting the CloudKit zone must verify which account is current before issuing the destructive request.",
)
require(
    "finalDeviceRecordUpdateTask" in MANAGER
    and "awaitFinalDeviceRecordUpdate()" in delete_all
    and "cancelAndAwaitLowPrioritySync()" in delete_all
    and delete_all.find("cancelAndAwaitLowPrioritySync()") < delete_all.find("deleteRecordZone")
    and delete_all.find("awaitFinalDeviceRecordUpdate()") < delete_all.find("deleteRecordZone"),
    "Zone deletion must await every tracked send so none can recreate the zone afterwards.",
)
before_zone_delete = delete_all.split("deleteRecordZone", 1)[0]
after_final_send_wait = before_zone_delete.split("awaitFinalDeviceRecordUpdate()", 1)[1]
require(
    "generation == cloudAccountGeneration" in after_final_send_wait,
    "An account switch while waiting for prior sends must stop before the new account's zone is deleted.",
)
background_sync = method_body("@objc func performBackgroundSyncWithCompletion")
background_generation = background_sync.find("let generation = self.cloudAccountGeneration")
require(
    "await refreshAccountStatus()" in background_sync
    and background_generation != -1
    and background_sync.find("await refreshAccountStatus()") < background_generation,
    "A background fetch after suspension must verify the account before using persisted engine state.",
)

require(
    "scheduleSyncRetryAfterFailure" in perform_account_refresh
    and "lastForegroundSyncDate = nil" in perform_account_refresh,
    "Indeterminate or temporarily unavailable account checks must retry and must not consume the foreground throttle window.",
)
after_delete = delete_all.split("deleteRecordZone", 1)[1]
require(
    "generation == cloudAccountGeneration" in after_delete
    and after_delete.find("generation == cloudAccountGeneration") < after_delete.find("syncEngine = nil"),
    "A zone delete returning after an account switch must stop before resetting the new account.",
)


print("iCloud account switch regression checks passed")
