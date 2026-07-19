#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def source_between(source, start, end):
    require(start in source, f"{start} is missing.")
    require(end in source, f"{end} is missing.")
    return source.split(start, 1)[1].split(end, 1)[0]


def method_body(source, signature):
    require(signature in source, f"{signature} is missing.")
    return source.split(signature, 1)[1].split("\n- (", 1)[0]


PLAYBACK = read("Classes/PlaybackManager.m")

require('#import "InstacastPlus-Swift.h"' in PLAYBACK, "PlaybackManager must be able to use ICDiagnosticLogger.")
require('logEvent:@"playback-auto-skip"' in PLAYBACK, "Auto-skip playback diagnostics must use a dedicated log category.")

metadata_helper = method_body(PLAYBACK, "- (NSMutableDictionary*)_playbackDiagnosticsMetadataForEpisode:")
for key in ["episodeHash", "currentTime", "duration", "playerRate", "state", "autoSkipMarkerCount", "suppressedSkipMarker", "isAutoSkipping"]:
    require(f'@"{key}"' in metadata_helper, f"Playback auto-skip diagnostics must include {key}.")
require("episode.objectHash" in metadata_helper, "Playback auto-skip diagnostics must identify the affected episode by object hash.")

auto_skip_end = source_between(PLAYBACK, "// Handle auto skip end", "\n        \n        if (weakSelf.player.rate > 0)")
require('Auto-Skip-Ende ausgelöst' in auto_skip_end, "The auto-skip-end trigger must be logged before closing playback.")
require('Auto-Skip-Ende abgeschlossen' in auto_skip_end, "The auto-skip-end completion must be logged after the episode is saved and removed from Up Next.")
for key in ["skipEndPeriod", "skipTriggerTime", "feedSkipEndPeriod", "globalSkipEndPeriod"]:
    require(f'@"{key}"' in auto_skip_end, f"Auto-skip-end diagnostics must include {key}.")

skip_chapter = method_body(PLAYBACK, "- (void)nextTimeAfterSkipChapter:")
require('Kapitel-Skip beendet Episode' in skip_chapter, "A skip marker that finishes an episode must be logged.")
require('Kapitel-Skip springt zu Resume-Zeit' in skip_chapter, "A skip marker jump must be logged.")
for key in ["markerIndex", "skipStart", "resumeTime"]:
    require(f'@"{key}"' in skip_chapter, f"Chapter skip diagnostics must include {key}.")

finish_skip = method_body(PLAYBACK, "- (void)_finishEpisodeDueToSkip:")
require("CMTIME_IS_VALID(duration)" in finish_skip and "CMTimeGetSeconds(duration)" in finish_skip, "Chapter-skip episode finishing must not derive duration from invalid CMTime values.")
require('Kapitel-Skip-Episodenabschluss gestartet' in finish_skip, "Chapter-skip episode finishing must log before closing playback.")
require('Kapitel-Skip-Episodenabschluss gespeichert' in finish_skip, "Chapter-skip episode finishing must log after saving the consumed episode.")

compute_markers = method_body(PLAYBACK, "- (void)_computeAutoSkipMarkers")
require('Auto-Skip-Marker berechnet' in compute_markers, "Auto-skip marker computation must be logged.")
for key in ["chapterCount", "markerCount", "skipNameCount", "sponsorKeywordEnabled"]:
    require(f'@"{key}"' in compute_markers, f"Auto-skip marker diagnostics must include {key}.")
