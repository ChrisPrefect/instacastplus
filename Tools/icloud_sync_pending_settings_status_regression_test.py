#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
REMOTE_APPLY = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
LOCALIZATIONS = [
    (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text(),
    (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text(),
]


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


completion_gate = method_body(METADATA, "func markSyncCompletedIfFinished")
require(
    "hasPendingInitialSettingsChoice" in completion_gate
    and completion_gate.find("hasPendingInitialSettingsChoice")
    < completion_gate.find("markSyncCompleted()"),
    "A parked initial settings choice must block the terminal 'sync complete' state.",
)
require(
    "clearSyncActivity()" in completion_gate
    and 'NSLocalizedString("Choose which iCloud settings should be used."' in completion_gate
    and "postStateChanged()" in completion_gate,
    "The pending-choice state must stop stale progress and show an actionable status.",
)

adopt_choice = method_body(REMOTE_APPLY, "@objc func resolveInitialSettingsAdoptingCloud")
require(
    adopt_choice.find("setSyncMetadata(nil, forKey: Self.pendingInitialSettingsPayloadKey)")
    < adopt_choice.find("markSyncCompletedIfFinished()"),
    "Adopting the cloud settings must re-evaluate completion only after releasing the choice gate.",
)

publish_choice = method_body(REMOTE_APPLY, "@objc func resolveInitialSettingsPublishingLocal")
require(
    "addPendingSave(appSettingsRecordID())" in publish_choice
    and "markSyncCompletedIfFinished()" not in publish_choice,
    "Publishing local settings must wait for the queued CloudKit save before completing.",
)

for localization in LOCALIZATIONS:
    require(
        '"Choose which iCloud settings should be used." =' in localization,
        "The pending settings choice status must be localized in German and English.",
    )


print("iCloud pending-settings status regression checks passed")
