from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


engine_source = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
scene_source = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
playback_source = (ROOT / "Classes" / "PlaybackManager.m").read_text()


require(
    "let metadata: [String: String]?" in engine_source
    and "writeSessionStateLocked(state: state, metadata: convertedMetadata)" in engine_source,
    "Lifecycle session state must persist metadata, otherwise a background termination loses playback/background context.",
)

require(
    "didPreviousSessionEndInBackground" in engine_source
    and '"previousSessionEndedInBackground"' in engine_source
    and '"secondsSincePreviousState"' in engine_source
    and '"background-termination"' in engine_source,
    "Startup diagnostics must separately flag previous background terminations and record elapsed time since the last state.",
)

unexpected_classifier = engine_source.split("private static func didPreviousSessionEndUnexpectedly", 1)[1].split(
    "private static func didPreviousSessionEndInBackground", 1
)[0]
require(
    "!didPreviousSessionEndInBackground(state)" in unexpected_classifier,
    "A normal sceneDidEnterBackground termination must not also be classified as an unexpected crash.",
)

background_block = scene_source.split("- (void)sceneDidEnterBackground:", 1)[1].split("- (void)templateApplicationScene:", 1)[0]
require(
    "[self _diagnosticLifecycleMetadataForScene:scene]" in background_block,
    "sceneDidEnterBackground must persist the shared lifecycle diagnostics metadata.",
)
metadata_helper = scene_source.split("- (NSMutableDictionary*)_diagnosticLifecycleMetadataForScene:", 1)[1].split("- (void)sceneWillEnterForeground:", 1)[0]
for key in [
    "applicationState",
    "backgroundTimeRemaining",
    "playbackEpisodeHash",
    "playbackReady",
    "playbackPaused",
    "playbackTime",
    "playbackDuration",
    "playbackActive",
]:
    require(key in metadata_helper, f"sceneDidEnterBackground diagnostics must include {key}.")

require(
    '"background-playback"' in playback_source
    and "Hintergrund-Playback-Checkpoint" in playback_source
    and "_logBackgroundPlaybackCheckpointIfNeeded" in playback_source
    and "[weakSelf _logBackgroundPlaybackCheckpointIfNeeded];" in playback_source,
    "Background playback must emit periodic checkpoints so future background kills have a last-known playback state.",
)
