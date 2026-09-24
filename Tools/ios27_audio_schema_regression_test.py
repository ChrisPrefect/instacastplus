#!/usr/bin/env python3
"""Validate the audio schema contract in an actual built app bundle."""
from pathlib import Path
import json
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: ios27_audio_schema_regression_test.py /path/to/InstacastPlus.app")

bundle = Path(sys.argv[1])
metadata = json.loads((bundle / "Metadata.appintents/extract.actionsdata").read_text())
for group, name, schema in [
    ("entities", "ICAudioPodcastEntity", "PodcastShowEntity"),
    ("entities", "ICAudioEpisodeEntity", "PodcastEpisodeEntity"),
    ("actions", "ICPlayAudioIntent", "PlayAudioIntent"),
]:
    definition = metadata[group][name]
    assert any(s["domain"] == "audio" and s["name"] == schema for s in definition["assistantDefinedSchemas"])
    assert definition["availabilityAnnotations"]["LNPlatformNameIOS"]["introducedVersion"] == "27.0"
for name in ("ICPodcastEntity", "ICEpisodeEntity"):
    assert name in metadata["entities"], "Saved shortcuts must retain their entity types"
play = metadata["actions"]["ICPlayAudioIntent"]
assert {p["name"] for p in play["parameters"]} == {"audioEntity", "playbackAttributes", "queueLocation", "warmupAudioQueueResult"}
assert not play["openAppWhenRun"]
assert "ICAudioSearchQuery" in metadata["queries"]
print("Built App Intents metadata contracts passed")
