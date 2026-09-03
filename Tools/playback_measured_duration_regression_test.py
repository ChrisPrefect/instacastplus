#!/usr/bin/env python3
"""Pins the single source of truth for an episode's duration.

Regression: the cell computes the remaining time from episode.duration (the feed's
itunes:duration), while the end-of-episode check compares against the AVAsset duration
and _continueOpeningAsset restarts at 0:00 once position >= episode.duration - 5. Feeds
with dynamic ad insertion deliver media that is longer than the feed promises, so an
episode showed a full ring and no remaining time, restarted at 0:00 — and still never got
the consumed flag, so it stayed in "Unplayed" forever.

The player therefore stores the measured media length when it opens an episode, and the
feed merge must not overwrite that measured value with the feed's promise again.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


playback_manager = (ROOT / "Classes" / "PlaybackManager.m").read_text()
subscription_manager = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()

# The measured length is stored where the player first knows it: ready-to-play, next to
# the lastPlayed stamp that the merge below uses as the "was measured" marker.
ready_to_play = playback_manager.split(
    "if (currentItem.status == AVPlayerItemStatusReadyToPlay", 1
)
require(len(ready_to_play) == 2, "Missing ready-to-play observer in PlaybackManager.")
ready_block = ready_to_play[1].split("[DMANAGER save];", 1)[0]

require(
    "episode.lastPlayed = [NSDate date];" in ready_block,
    "The measured duration must be stored together with the lastPlayed marker.",
)
require(
    "NSTimeInterval measuredDuration = [weakSelf duration];" in ready_block,
    "The player must read the measured media length from the loaded asset.",
)
require(
    "measuredDuration > 0 && (int32_t)measuredDuration != episode.duration" in ready_block,
    "Only a valid and actually different measured duration may be written "
    "(Core Data marks an episode as updated even for an identical value).",
)
require(
    "episode.duration = (int32_t)measuredDuration;" in ready_block,
    "The measured media length must land in episode.duration.",
)

require(
    "localEpisode.lastPlayed == nil" in subscription_manager,
    "The feed merge must not overwrite a duration the player has already measured.",
)
merge_duration = subscription_manager.split("NSInteger remoteDuration = remoteEpisode.duration;", 1)
require(len(merge_duration) == 2, "Missing duration merge in SubscriptionManager.")
merge_block = merge_duration[1].split("BOOL newer =", 1)[0]
require(
    "remoteDuration > 0" in merge_block
    and "localEpisode.lastPlayed == nil" in merge_block
    and "localEpisode.duration != (int32_t)remoteDuration" in merge_block,
    "The feed duration may only seed episodes the player has never opened.",
)

print("playback measured duration regression checks passed")
