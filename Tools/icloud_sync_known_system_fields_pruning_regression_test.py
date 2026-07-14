from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
TYPES = (ROOT / "Classes" / "ICiCloudSyncTypes.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


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
    raise SystemExit(f"Unterminated method: {signature}")


record = method_body(TYPES, "func record(_ record: CKRecord)")
remove = method_body(TYPES, "func remove(recordName: String)")
refresh = method_body(MANAGER, "func refreshCloudInventory(reason: String)")
snapshot = method_body(METADATA, "nonisolated static func snapshotKnownRecordSystemFieldsForPruning")
prune = method_body(METADATA, "nonisolated static func pruneKnownRecordSystemFields")
reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")

require(
    "allObservedRecordNames" in TYPES
    and "allObservedRecordNames.insert" in record
    and "allObservedRecordNames.remove" in remove,
    "Inventory must retain every physical CloudKit record name separately from user-facing type counts, including transitional tombstones.",
)
require(
    "inventoryIsComplete" in TYPES
    and "markRecordFetchFailure" in TYPES
    and "markZoneFetchCompleted" in TYPES,
    "Pruning needs an explicit proof that every record and the complete zone fetch succeeded.",
)
require(
    "recordWasChangedBlock" in refresh
    and "markRecordFetchFailure" in refresh
    and "recordZoneFetchResultBlock" in refresh
    and "markZoneFetchCompleted" in refresh
    and "inventoryIsComplete" in refresh,
    "Per-record and per-zone failures must make a nominal operation result ineligible for pruning.",
)
require(
    "newBackgroundContext()" in snapshot
    and "accountRecordName == %@" in snapshot
    and "recordName > %@" in snapshot
    and "systemFieldsData" in snapshot
    and "SHA256.hash" in snapshot
    and "await Task.yield()" in snapshot,
    "Capture the exact account-scoped rows and system-field versions before the Cloud inventory starts.",
)
require(
    "candidatesAtInventoryStart" in prune
    and "recordName IN %@" in prune
    and "systemFieldsData" in prune
    and "candidateDigest == currentDigest" in prune
    and "context.delete" in prune
    and "context.save()" in prune
    and "context.reset()" in prune
    and "await Task.yield()" in prune
    and "NOT" not in prune,
    "Delete only unchanged rows from the pre-inventory snapshot in bounded transactions; concurrent inserts/updates must survive.",
)
require(
    "pruneKnownRecordSystemFields" in refresh
    and "snapshotKnownRecordSystemFieldsForPruning" in refresh
    and "shouldPruneKnownRecordSystemFields" in refresh,
    "Only an account whose cleanup version is stale should snapshot and prune local system fields.",
)
completion = refresh.split("operation.fetchRecordZoneChangesResultBlock", 1)[1]
failure_position = completion.find("case .failure(let error):")
missing_zone_guard = completion.find("guard zoneIsMissing else", failure_position)
prune_position = completion.find("pruneKnownRecordSystemFields", failure_position)
require(
    -1 < failure_position < missing_zone_guard < prune_position
    and "return" in completion[missing_zone_guard:prune_position],
    "Offline, partial, and failed inventories must return before pruning; only an authoritative missing zone may use an empty live set.",
)
require(
    "knownRecordSystemFieldsPruneVersion" in MANAGER
    and "knownRecordSystemFieldsPruneVersionsKey" in MANAGER
    and "requestKnownRecordSystemFieldsPruneIfNeeded" in reconcile,
    "Existing customers need one automatic, account-scoped inventory pass; it must not run on every launch forever.",
)
require(
    -1 < completion.find("storeCloudInventory") < prune_position
    < completion.find("setKnownRecordSystemFieldsPruneVersion", prune_position),
    "Authoritative Cloud counts and devices must publish before the optional local cleanup, whose version advances only after success.",
)
cleanup_catch = completion[completion.find("catch", prune_position):]
require(
    "cloudInventoryRefreshErrorText" not in cleanup_catch.split("database.add(operation)", 1)[0],
    "A local cleanup failure must be diagnostic-only and must not turn a successful Cloud inventory into a user-facing count error.",
)
require(
    "knownRecordSystemFieldsPruneVersion(for: accountRecordName)" in refresh,
    "Mark the account's cleanup version only after a successful inventory and local prune.",
)
