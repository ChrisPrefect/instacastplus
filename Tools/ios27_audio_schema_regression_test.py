#!/usr/bin/env python3
"""Source/lifecycle contracts; the SDK build additionally validates schema metadata."""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / "Classes/AppIntents/ICAudioIntents.swift"
assert source.exists(), "iOS 27 audio schema integration is missing"
audio = source.read_text()
for schema in ("podcastShow", "podcastEpisode", "playAudio"):
    assert f"schema: .audio.{schema}" in audio, schema
assert "@available(iOS 27.0, *)" in audio
assert "MediaIntents" in audio and "IntentValueQuery" in audio
assert "EntityIdentifier(for:" in audio
bridge = (ROOT / "Classes/AppIntents/ICIntentBridge.swift").read_text()
assert "@MainActor\nenum ICIntentBridge" in bridge
assert "session.prepend(toUpNext:" in bridge
assert "session.append(toUpNext:" in bridge
assert "guard playbackAttributes.isEmpty" in audio, "Unsupported playback modifiers must not report success"
for path in ("EpisodesTableViewCell.m", "SubscriptionTableViewCell.m"):
    text = (ROOT / "Classes" / path).read_text()
    setter = text[text.index("- (void) setObjectValue:"):] if "- (void) setObjectValue:" in text else text[text.index("- (void)setObjectValue:"):]
    assert setter.index("ICAudioViewAnnotationBridge") < setter.index("if (!objectValue)"), "Reused cells must clear stale annotations"
for path in ("EpisodeViewController.m", "PlayerInfoViewController_v5.m"):
    assert "ICAudioViewAnnotationBridge" in (ROOT / "Classes" / path).read_text()
database = (ROOT / "Classes/Model/DatabaseManager.m").read_text()
migration = database.split("- (void) _migrateSpotlight\n", 1)[1].split("- (void) _migrateDatabase", 1)[0]
assert "SpotlightAudioSchemaMigrationDone" in migration
assert "newExportBackgroundContext" in migration and "setParentContext:" not in migration
assert migration.index("if (indexError)") < migration.index("setBool:YES")

if len(sys.argv) > 1:
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
print("iOS 27 audio schema and view lifecycle contracts passed")
