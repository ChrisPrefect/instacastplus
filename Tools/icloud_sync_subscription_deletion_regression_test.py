#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature, next_marker=None):
    # Brace-matching extraction: the old "cut at the next private member" heuristic broke
    # when the manager was split into files and member access became internal.
    require(signature in source, f"{signature} is missing.")
    start = source.find(signature)
    brace = source.find("{", start)
    require(brace != -1, f"{signature} has no body.")
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated body: {signature}")


MANAGER = "\n".join(read("Classes/" + _n) for _n in ["ICiCloudSyncManager.swift", "ICiCloudSyncTypes.swift", "ICiCloudSyncManager+EngineRecords.swift", "ICiCloudSyncManager+RemoteApply.swift", "ICiCloudSyncManager+LocalChanges.swift", "ICiCloudSyncManager+Metadata.swift"])

# Enabling subscription sync must NEVER delete local subscriptions. Deletions that piled
# up in the cloud while sync was off arrive in the catch-up fetch and must be suppressed
# until the first complete fetch has run; only live deletions after that are applied.
enable = method_body(MANAGER, "@objc func setSubscriptionsSyncEnabled", next_marker="\n    @objc func ")
require('defaults.set(true, forKey: Self.suppressSubscriptionDeletionsKey)' in enable,
        "Enabling subscription sync must arm the deletion-suppression flag.")
require('defaults.removeObject(forKey: Self.suppressSubscriptionDeletionsKey)' in enable,
        "Disabling subscription sync must clear the deletion-suppression flag.")

deletion = method_body(MANAGER, "func applyRemoteDeletion")
require("suppressSubscriptionDeletionsKey" in deletion,
        "Remote subscription deletions must respect the suppression flag.")
require("unsubscribeFeed" in deletion,
        "Live remote deletions must still unsubscribe the local feed.")

event_handler = method_body(MANAGER, "func handleEventOnMain")
require("suppressSubscriptionDeletionsKey" in event_handler and "didFetchChanges" in event_handler,
        "The suppression flag must be cleared only after a complete fetch (didFetchChanges), not after send-only runs.")

# Frozen-when-off invariants: nothing may be applied while a category is disabled.
pending_episodes = method_body(MANAGER, "func applyPendingEpisodeStates")
require("guard episodesSyncEnabled else { return }" in pending_episodes,
        "Pending episode states must not be applied while episode sync is off.")
pending_subscriptions = method_body(MANAGER, "func applyPendingSubscriptions")
require("guard subscriptionsSyncEnabled else { return }" in pending_subscriptions,
        "Pending subscriptions must not be applied (or subscribed over the network) while subscription sync is off.")
