#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "InstacastWatch/WatchDownloadManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def block_body(source: str, marker: str) -> str:
    start = source.find(marker)
    require(start != -1, f"Missing block: {marker}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing opening brace: {marker}")
    depth = 0
    for index in range(brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated block: {marker}")


reconcile = block_body(SOURCE, "private func reconcileManifestWithDownloadTasks(")
resolution_loop = block_body(reconcile, "for resolution in fileResolutions")

require(
    "WatchDiagnostics.log" not in resolution_loop,
    "Reconcile must not send a WatchConnectivity diagnostic for every resolved file. "
    "Large manifests otherwise create an unbounded MainActor/transport burst.",
)

require(
    reconcile.count('WatchDiagnostics.log("download-reconcile-pathRerooted"') == 1
    and reconcile.count('WatchDiagnostics.log("download-reconcile-localFileMissing"') == 1,
    "Reconcile should emit at most one aggregate diagnostic for rerooted files and one for "
    "missing files.",
)

require(
    "rerootedURLsByHash.count" in reconcile
    and "missingLocalFilesByHash.count" in reconcile
    and "reconcileDiagnosticSampleLimit" in reconcile
    and "sampleEpisodeHashes" in reconcile,
    "Aggregate reconcile diagnostics need exact category counts and a bounded episode-hash sample.",
)

require(
    reconcile.find("try await WatchManifestStore.shared.updateEpisodes")
    < reconcile.find('WatchDiagnostics.log("download-reconcile-pathRerooted"')
    and reconcile.find("try await WatchManifestStore.shared.updateEpisodes")
    < reconcile.find('WatchDiagnostics.log("download-reconcile-localFileMissing"'),
    "Reconcile diagnostics must describe a durably committed repair, not work that may still fail.",
)

print("Watch reconcile diagnostic batching regression checks passed.")
