#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONNECTIVITY = (ROOT / "InstacastWatch" / "WatchConnectivityController.swift").read_text()
DOWNLOADS = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()
PLAYER = (ROOT / "InstacastWatch" / "WatchPlayerController.swift").read_text()


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


report = method_body(CONNECTIVITY, "func reportTerminalDownloadState")
signature = method_body(CONNECTIVITY, "private func terminalStateSignature(")
require(
    "reportedTerminalStateSignatures" in CONNECTIVITY
    and "terminalStateSignature" in report
    and "episode.selectionIdentifier" in signature,
    "Terminal Watch events need a durable, selection-safe delivery signature.",
)
require(
    "delivery: .durable" in report
    and 'payload["terminalStateSignature"] = terminalStateSignature' in report
    and "inFlightTerminalStateIdentifiers.insert" in report
    and "reportedTerminalStateSignatures[episode.episodeHash] = terminalStateSignature" not in report,
    "Enqueueing transferUserInfo is not delivery: a terminal event must remain in-flight until "
    "WatchConnectivity reports that the transfer actually finished.",
)

finish = method_body(CONNECTIVITY, "didFinish userInfoTransfer: WCSessionUserInfoTransfer")
require(
    'userInfoTransfer.userInfo["episodeHash"]' in finish
    and 'userInfoTransfer.userInfo["terminalStateSignature"]' in finish
    and "Task { @MainActor" in finish
    and "completeTerminalStateTransfer" in finish,
    "The WCSession user-info completion callback must identify terminal transfers and hop "
    "explicitly to the MainActor.",
)

complete = method_body(CONNECTIVITY, "private func completeTerminalStateTransfer(")
require(
    "inFlightTerminalStateIdentifiers.remove" in complete
    and "if let errorDescription" in complete
    and "reportTerminalDownloadState" in complete
    and "reportedTerminalStateSignatures[episodeHash] = terminalStateSignature" in complete
    and complete.find("if let errorDescription")
    < complete.find("reportedTerminalStateSignatures[episodeHash] = terminalStateSignature"),
    "Failed terminal transfers must become retryable; only a successful WCSession completion "
    "may persist the delivered signature.",
)

activation = method_body(CONNECTIVITY, "nonisolated func session(_ session: WCSession, activationDidCompleteWith")
require(
    "await WatchManifestStore.shared.load()" in activation
    and "restoreOutstandingTerminalStateTransfers" in activation
    and "replayPendingTerminalDownloadStates" in activation
    and activation.find("await WatchManifestStore.shared.load()")
    < activation.find("restoreOutstandingTerminalStateTransfers")
    < activation.find("replayPendingTerminalDownloadStates"),
    "Connectivity activation must replay unreported terminal states from the loaded durable manifest.",
)

start = method_body(DOWNLOADS, "private func beginPreparedDownload(")
require(
    "clearReportedTerminalDownloadState" in start,
    "A retry must clear the prior terminal signature when its revalidated network task actually "
    "starts so an identical later result is reported again.",
)

clear = method_body(CONNECTIVITY, "func clearReportedTerminalDownloadState")
require(
    "outstandingUserInfoTransfers" in clear
    and 'transfer.userInfo["episodeHash"]' in clear
    and 'transfer.userInfo["terminalStateSignature"]' in clear
    and "transfer.cancel()" in clear,
    "Starting a retry must cancel older terminal transfers for that episode; otherwise a stale "
    "lower-revision event can arrive after the new queued event and suppress an identical result.",
)

finished = method_body(DOWNLOADS, "private func processFinishedDownload")
failed = method_body(DOWNLOADS, "private func markDownloadFailed")
evicted = method_body(DOWNLOADS, "private func sendStorageEviction")
playback_failed = method_body(PLAYER, "private func markEpisodePlaybackFailed")
for name, body in (
    ("download completion", finished),
    ("download failure", failed),
    ("storage eviction", evicted),
    ("playback validation failure", playback_failed),
):
    require(
        "reportTerminalDownloadState" in body,
        f"{name} must use the replayable terminal-state transport.",
    )


print("Watch terminal-event replay regression checks passed")
