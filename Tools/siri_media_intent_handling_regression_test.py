#!/usr/bin/env python3
"""Pins direct in-app handling of SiriKit Play Media intents."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(signature: str) -> str:
    require(signature in SOURCE, f"Missing method: {signature}")
    return SOURCE.split(signature, 1)[1].split("\n- (", 1)[0]


require("#import <Intents/Intents.h>" in SOURCE, "AppDelegate must import SiriKit Intents.")
require(
    "<UNUserNotificationCenterDelegate, INPlayMediaIntentHandling>" in SOURCE,
    "AppDelegate must implement INPlayMediaIntentHandling in app.",
)

handler = method_body("- (id)application:(UIApplication *)application handlerForIntent:(INIntent *)intent")
require(
    "[intent isKindOfClass:INPlayMediaIntent.class]" in handler
    and "return self;" in handler
    and "return nil;" in handler,
    "Only INPlayMediaIntent must be routed to AppDelegate.",
)

play = method_body("- (void)handlePlayMedia:(INPlayMediaIntent *)intent")
for token in [
    "dispatch_async(dispatch_get_main_queue()",
    "ICDatabaseStartupStateReady",
    "INPlayMediaIntentResponseCodeFailureRequiringAppLaunch",
    "intent.mediaItems.firstObject.identifier",
    "episodeWithObjectHash:",
    "intent.mediaContainer.identifier",
    "feedWithSourceURL:",
    "sortedEpisodes",
    "intent.resumePlayback.boolValue",
    "preservingPlaybackSource:YES",
    "intent.playbackSpeed",
    "INPlayMediaIntentResponseCodeSuccess",
    "INPlayMediaIntentResponseCodeFailureUnknownMediaType",
    "INPlayMediaIntentResponseCodeFailureNoUnplayedContent",
]:
    require(token in play, f"Play Media handling is incomplete: {token}")

for token in [
    '[playbackManager removeTaskObserver:self forKeyPath:@"speedControl"]',
    "[AudioSession playbackIntentRevision]",
    '[playbackManager addTaskObserver:self forKeyPath:@"speedControl"',
    "observedPlaybackManager.ready",
    "observedPlaybackManager.playingEpisode.objectHash",
    "observedPlaybackManager.playbackRate = requestedPlaybackSpeed.floatValue",
]:
    require(token in play, f"Siri playback speed is not tied to the accepted ready playback: {token}")
require(
    "playbackManager.playbackRate = intent.playbackSpeed.floatValue" not in play,
    "A new Siri episode must not apply playback speed before PlaybackManager initializes the feed rate.",
)
speed_observer = play.split('[playbackManager addTaskObserver:self forKeyPath:@"speedControl"', 1)[1]
require(
    speed_observer.find("observedPlaybackManager.ready")
    < speed_observer.find("observedPlaybackManager.playbackRate = requestedPlaybackSpeed.floatValue"),
    "The deferred Siri speed may only apply once playback is ready.",
)
require(
    speed_observer.find("[AudioSession playbackIntentRevision]")
    < speed_observer.find("observedPlaybackManager.playbackRate = requestedPlaybackSpeed.floatValue"),
    "A superseded playback start must not inherit an older Siri speed request.",
)

ready = method_body("- (void) _startUpApplicationWithLaunchOptions:(NSDictionary *)launchOptions")
ready_state = ready.find("self.databaseStartupState = ICDatabaseStartupStateReady;")
context = ready.find("INMediaUserContext")
require(
    0 <= ready_state < context
    and "if (feed.subscribed)" in ready[ready_state:context]
    and "numberOfLibraryItems = @(subscribedPodcastCount);" in ready[context:]
    and "[mediaUserContext becomeCurrent];" in ready[context:],
    "The Siri media library context must become current only after the database is ready.",
)

print("Siri media intent handling regression checks passed.")
