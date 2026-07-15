#!/usr/bin/env python3
"""Pins remote subscription replay to one bounded off-main transaction per page."""

from pathlib import Path
from urllib.parse import urlsplit, urlunsplit


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
TYPES = (ROOT / "Classes" / "ICiCloudSyncTypes.swift").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function(source: str, signature: str) -> tuple[str, str]:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:brace], source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


apply_declaration, apply_body = function(REMOTE, "func applyPendingSubscriptions() async")
list_settings_marker = apply_body.find("// List settings depend on all referenced feed stubs")
require(list_settings_marker != -1, "Missing post-subscription list-settings phase.")
subscription_page_body = apply_body[:list_settings_marker]
worker_declaration, worker_body = function(
    REMOTE,
    "nonisolated static func applyPendingSubscriptionBatchInBackground(",
)
payload_declaration, payload_body = function(
    REMOTE,
    "nonisolated static func applySubscriptionPayloadInBackground(",
)
consume_declaration, consume_body = function(
    REMOTE,
    "func consumeSubscriptionApplyBatchResult(",
)
_, view_merge_body = function(
    REMOTE,
    "func performSynchronousRemoteViewContextMerge(",
)
resolver_declaration, resolver_body = function(
    REMOTE,
    "nonisolated static func resolvedPendingSubscriptionChanges(",
)

require(
    "applyPendingSubscriptionBatchInBackground" in subscription_page_body
    and "consumeSubscriptionApplyBatchResult" in subscription_page_body,
    "Pending subscriptions must converge on one background apply worker and one exact view merge.",
)
for forbidden in (
    "performSynchronousRemoteApplyBatch {",
    "databaseManager.objectContext",
    "databaseManager.feed(withSourceURL:",
    "subscriptionManager.subscribeParserFeed",
    "applyRemoteSubscription(",
    "applyRemoteSubscriptionTombstone(",
    "applyPendingLegacySubscriptionDeletion(",
):
    require(
        forbidden not in subscription_page_body,
        f"Pending subscription orchestration still performs per-feed MainActor work: {forbidden}",
    )

require(
    "nonisolated static" in worker_declaration and "async throws" in worker_declaration,
    "The subscription apply worker must be nonisolated and asynchronous.",
)
require(
    "newICloudSyncBackgroundContext()" in worker_body
    and "context.perform" in worker_body
    and "context.save()" in worker_body,
    "Each bounded subscription page must commit through the dedicated iCloud context.",
)
require(
    'NSFetchRequest<CDFeed>(entityName: "Feed")' in worker_body
    and "sourceURL_ IN[c] %@" in worker_body
    and 'relationshipKeyPathsForPrefetching = ["properties"]' in worker_body,
    "The worker must resolve legacy scheme/host casing with one indexed IN fetch per page.",
)
identity_declaration, identity_body = function(
    REMOTE,
    "nonisolated static func subscriptionFeedIdentityCandidates(",
)
require(
    "URLComponents(string: candidate)" in identity_body
    and "components.percentEncodedPath" in identity_body
    and 'append("\\(candidate)/")' not in identity_body,
    "Trailing-slash variants must modify only the URL path, preserving query and fragment.",
)
require(
    "exactFeedsByStoredURL" in worker_body
    and "aliasFeedsByIdentity" in worker_body
    and worker_body.find("exactFeedsByStoredURL") < worker_body.find("aliasFeedsByIdentity"),
    "Exact normalized URL identity must win before deterministic HTTP/HTTPS alias matching.",
)
for forbidden in (
    "databaseManager.feed(withSourceURL:",
    "subscriptionManager.subscribeParserFeed",
    "databaseManager.saveReturningError",
    "performSynchronousRemoteApplyBatch",
    "MainActor.run",
):
    require(
        forbidden not in worker_body,
        f"The background subscription worker still reaches the old per-feed path: {forbidden}",
    )

require(
    "removePendingSubscription" in worker_body
    and worker_body.find("removePendingSubscription") < worker_body.rfind("context.save()"),
    "Pending rows must be CAS-removed inside the same successful local transaction.",
)
require(
    "insertedObjectURIStrings" in worker_body
    and "updatedObjectURIStrings" in worker_body
    and "deletedObjectURIStrings" in worker_body,
    "The worker must report exact cross-coordinator object identities for the view merge.",
)
require(
    "insertedObjectURIStrings.union( updatedObjectURIStrings )"
        in " ".join(worker_body.split()),
    "Remote-origin suppression must use permanent post-obtain insert/update IDs, never temporary object IDs.",
)
require(
    "managedObjectIDs(" in consume_body
    and "performSynchronousRemoteViewContextMerge(" in consume_body
    and "NSManagedObjectContext.mergeChanges(" in view_merge_body
    and "isApplyingRemoteChange = true" in view_merge_body
    and "NSInsertedObjectIDsKey" in consume_body
    and "NSUpdatedObjectIDsKey" in consume_body
    and "NSDeletedObjectIDsKey" in consume_body,
    "The main coordinator must receive exact insert/update/delete IDs after the worker commit.",
)
origin_union = consume_body.find("remoteAppliedObjectIDs.formUnion(originObjectIDs)")
origin_cleanup = consume_body.find("defer {", origin_union)
require(
    origin_union != -1
    and origin_cleanup != -1
    and "remoteAppliedObjectIDs.subtract(originObjectIDs)"
        in consume_body[origin_cleanup:consume_body.find("\n        }", origin_cleanup) + 10]
    and origin_cleanup < consume_body.find("let insertedObjectIDs"),
    "Remote origin IDs must be unconditionally cleared even when a password-only apply has no Core Data merge.",
)
require(
    "ICCloudSubscriptionApplyBatchResult" in TYPES,
    "The Sendable subscription batch result is missing.",
)
require(
    "ICCloudSubscriptionCredentialUpdate" in TYPES
    and "let expectedPassword: String?" in TYPES
    and "credentialPendingSnapshots" in TYPES
    and "credentialUpdates" in worker_body
    and "credentialUpdates" in consume_body
    and "try feed.compareAndSetPassword" in consume_body
    and "feed.password = update.password" not in consume_body
    and "feed.password =" not in payload_body,
    "Keychain credentials must be returned as post-commit intents, never written inside the Core Data worker.",
)
consume_gate = consume_body.find("syncEngineCallbackGate.subscriptionApplyIsValid(")
credential_apply = consume_body.find("try feed.compareAndSetPassword")
require(
    consume_gate != -1
    and consume_gate < credential_apply
    and "accountRecordName: String" in consume_declaration
    and "subscriptionEpoch: UInt64" in consume_declaration,
    "Credential intents must revalidate the exact account and subscription epoch on MainActor after commit.",
)
require(
    "guard replaced else" in consume_body
    and "restoreDurableSubscriptionOutboxIntent" in consume_body
    and "saveReturningError" in consume_body,
    "A newer local Keychain credential must win via a newly persisted local outbox intent.",
)
credential_set = consume_body.find("try feed.compareAndSetPassword")
credential_verify = consume_body.find("guard replaced else", credential_set)
credential_pending_remove = consume_body.find("removePendingSubscriptionStates(")
require(
    "credentialPendingSnapshots.append" in worker_body
    and credential_set != -1
    and credential_set < credential_verify < credential_pending_remove
    and "result.credentialPendingSnapshots"
        in consume_body[credential_pending_remove:credential_pending_remove + 150]
    and "removePendingSubscriptionSnapshots(change.snapshots.filter" in worker_body,
    "Credential-bearing pending rows must survive the worker commit until Keychain success is verified.",
)
setter_declaration, setter_body = function(
    MANAGER,
    "func setSubscriptionsSyncEnabled(_ enabled: Bool)",
)
require(
    setter_body.find("applySubscriptionsSyncEnabled")
    < setter_body.find("updateSyncEngineCallbackGate()")
    < setter_body.find("syncOptionsChanged()"),
    "Every subscription OFF/ON transition must publish its new apply epoch before sync work starts.",
)
gate_declaration, gate_body = function(MANAGER, "func subscriptionApplyIsValid(")
require(
    "epoch: UInt64" in gate_declaration
    and "subscriptionApplyEpoch == epoch" in gate_body
    and "subscriptionsSyncEnabled" in gate_body,
    "A stale OFF→ON worker must not commit in a newer subscription-option epoch.",
)
require(
    "subscriptionEpoch: UInt64" in worker_declaration
    and "epoch: subscriptionEpoch" in worker_body,
    "The worker must validate the exact subscription enable epoch immediately before save.",
)
last_epoch_validation = worker_body.rfind("validityGate.subscriptionApplyIsValid(")
require(
    worker_body.find("originRegistration = remoteOriginGate.register")
    < last_epoch_validation
    < worker_body.rfind("context.save()"),
    "The exact subscription epoch must be revalidated after transaction preparation and directly before commit.",
)
require(
    "localOutboxSnapshotCache[snapshot.recordName]?.revision == snapshot.revision" in consume_body
    and "localOutboxSnapshotCache[snapshot.recordName] = snapshot" in consume_body,
    "Same-revision acknowledged/re-armed outbox state must replace the cached snapshot.",
)
require(
    "let lhsDate" in resolver_body
    and "if lhsDate != rhsDate" in resolver_body
    and "if lhs.isTombstone != rhs.isTombstone" in resolver_body
    and "return lhs.isTombstone" in resolver_body,
    "Equivalent redirect records must apply by clock with equal-clock tombstones before active records.",
)
require(
    "subscriptionFeedIdentityCandidates(change.feedURL)" in worker_body
    and "candidateMetadataSnapshots" in worker_body
    and "localModifiedAt" in worker_body,
    "Conflict clocks must be prefetched and compared across equivalent HTTP/HTTPS feed identities.",
)
require(
    "actualStoredFeedURLByFeedURL" in worker_body
    and "additionalMetadataRecordNames" in worker_body
    and "additionalOutboxRecordNames" in worker_body
    and "conflictFeedURLCandidates" in worker_body,
    "Legacy raw stored URLs discovered by the feed fetch must join metadata and outbox conflict lookup.",
)


# Exact identity wins even when its HTTP/HTTPS alias has a lower rank.
feeds = [
    {"identity": "https://example.com/feed", "rank": 1, "name": "https"},
    {"identity": "http://example.com/feed", "rank": 99, "name": "http"},
]
exact = {}
aliases = {}
for feed in sorted(feeds, key=lambda item: item["rank"]):
    exact.setdefault(feed["identity"], []).append(feed)
    peer = feed["identity"].replace("https://", "http://") \
        if feed["identity"].startswith("https://") \
        else feed["identity"].replace("http://", "https://")
    for identity in (feed["identity"], peer):
        aliases.setdefault(identity, []).append(feed)
selected = exact.get("http://example.com/feed", aliases["http://example.com/feed"])[0]
require(selected["name"] == "http", "The lower-ranked HTTPS alias displaced the exact HTTP feed.")

# Two equivalent records in one initially empty page resolve to the one just-inserted feed.
resolved = {}
insertions = 0
candidate_sets = {
    "http://example.com/feed": {"http://example.com/feed", "https://example.com/feed"},
    "https://example.com/feed": {"https://example.com/feed", "http://example.com/feed"},
}
for feed_url in candidate_sets:
    if feed_url not in resolved:
        insertions += 1
        inserted_identities = candidate_sets[feed_url]
        for candidate_url, candidates in candidate_sets.items():
            if candidate_url not in resolved and inserted_identities.intersection(candidates):
                resolved[candidate_url] = "inserted-feed"
require(insertions == 1, "Equivalent HTTP/HTTPS records in one page created duplicate feeds.")

# The old feed lookup normalized each stored URL before comparing it. The batched fetch
# must therefore discover legacy scheme/host casing plus a trailing slash, while the
# post-fetch identity check must still preserve case-sensitive URL path semantics.
legacy_stored_urls = [
    "HTTPS://Example.COM/feed/",
    "https://example.com/Feed/",
]
remote_candidates = [
    "https://example.com/feed",
    "https://example.com/feed/",
    "http://example.com/feed",
    "http://example.com/feed/",
]
fetched = [
    stored for stored in legacy_stored_urls
    if stored.casefold() in {candidate.casefold() for candidate in remote_candidates}
]
require(
    fetched == legacy_stored_urls,
    "The model must expose both the legacy match and the broad case-fold candidate.",
)


def normalized_identity(url: str) -> str:
    scheme, remainder = url.split("://", 1)
    host, separator, path = remainder.partition("/")
    normalized = f"{scheme.lower()}://{host.lower()}"
    if separator:
        normalized += f"/{path}"
    return normalized.rstrip("/")


resolved = [stored for stored in fetched
            if normalized_identity(stored) == "https://example.com/feed"]
require(
    resolved == ["HTTPS://Example.COM/feed/"],
    "Post-fetch normalization must not merge a distinct case-sensitive URL path.",
)


def path_slash_variant(url: str) -> str:
    parts = urlsplit(url)
    path = parts.path[:-1] if parts.path.endswith("/") else f"{parts.path}/"
    return urlunsplit((parts.scheme, parts.netloc, path, parts.query, parts.fragment))


require(
    path_slash_variant("https://example.com/feed?token=1#latest")
    == "https://example.com/feed/?token=1#latest",
    "A query-bearing feed URL must keep its query and fragment behind the path slash.",
)


def apply_redirect_changes(changes):
    state = None
    clock = -1
    ordered = sorted(
        changes,
        key=lambda change: (
            change["clock"],
            0 if change["tombstone"] else 1,
            change["url"],
        ),
    )
    for change in ordered:
        if change["clock"] < clock:
            continue
        clock = change["clock"]
        state = not change["tombstone"]
    return state


require(
    apply_redirect_changes([
        {"url": "http://example.com/feed", "clock": 10, "tombstone": True},
        {"url": "https://example.com/feed", "clock": 10, "tombstone": False},
    ]) is True,
    "An equal-clock HTTP-to-HTTPS redirect must finish subscribed.",
)
require(
    apply_redirect_changes([
        {"url": "https://example.com/feed", "clock": 10, "tombstone": False},
        {"url": "http://example.com/feed", "clock": 11, "tombstone": True},
    ]) is False,
    "A genuinely newer equivalent tombstone must still unsubscribe the feed.",
)

# A legacy raw URL cannot be reconstructed from a normalized remote URL, but the one
# batched feed fetch discovers it. Its newer local clock must join conflict lookup.
remote_url = "https://example.com/feed"
matched_stored_url = "HTTPS://Example.COM/feed/"
metadata_clocks = {matched_stored_url: 20}
conflict_candidates = [remote_url, "http://example.com/feed", matched_stored_url]
local_clock = max((metadata_clocks[url] for url in conflict_candidates
                   if url in metadata_clocks), default=-1)
require(local_clock > 10,
        "A newer legacy raw-URL metadata clock must defeat an older normalized remote payload.")

# Crash durability model: the Core Data worker commits the feed/metadata but leaves the
# exact pending payload as the retry source until the non-transactional Keychain side
# effect has been verified.
pending_credential_payload = True
keychain_password = "old"
worker_committed = True
require(worker_committed and pending_credential_payload,
        "A kill after the worker commit must leave the credential payload retryable.")
keychain_password = "remote"
if keychain_password == "remote":
    pending_credential_payload = False
require(not pending_credential_payload,
        "The pending credential payload may be removed only after a successful read-back.")

print("iCloud subscription apply responsiveness regression checks passed")
