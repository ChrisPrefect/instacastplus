#!/usr/bin/env python3
"""Pins episode initial backfill to a complete remote fetch before first upload."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


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
    raise AssertionError(f"Unterminated method: {signature}")


# A different/new target account has no proven episode merge. Its first operation must
# therefore be a complete fetch. Arm that durable gate before the account callback gate
# opens, otherwise continueEnabledSyncAfterAccountVerification queues the local library
# and the send-only backfill optimization overwrites target-account state first.
reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")
remote_first = reconcile.find("prepareInitialEpisodeFetchBeforeUploadIfNeeded")
verification = reconcile.find("setICloudAccountIdentityVerified(true)")
require(remote_first != -1 and remote_first < verification,
        "A new/different CloudKit account must close the episode upload gate before verification opens sends.")

# The same invariant applies when the user first enables episode sync while the current
# account is already verified: close the fetch gate while episode sends are still disabled.
episode_enable = method_body(MANAGER, "private func applyEpisodesSyncEnabled")
remote_first = episode_enable.find("prepareInitialEpisodeFetchBeforeUploadIfNeeded")
enable_commit = episode_enable.find("defaults.set(enabled, forKey: ICiCloudSyncEpisodesEnabled)")
require(remote_first != -1 and remote_first < enable_commit,
        "First episode participation must arm remote-first before the episode send gate opens.")

prepare = method_body(MANAGER, "func prepareInitialBackfillsForVerifiedAccount")
episode_prepare = prepare.split("if episodesSyncEnabled", 1)[1].split("if subscriptionsSyncEnabled", 1)[0]
remote_first = episode_prepare.find("prepareInitialEpisodeFetchBeforeUploadIfNeeded")
cursor_reset = episode_prepare.find("resetInitialEpisodeBackfillCursor()")
require(remote_first != -1 and cursor_reset != -1 and remote_first < cursor_reset,
        "Any newly created episode backfill must be fetch-gated before its upload cursor is reset to zero.")

gate = method_body(MANAGER, "func prepareInitialEpisodeFetchBeforeUploadIfNeeded")
for token in [
    "initialEpisodeBackfillCompletedAccountKey",
    "initialEpisodeBackfillAccountKey",
    "initialEpisodeBackfillCheckpointKey",
    "initialEpisodeBackfillOffsetKey",
    "initialBackfillFetchBeforeUploadCategoriesKey",
    "initialBackfillFetchBeforeUploadAccountKey",
    'categories.insert("episodes")',
]:
    require(token in gate, f"Episode remote-first gate is missing lifecycle evidence: {token}")

# Do not broaden this fix to subscriptions: their independent durable incomplete-fetch
# gate controls destructive replay and is covered by its own regression test.
subscription_enable = method_body(MANAGER, "private func applySubscriptionsSyncEnabled")
require("prepareInitialEpisodeFetchBeforeUploadIfNeeded" not in subscription_enable,
        "The episode remote-first lifecycle fix must not change subscription enable semantics.")


def needs_remote_first(account, started_account, completed_account, cursor_exists):
    if completed_account == account:
        return False
    return started_account != account or not cursor_exists


require(needs_remote_first("B", "A", "A", False),
        "Account A completion is not proof that target account B was fetched.")
require(needs_remote_first("A", None, None, False),
        "First episode participation must merge a possibly existing cloud library before upload.")
require(not needs_remote_first("A", "A", None, True),
        "A same-account upload that already passed its fetch gate must resume without another fetch.")
require(not needs_remote_first("A", "A", "A", False),
        "A completed same-account backfill must remain a no-op after OFF/ON.")


print("iCloud episode account-switch remote-first regression checks passed")
