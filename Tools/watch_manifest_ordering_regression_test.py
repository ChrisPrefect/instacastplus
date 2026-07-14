#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PHONE = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()
WATCH_CONNECTIVITY = (ROOT / "InstacastWatch" / "WatchConnectivityController.swift").read_text()
WATCH_STORE = (ROOT / "InstacastWatch" / "WatchManifestStore.swift").read_text()


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


revision = method_body(PHONE, "- (NSNumber*)_nextManifestRevision")
require("ICAppleWatchManifestRevisionKey" in revision
        and "previousRevision + 1" in revision,
        "The phone needs a persisted monotonic manifest revision across delivery channels.")

replace = method_body(PHONE, "- (void)_sendCurrentManifestAndNotify")
remove_wrapper = method_body(PHONE, "- (void)removeEpisodeFromWatch:")
remove = method_body(PHONE, "- (void)removeEpisodeStateFromWatch:")
require("removeEpisodeStateFromWatch" in remove_wrapper,
        "Episode-based removal must delegate to the state-identity removal contract.")
for body, label in [(replace, "replace"), (remove, "remove")]:
    require('"manifestRevision"' in body and "_nextManifestRevision" in body,
            f"Every logical manifest {label} must carry a revision.")
require("_sendCurrentManifestAndNotify" in remove,
        "Removing an episode must also replace the durable application context so a reinstalled Watch cannot restore it.")

current_state = method_body(PHONE, "- (void)_sendCurrentStateMessage:")
require("session.applicationContext" in current_state
        and "phonePlaybackState" in current_state
        and "updateApplicationContext:payload" not in current_state,
        "Phone playback updates must augment the stored manifest context, never replace it.")

should_apply = method_body(WATCH_STORE, "func shouldApplyManifestRevision")
persist_archive = method_body(WATCH_STORE, "private func persistEpisodesNow(")
require("lastAppliedManifestRevision" in should_apply and ">" in should_apply,
        "The Watch must reject duplicate or older manifest operations.")
require("WatchManifestArchive" in persist_archive and
        persist_archive.find("WatchManifestArchive") < persist_archive.find("persistenceWriter.persist") and
        persist_archive.find("persistenceWriter.persist") < persist_archive.find("recordCommittedArchive"),
        "The accepted revision must be atomically archived with episodes before it becomes active.")

handle = method_body(WATCH_CONNECTIVITY, "private func handle(payload:")
replace_block = handle.split('case "manifest.replace"', 1)[1].split("case ", 1)[0]
replace_apply = method_body(WATCH_CONNECTIVITY, "private func applyManifestReplace(")
require("applyManifestReplace" in replace_block
        and "shouldApplyManifestRevision" in replace_apply
        and "manifestRevision: revision" in replace_apply,
        "Legacy and file manifest replacements must share the revision gate and commit path.")
for case_name in ['case "manifest.upsertEpisodes"', 'case "manifest.removeEpisodes"']:
    block = handle.split(case_name, 1)[1].split("case ", 1)[0]
    require("shouldApplyManifestRevision" in block
            and "manifestRevision: revision" in block,
            f"Watch handler must gate and commit revision for {case_name}.")
require("phonePlaybackState" in handle,
        "A manifest application context must also deliver its nested latest phone playback state.")

activation = method_body(WATCH_CONNECTIVITY, "nonisolated func session(_ session: WCSession, activationDidCompleteWith")
require('self.send(type: "watch.requestManifest"' in activation,
        "A newly activated or reinstalled Watch must explicitly request the current manifest.")

phone_handle = method_body(PHONE, "- (void)_handleIncomingPayloadOnMainThread:")
request_block = phone_handle.split('if ([type isEqualToString:@"watch.requestManifest"])', 1)
require(len(request_block) == 2 and "syncNow" in request_block[1].split("else if", 1)[0],
        "The phone must answer a Watch activation request with its current manifest.")

print("Watch manifest ordering regression checks passed")
