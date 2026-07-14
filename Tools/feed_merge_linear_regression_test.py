#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


merge = method_body("- (NSArray*) _mergeLocalFeed:")
require("localEpisodesByGUID" in merge and "localEpisodesByObjectHash" in merge,
        "Feed merge must build direct GUID and object-hash indexes in its one local pass.")

remote_loop = merge.split("for (ICEpisode* remoteEpisode in remoteEpisodes)", 1)[1]
require("for (CDEpisode *localEp in localEpisodes)" not in remote_loop,
        "Remote episodes must never rescan every local episode (O(remote × local)).")
require("localEpisodesByGUID[remoteEpisode.guid]" in remote_loop
        and "localEpisodesByObjectHash[remoteEpisode.objectHash]" in remote_loop,
        "Existing/stub episodes must resolve by constant-time GUID, then hash lookup.")

require("newestLocalEpisodeDate" in merge and "[localFeed sortedEpisodes]" not in merge,
        "The existing local pass must track the newest date instead of sorting/materializing the feed again.")

new_episode_block = remote_loop.split("CDEpisode* newPersistentEpisode", 1)[1]
require("localEpisodesByGUID[remoteEpisode.guid] = newPersistentEpisode" in new_episode_block
        and "localEpisodesByObjectHash[newPersistentEpisode.objectHash] = newPersistentEpisode" in new_episode_block,
        "Newly inserted episodes must join both indexes so duplicate remote entries stay linear and deterministic.")

print("Linear feed merge regression checks passed")
