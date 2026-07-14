#!/usr/bin/env python3
"""Pins revision-owned, monotonic Watch capability negotiation.

A delayed manifest descriptor/replacement may arrive after a newer manifest.  Its
legacy protocol value must neither take effect before the manifest revision gate nor
downgrade capabilities already negotiated with the current phone build.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "InstacastWatch" / "WatchConnectivityController.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function body: {signature}")


advance = function_body(SOURCE, "private func advancePhoneWatchEventProtocolVersion(")
require(
    "phoneWatchEventProtocolVersion = max(" in advance
    and "phoneWatchEventProtocolVersion," in advance
    and "max(1, version)" in advance,
    "Phone capability negotiation must be monotonic; a delayed legacy payload may never "
    "lower a capability already observed from a newer phone manifest.",
)

handle = function_body(SOURCE, "private func handle(payload:")
before_switch = handle.split("switch type", 1)[0]
require(
    "phoneWatchEventProtocolVersion" not in before_switch,
    "A manifest descriptor/replacement must not mutate capabilities before its revision is gated "
    "and durably committed.",
)
file_available = handle.split('case "manifest.fileAvailable"', 1)[1].split("case ", 1)[0]
require(
    "phoneWatchEventProtocolVersion" not in file_available
    and "advancePhoneWatchEventProtocolVersion" not in file_available,
    "manifest.fileAvailable is only a descriptor; its protocol version is not authoritative until "
    "the staged file's revision commits.",
)

apply_replace = function_body(SOURCE, "private func applyManifestReplace(")
replace = apply_replace.find("try await WatchDownloadManager.shared.replaceManifest")
advance_version = apply_replace.find("advancePhoneWatchEventProtocolVersion")
acknowledge = apply_replace.find("acknowledgeManifest")
require(
    -1 not in (replace, advance_version, acknowledge)
    and replace < advance_version < acknowledge,
    "The accepted protocol version may advance only after the matching manifest revision commits "
    "and before its acknowledgement is emitted.",
)
committed_duplicate = apply_replace.split(
    "else if WatchManifestStore.shared.isManifestRevisionCommitted(revision)", 1
)[1]
require(
    "advancePhoneWatchEventProtocolVersion" not in committed_duplicate,
    "An older already-committed replacement must only be acknowledged; its stale capability value "
    "must not be renegotiated.",
)

activation = function_body(SOURCE, "activationDidCompleteWith")
require(
    "advancePhoneWatchEventProtocolVersion(to: eventProtocolVersion)" in activation
    and activation.find("advancePhoneWatchEventProtocolVersion(to: eventProtocolVersion)")
    < activation.find("finalizePendingRemovalsAfterConnectivityActivation"),
    "Activation must restore the current application-context capability monotonically before "
    "choosing legacy versus batched deletion acknowledgements.",
)


def advance_model(current: int, incoming: int, revision_is_accepted: bool) -> int:
    if not revision_is_accepted:
        return current
    return max(current, max(1, incoming))


require(advance_model(2, 1, False) == 2, "A stale revision downgraded the negotiated protocol.")
require(advance_model(2, 1, True) == 2, "Even an accepted legacy value must not downgrade capability.")
require(advance_model(1, 2, True) == 2, "A newly committed current manifest must advance capability.")

print("Watch protocol capability/revision regression checks passed")
