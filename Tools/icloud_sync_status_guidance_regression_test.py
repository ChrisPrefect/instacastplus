#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")

    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated body: {signature}")


MANAGER = "\n".join(
    read("Classes/" + name)
    for name in [
        "ICiCloudSyncManager.swift",
        "ICiCloudSyncTypes.swift",
        "ICiCloudSyncManager+EngineRecords.swift",
        "ICiCloudSyncManager+RemoteApply.swift",
        "ICiCloudSyncManager+LocalChanges.swift",
        "ICiCloudSyncManager+Metadata.swift",
    ]
)
SETTINGS = read("Classes/ICiCloudSyncSettingsViewController.m")
EN_STRINGS = read("Resources/en.lproj/Localizable.strings")
DE_STRINGS = read("Resources/de.lproj/Localizable.strings")


# A temporarily unverifiable completion is normal during the first paged upload. It must
# continue the upload without presenting the generic terminal-error copy.
completion_guard = method_body(MANAGER, "func verifyNoExpectedUserDataWasSkippedBeforeCompleting")
require(
    "pendingInitialUploadBatch" in completion_guard
    and "cloudInventory" not in completion_guard
    and "cachedSyncTotalCounts" not in completion_guard
    and "resetInitialEpisodeBackfillCursor()" not in completion_guard,
    "Completion must trust confirmed backfill cursors/pending batches, not a stale cloud-inventory snapshot.",
)
requeue = method_body(MANAGER, "func blockCompletionAndRequeue")
require(
    "hasUnresolvedSyncFailures = true" not in requeue
    and "lastErrorKey" not in requeue
    and "setStatus(recoveryProgressStatusText())" in requeue,
    "A completion recheck must remain an in-progress state, not become a user-visible sync failure.",
)

completion = method_body(MANAGER, "func markSyncCompletedIfFinished")
low_priority_sync = method_body(MANAGER, "func performLowPrioritySync")
require(
    "activeSyncCycleCount" in completion
    and "beginSyncCycle()" in low_priority_sync
    and "markSyncCompletedIfFinished(allowActiveSyncCycle: true)" in low_priority_sync,
    "Delegate callbacks must not finalize a send/fetch cycle before its outer operation finishes.",
)
require(
    "activeSyncCycleCount == 1" in completion
    and "activeSyncCycleCount == 0" in completion,
    "An outer sync may finalize only when it is the sole active cycle; overlapping cycles must remain in progress.",
)

# A transient error remains useful during its retry backoff. Once the automatic retry
# actually begins, the UI must replace it with live progress before showing a spinner.
first_retry_work = low_priority_sync.find("await applyPendingEpisodeStates()")
retry_backfill_status = low_priority_sync.find("setStatus(backfillProgressStatusText())")
retry_live_status = low_priority_sync.find('setStatus(NSLocalizedString("Synchronisiere…", comment: ""))')
retry_state_change = low_priority_sync.find("postStateChanged()")
require(
    first_retry_work != -1
    and retry_backfill_status != -1
    and retry_live_status != -1
    and retry_state_change != -1
    and max(retry_backfill_status, retry_live_status, retry_state_change) < first_retry_work,
    "A started automatic retry must replace the old visible error with current sync/backfill progress before doing work.",
)


# A sole device reads its own newly uploaded records back from the CloudKit change stream.
# That is verification, not a download from another device.
require(
    "case up, down, verifying" in MANAGER,
    "Sync activity must distinguish verification of this device's uploads from remote downloads.",
)
fetched_changes = method_body(MANAGER, "func handleFetchedRecordZoneChanges")
fetched_direction = method_body(MANAGER, "func fetchedActivityDirection")
require(
    "fetchedActivityDirection" in fetched_changes
    and "payload[\"deviceID\"]" in fetched_direction,
    "Fetched records must classify own-device echoes as verification activity.",
)
activity_status = method_body(MANAGER, "func syncActivityStatusText")
require(
    'NSLocalizedString("Prüft hochgeladene Daten…", comment: "")' in activity_status,
    "Verification activity needs an honest user-facing status instead of 'downloading'.",
)


# Initial progress must explain what is being uploaded and show the stable total.
backfill_status = method_body(MANAGER, "func backfillProgressStatusText")
require(
    '"Lädt Episodenstatus hoch… %ld / %ld"' in backfill_status,
    "Initial episode progress must name episode-state records and show X / Y.",
)


# Long status and error guidance must wrap, and the manual action must visibly remain busy
# across state-driven table reloads instead of reverting immediately to 'Sync Now'.
status_row_start = SETTINGS.find("if (indexPath.section == ICiCloudSyncSettingsSectionStatus) {")
status_row_end = SETTINGS.find("if (indexPath.section == ICiCloudSyncSettingsSectionOptions)", status_row_start)
status_row = SETTINGS[status_row_start:status_row_end]
require(
    'multilineInfoCellWithIdentifier:@"ICiCloudSyncStatusCell"' in status_row
    and "cell.detailTextLabel.numberOfLines = 0" in status_row,
    "The complete iCloud status must wrap on a dedicated multiline row.",
)
configure_sync_now = method_body(SETTINGS, "- (void)configureSyncNowCell")
require(
    "syncInProgress" in configure_sync_now
    and "UIActivityIndicatorView" in configure_sync_now,
    "The manual-sync row must keep a spinner and disabled state while a sync is already running.",
)

account_status = method_body(MANAGER, "func performAccountStatusRefresh")
require(
    "if hasInitialUploadBackfillWork" in account_status
    and "setStatus(backfillProgressStatusText())" in account_status,
    "An available iCloud account must not replace active first-upload progress with 'Ready'.",
)
require(
    account_status.count("setBlockingStatus(") >= 4,
    "Unavailable, restricted, temporary, and unknown account states must stop the backfill spinner with actionable status.",
)
temporary_status = account_status.split("case .temporarilyUnavailable:", 1)[1].split("@unknown default:", 1)[0]
require(
    'NSLocalizedString("iCloud ist vorübergehend nicht erreichbar. Die Synchronisation wird automatisch fortgesetzt."' in temporary_status
    and 'scheduleSyncRetryAfterFailure(code: .serviceUnavailable, reason: "accountStatus")' in temporary_status
    and "Tippe auf „Jetzt synchronisieren“" not in temporary_status,
    "A temporarily unavailable account must describe the automatic retry that is actually scheduled.",
)

manual_entry = method_body(MANAGER, "@objc func performManualSyncWithCompletion")
background_sync = method_body(MANAGER, "@objc func performBackgroundSyncWithCompletion")
require(
    'scheduleSyncRetryAfterFailure(error: error, reason: "manualSync")' in manual_entry
    and 'scheduleSyncRetryAfterFailure(error: error, reason: "backgroundSync")' in background_sync,
    "Every path promising automatic continuation must actually schedule the transient CloudKit retry.",
)


for strings, language in [(EN_STRINGS, "English"), (DE_STRINGS, "German")]:
    for key in [
        "Prüft hochgeladene Daten…",
        "Lädt Episodenstatus hoch… %ld / %ld",
        "Beim ersten Sync überträgt iCloud jeden Episodenstatus als eigenen Datensatz. Der Fortschritt wird oben angezeigt; danach werden nur Änderungen übertragen.",
        "iCloud ist vorübergehend nicht erreichbar. Die Synchronisation wird automatisch fortgesetzt.",
    ]:
        require(f'"{key}" =' in strings, f"{language} localization is missing: {key}")

require(
    "einige Minuten" not in method_body(SETTINGS, "- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:"),
    "The sync guidance must not claim a fixed multi-minute duration after the initial-upload performance fix.",
)


print("iCloud sync status guidance regression checks passed")
