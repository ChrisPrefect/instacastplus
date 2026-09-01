#!/usr/bin/env python3
"""Pins SharePlay/Handoff wiring to the existing playback and scene lifecycle."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


playback = read("Classes/PlaybackManager.m")
playback_header = read("Classes/PlaybackManager.h")
audio = read("Classes/AudioSession.m")
episode_view = read("Classes/EpisodeViewController.m")
scene = read("Classes/InstacastSceneDelegate.m")

for token in [
    "publishLocalEpisodeIdentifier:",
    "attachPlayer:self.player episodeIdentifier:self.playingEpisode.objectHash",
    "canAdvanceAutomatically",
    "hasActiveSession",
    "publishPlaybackFinishedForEpisodeIdentifier:",
    "requestedCoordinatedRate",
]:
    require(token in playback, f"PlaybackManager is missing SharePlay integration: {token}")

require(
    playback.count("canAdvanceAutomatically") >= 3,
    "All three automatic episode-finish paths must use the SharePlay transition owner.",
)
require(
    playback.count("publishPlaybackFinishedForEpisodeIdentifier:episode.objectHash") >= 3,
    "Every owner path with no successor must publish the shared playback-finished state.",
)
require(
    playback.find("requestedCoordinatedRate") < playback.find("weakSelf.player.rate = targetRate"),
    "A coordinated remote speed must be reconciled before the local speed-enforcement path.",
)
for token in [
    'initWithActivityType:@"com.iteconomy.instacastplus.playback"',
    "eligibleForHandoff = YES",
    "externalMediaContentIdentifier",
    "targetContentIdentifier",
    "userActivityWillSave:",
    "requiredUserInfoKeys = [NSSet setWithArray:userInfo.allKeys]",
    "wasPlaying",
]:
    require(token in playback, f"Playback Handoff publication is incomplete: {token}")

sleep_timer = audio.split("- (void)stopPlaybackTimer:", 1)[1]
leave = "leaveSessionForLocalPlayback"
pause = "[[PlaybackManager playbackManager] pause]"
require(leave in sleep_timer, "A local sleep timer must leave SharePlay before pausing.")
require(
    sleep_timer.find(leave) < sleep_timer.find(pause),
    "The sleep timer must leave the GroupSession synchronously before its pause call.",
)

for token in [
    "activityItemProviderForEpisodeIdentifier:",
    "allowsProminentActivity = YES",
]:
    require(token in episode_view, f"The existing episode share sheet is missing SharePlay: {token}")

for token in [
    "activityDidChangeNotification",
    "startObservingSessions",
    "redeliverPendingAppliedActivity",
    "_sharePlayActivityDidChange:",
    "_applySharePlayActivity:",
    "acknowledgeAppliedActivityOwnerToken:",
    "isCurrentActivityOwnerToken:",
    "playbackFinishedUserInfoKey",
    'ICPlaybackHandoffActivityType = @"com.iteconomy.instacastplus.playback"',
    "isEqualToString:ICPlaybackHandoffActivityType",
    "_continuePlaybackUserActivity:",
    "autostart:NO",
    "autostart:wasPlaying.boolValue",
    "preservingPlaybackSource:NO",
]:
    require(token in scene, f"Scene lifecycle is missing SharePlay/Handoff handling: {token}")

require(
    "locallyOriginatedUserInfoKey" in scene,
    "The scene must ignore its own SharePlay activity rather than reloading it as remote state.",
)
require(
    "pendingSharePlayActivity" in scene,
    "A SharePlay activity arriving during database startup must survive until the scene is ready.",
)

shareplay_handler = scene.split("- (void)_sharePlayActivityDidChange:", 2)[-1].split(
    "- (void)_applySharePlayActivity:", 1
)[0]
local_activity = "locallyOriginatedUserInfoKey"
apply_activity = "[self _applySharePlayActivity:activity]"
require(
    shareplay_handler.find(local_activity) < shareplay_handler.find(apply_activity)
    and "acknowledgeAppliedActivityOwnerToken:ownerToken" in shareplay_handler,
    "A locally originated GroupActivity must be acknowledged and returned before remote playback is applied.",
)

shareplay_apply = scene.split("- (void)_applySharePlayActivity:", 2)[-1].split(
    "- (void)_continuePlaybackUserActivity:", 1
)[0]
for token in ["queueUpCurrent:NO", "autostart:NO", "preservingPlaybackSource:NO"]:
    require(token in shareplay_apply, f"Remote SharePlay playback must remain paused and local-source-free: {token}")
require(
    "playbackFinishedUserInfoKey" in shareplay_apply
    and "closeAfterFinishedPlayback" in shareplay_apply
    and "closeAfterFinishedPlayback" in playback_header,
    "A shared no-successor end state must close the matching finished episode on every participant.",
)
require(
    "playbackManager.playingEpisode.objectHash" in shareplay_apply
    and "playbackManager.ready" not in shareplay_apply
    and shareplay_apply.find("acknowledgeAppliedActivityOwnerToken:ownerToken")
    < shareplay_apply.find("playEpisode:episode"),
    "The current SharePlay episode must be acknowledged without reopening it, including while its asset is loading.",
)

handoff_apply = scene.split("- (void)_continuePlaybackUserActivity:", 2)[-1].split(
    "- (void)_resolveEpisodeWithObjectHash:", 1
)[0]
for token in ["position.doubleValue", "wasPlaying.boolValue", "queueUpCurrent:NO", "preservingPlaybackSource:NO"]:
    require(token in handoff_apply, f"Playback Handoff restoration is incomplete: {token}")
for token in ["playbackManager.playingEpisode.objectHash", "seekToTime:", "[playbackManager play]", "[playbackManager pause]"]:
    require(token in handoff_apply, f"Handoff must update an already loaded episode in place: {token}")
require(
    handoff_apply.find("seekToTime:") < handoff_apply.find("playEpisode:episode"),
    "Handoff must seek an already loaded player instead of rebuilding it.",
)

resolver = scene.split("- (void)_resolveEpisodeWithObjectHash:", 2)[-1]
local_lookup = "[DMANAGER episodeWithObjectHash:objectHash]"
feed_parse = "[[App mainQueue] addOperation:parser]"
require(
    local_lookup in resolver and feed_parse in resolver and resolver.find(local_lookup) < resolver.find(feed_parse),
    "SharePlay/Handoff must resolve objectHash locally before parsing feedURL + GUID.",
)
require(
    resolver.count("dispatch_async(dispatch_get_main_queue()") >= 2
    and resolver.find("dispatch_async(dispatch_get_main_queue()") < resolver.find("[DMANAGER addUnsubscribedFeed:"),
    "Feed parsing may run in the background, but every DMANAGER/completion callback must return to the main thread.",
)
require(
    "latestSharePlayOwnerToken" in scene,
    "A superseded asynchronous feed resolution must not apply an older SharePlay episode.",
)
require(
    "isCurrentActivityOwnerToken:ownerToken" in shareplay_apply,
    "A feed callback from an ended SharePlay session must not apply its old episode.",
)

disconnect = scene.split("- (void)sceneDidDisconnect:", 1)[-1].split("- (void)sceneDidBecomeActive:", 1)[0]
require(
    "activityDidChangeNotification" in disconnect and "removeObserver:self" in disconnect,
    "A disconnected scene must stop receiving SharePlay activity notifications.",
)

scene_connect = scene.split("- (void)scene:", 1)[-1].split("// Window size restrictions", 1)[0]
require(
    scene_connect.find("addObserver:self")
    < scene_connect.find("redeliverPendingAppliedActivity"),
    "A reconnected scene must observe SharePlay before pending activity is redelivered.",
)

print("SharePlay/Handoff integration regression checks passed.")
