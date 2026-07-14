#!/usr/bin/env python3
"""Pins truthful Watch manifest loading, failure, retry, and remote-repair UI state."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / "InstacastWatch" / "WatchManifestStore.swift").read_text()
VIEWS = (ROOT / "InstacastWatch" / "WatchEpisodeViews.swift").read_text()
ENGLISH = (ROOT / "InstacastWatch" / "en.lproj" / "Localizable.strings").read_text()
GERMAN = (ROOT / "InstacastWatch" / "de.lproj" / "Localizable.strings").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


require("enum WatchManifestLoadState" in STORE
        and "case loading" in STORE
        and "case loaded" in STORE
        and "case failed" in STORE
        and "@Published private(set) var loadState: WatchManifestLoadState = .loading" in STORE,
        "The Watch UI needs one published source of truth for loading, loaded, and failed states.")

load = body(STORE, "func load() async")
require("manifestLoadInProgress" in load and "withCheckedContinuation" in load,
        "Concurrent foreground/background loads must still coalesce.")
require("loadState = .loading" in load
        and "case .loaded:" in load
        and "loadState = .loaded" in load
        and "case .failed:" in load
        and "loadState = .failed" in load,
        "Retry must publish loading first, then distinguish success from read failure.")

initial_load = body(STORE, "private func performInitialLoad(")
require("expectedManifestMutationGeneration" in initial_load
        and initial_load.count("manifestMutationGeneration") >= 2
        and "return .superseded" in initial_load,
        "An older local retry must not overwrite a newer manifest received from the phone.")
failure_branch = initial_load.split("case let .failure(message):", 1)[1].split("case", 1)[0]
require("return .failed" in failure_branch
        and "loadedArchive = WatchManifestArchive" not in failure_branch,
        "A corrupt/read-failed manifest must remain a failure, never masquerade as a successful empty archive.")

commit = body(STORE, "private func recordCommittedArchive(")
require("loadState = .loaded" in commit,
        "A successful remote manifest commit must repair any earlier local-load failure.")

list_body = body(VIEWS, "var body: some View")
require("switch store.loadState" in list_body
        and "ProgressView" in list_body
        and "Episoden werden geladen…" in list_body
        and "Episoden konnten nicht geladen werden. Tippen zum Wiederholen." in list_body
        and "Task { await store.load() }" in list_body,
        "The list must show loading, a tappable retry error, and only then the true empty state.")
require(list_body.find("case .loaded") < list_body.find("if sortedEpisodeRows.isEmpty"),
        "‘Keine Episoden’ may be rendered only after a successful load.")

for key, english in (
    ("Episoden werden geladen…", "Loading Episodes…"),
    ("Episoden konnten nicht geladen werden. Tippen zum Wiederholen.",
     "Episodes could not be loaded. Tap to retry."),
):
    require(f'"{key}" = "{english}";' in ENGLISH, f"Missing English Watch localization: {key}")
    require(f'"{key}" = "{key}";' in GERMAN, f"Missing German Watch localization: {key}")


def apply_local_result(start_generation, current_generation, succeeded):
    if start_generation != current_generation:
        return "remote-wins"
    return "loaded" if succeeded else "failed"


require(apply_local_result(1, 2, False) == "remote-wins",
        "A remote commit must win against an older failing local retry.")
require(apply_local_result(1, 1, False) == "failed",
        "A genuine current read failure must remain visible and retryable.")

print("Watch manifest load-state regression checks passed")
