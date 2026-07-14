#!/usr/bin/env python3
"""Pins list continuous playback via end-of-episode check (User-Entscheid 08.07.2026).

Old behavior: starting an episode from a list with continuousPlayback erased the whole
play-next queue and pre-filled it with the next 10 list episodes (TestFlight feedback
26.05.: "Abspielliste füllt sich automatisch?"). New behavior: the list is remembered as
playback source; AudioSession.nextPlayableEpisode continues the list at end of episode.
Priority stays: play-next queue > source list > per-feed continuous setting.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


list_controller = (ROOT / "Classes" / "ListEpisodesTableViewController.m").read_text()
audio_session = (ROOT / "Classes" / "AudioSession.m").read_text()
audio_header = (ROOT / "Classes" / "AudioSession.h").read_text()

# --- The list controller must not manipulate the queue anymore ------------------------
play_combo = list_controller.split("- (void) playComboButtonAction:", 1)[1].split("\n- (", 1)[0]
require(
    "eraseAllEpisodesFromUpNext" not in play_combo and "appendToUpNext" not in play_combo,
    "Starting playback from a list must not touch the play-next queue.",
)
require(
    "notePlaybackSourceEpisodeList:episodeList" in play_combo
    and play_combo.find("notePlaybackSourceEpisodeList") < play_combo.find("[super playComboButtonAction:button]"),
    "Starting playback from a list must arm the source BEFORE super (cellular alert defers the play).",
)

# --- AudioSession continues the source list at end of episode -------------------------
require(
    "@property (nonatomic, copy, readonly) NSString* sourceEpisodeListUID;" in audio_header
    and "notePlaybackSourceEpisodeList:" in audio_header,
    "AudioSession must own the source list; screens only arm it via notePlaybackSourceEpisodeList:.",
)

# playEpisode: must resolve the source: armed list sticks only if the episode belongs to
# it; without an arm the source survives only while the episode is still a list member
# (auto-continuation) and clears otherwise (no eternal stickiness from default lists).
resolve = audio_session.split("- (void) _resolvePlaybackSourceListForEpisode:", 1)[1].split("\n- (", 1)[0]
require(
    "pendingSourceEpisodeListUID" in resolve
    and resolve.count("evaluatesEpisodeNow:anEpisode") >= 2
    and "self.sourceEpisodeListUID = nil" in resolve,
    "playEpisode must validate both the armed and the surviving source via list membership.",
)
audio_implementation = audio_session.split("@implementation AudioSession", 1)[1]
play_core = audio_implementation.split("- (void) _playEpisode:(CDEpisode*)anEpisode", 1)[1].split("\n- (", 1)[0]
require(
    "_resolvePlaybackSourceListForEpisode:anEpisode" in play_core,
    "The shared play core must resolve the playback source list on every start.",
)

next_playable = audio_session.split("- (CDEpisode*) nextPlayableEpisode", 1)[1].split("\n- (", 1)[0]
queue_idx = next_playable.find("[self playlist]")
list_idx = next_playable.find("sourceEpisodeListUID")
feed_idx = next_playable.find("ContinuousPlayFromFeed")
require(
    0 <= queue_idx < list_idx < feed_idx,
    "nextPlayableEpisode must check queue first, then source list, then feed setting.",
)
require(
    "sourceList.continuousPlayback" in next_playable,
    "The source list must only continue when its continuousPlayback flag is on.",
)
require(
    "(currentIdx != NSNotFound) ? currentIdx + 1 : 0" in next_playable,
    "A finished episode that dropped out of a dynamic list must fall back to the first playable one.",
)
require(
    "!candidate.consumed" in next_playable and "preferedMedium" in next_playable,
    "List continuation must skip consumed episodes and episodes without media.",
)

# --- Source list survives app restarts -------------------------------------------------
require(
    'kPlaybackStateSourceList = @"PlaybackSourceList"' in audio_session,
    "The playback source list must have a persistence key.",
)
require(
    "setObject:self.sourceEpisodeListUID forKey:kPlaybackStateSourceList" in audio_session
    and "stringForKey:kPlaybackStateSourceList" in audio_session,
    "The playback source list must be saved and restored with the playback state.",
)

print("list continuous playback regression checks passed")
