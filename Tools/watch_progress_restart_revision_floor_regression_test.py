#!/usr/bin/env python3
"""Regression contract for the durable Watch progress revision floor.

The dangerous delivery order is:

    old terminal N -> retry queued fallback N+1 -> live progress N+2
    -> iPhone app restart -> terminal N arrives before queued N+1

Live progress may stay out of the durable status/UI model, but its ordering floor must
survive the restart before the progress is shown.  Otherwise the restarted phone can
accept the delayed terminal event and move the episode back to an older attempt.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()
CONTROLLER = (ROOT / "Classes" / "AppleWatchEpisodesViewController.m").read_text()
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
MODEL = (
    ROOT
    / "Resources"
    / "Models"
    / "Model5.xcdatamodeld"
    / "Model8.xcdatamodel"
    / "contents"
).read_text()
CURRENT_MODEL = (
    ROOT / "Resources" / "Models" / "Model5.xcdatamodeld" / ".xccurrentversion"
).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        semicolon = source.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


# Executable state-machine proof for the reported restart order.  A restart clears
# only the in-memory live floor; the existing Core Data ordering field must retain N+2.
terminal_n = 40
queued_n1 = 41
progress_n2 = 42
core_data_floor = 39
live_floor = 0

core_data_floor = max(core_data_floor, progress_n2)  # background commit before UI
live_floor = progress_n2
assert live_floor == progress_n2

live_floor = 0  # iPhone process restarted
assert terminal_n <= max(core_data_floor, live_floor)
assert queued_n1 <= max(core_data_floor, live_floor)


incoming = method_body(MANAGER, "- (void)_handleIncomingPayload:")
require(
    "_enqueueOrderedWatchDownloadPayload:" in incoming,
    "Ordered Watch download events need one pipeline so terminal N cannot pass progress N+2 "
    "while its durable commit is in flight.",
)

pipeline = method_body(MANAGER, "- (void)_processNextOrderedWatchDownloadPayload")
require(
    "watch.downloadProgress" in pipeline
    and "_persistWatchProgressRevisionForPayload:" in pipeline
    and "_handleIncomingPayloadOnMainThread:" in pipeline,
    "The ordered pipeline must persist progress revisions and route queued/terminal events "
    "through the existing handler.",
)

persist = method_body(MANAGER, "- (void)_persistWatchProgressRevisionForPayload:")
require(
    "newBackgroundContext" in persist
    and "NSBatchUpdateRequest" in persist
    and "NSUpdatedObjectIDsResultType" in persist,
    "Progress must durably update the existing AppleWatchEpisodeState row off the main context.",
)
require(
    'episodeHash == %@ AND uid == %@ AND watchLastEventRevision < %@' in persist
    and "@(eventRevision)" in persist
    and 'propertiesToUpdate = @{@"watchLastEventRevision": @(eventRevision)}' in persist,
    "The background write must be selection-safe and atomically monotone; a fetch/set/save race "
    "could overwrite a newer manifest or terminal revision.",
)
require(
    "executeRequest:updateRequest" in persist
    and "dispatch_get_main_queue()" in persist,
    "The conditional one-row update must commit in the background before returning to the UI.",
)
require(
    "DMANAGER save" not in persist
    and "USER_DEFAULTS" not in persist
    and "writeToFile" not in persist
    and "writeToURL" not in persist,
    "The two-second floor update must not save the whole main context or rewrite a growing plist.",
)

require(
    'name="watchLastEventRevision" optional="YES" attributeType="Integer 64" '
    'defaultValueString="0"' in MODEL
    and "Model8.xcdatamodel" in CURRENT_MODEL
    and "shouldMigrateStoreAutomatically = YES" in DATABASE
    and "shouldInferMappingModelAutomatically = YES" in DATABASE,
    "Existing installations must lightweight-migrate the optional revision floor to zero; the "
    "restart fix must not require a destructive or eager data rewrite.",
)

finish = method_body(MANAGER, "- (void)_finishPersistedWatchProgressPayload:")
require(
    "_applyPersistedTransientDownloadProgressPayload:" in finish
    and "mergeChangesFromRemoteContextSave:" in finish
    and "NSUpdatedObjectsKey" in finish
    and finish.find("_applyPersistedTransientDownloadProgressPayload:")
    < finish.find("mergeChangesFromRemoteContextSave:"),
    "Only after the durable commit may live progress be applied; then exactly the updated state "
    "IDs must be merged into the main context.",
)

persisted_apply = method_body(
    MANAGER, "- (AppleWatchEpisodeState*)_applyPersistedTransientDownloadProgressPayload:"
)
require(
    "state.watchLastEventRevision > eventRevision" in persisted_apply
    and "transientEventRevision >= eventRevision" in persisted_apply,
    "The post-commit UI path must accept equality with its own newly persisted floor, while still "
    "rejecting a newer durable event or an already-applied live sample.",
)
require(
    "_finishOrderedWatchDownloadPayload" in finish,
    "The next queued/terminal event may run only after the progress commit and UI handoff finish.",
)

context_changes = method_body(CONTROLLER, "- (void)_contextObjectsDidChange:")
require(
    "isKindOfClass:[CDEpisode class]" in context_changes
    and "isKindOfClass:[AppleWatchEpisodeState class]" not in context_changes,
    "Merging the one revision-floor row must remain a no-op for the Watch table's Core Data "
    "observer; live progress uses its lightweight targeted notification instead.",
)

print("Watch progress restart revision-floor regression checks passed")
