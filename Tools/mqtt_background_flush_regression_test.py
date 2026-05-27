#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SMARTHOME = (ROOT / "Classes" / "SmarthomeManager.m").read_text()
MQTT_HEADER = (ROOT / "Classes" / "MQTT" / "ICMQTTClient.h").read_text()
MQTT_SOURCE = (ROOT / "Classes" / "MQTT" / "ICMQTTClient.m").read_text()
AUDIO_SESSION = (ROOT / "Classes" / "AudioSession.m").read_text()
PLAYBACK = (ROOT / "Classes" / "PlaybackManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def objc_method(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")

    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]

    raise SystemExit(f"Unterminated method body: {signature}")


require(
    "startSilentPlayback" not in AUDIO_SESSION
    and "startSilentPlayback" not in PLAYBACK
    and "Silence.caf" not in AUDIO_SESSION,
    "MQTT background delivery must not be implemented by running hidden silent audio.",
)

require(
    "UIBackgroundTaskIdentifier _backgroundPublishTaskIdentifier;" in SMARTHOME,
    "SmarthomeManager must own a real finite UIBackgroundTask for MQTT state flushes.",
)
require(
    "beginBackgroundTaskWithName:@\"InstacastPlus.MQTTStateFlush\"" in SMARTHOME,
    "MQTT background work must use a named UIApplication background task, not an audio keep-alive.",
)
require(
    "UIApplicationStateActive" in objc_method(SMARTHOME, "- (BOOL)_beginBackgroundPublishTaskIfNeeded"),
    "MQTT background task should only be requested while the app is inactive/backgrounded.",
)
require(
    "_endBackgroundPublishTask" in SMARTHOME
    and "endBackgroundTask:taskIdentifier" in SMARTHOME,
    "MQTT background tasks must always be ended.",
)

require(
    "- (void)flushPendingWritesWithCompletion:(void (^ _Nullable)(void))completion;" in MQTT_HEADER
    and "- (void)flushPendingWritesWithCompletion:(void (^)(void))completion" in MQTT_SOURCE,
    "ICMQTTClient must expose a flush completion so background tasks end after queued writes are handed to the stream.",
)
require(
    "_flushCompletionBlocks" in MQTT_SOURCE
    and "_completePendingFlushCompletions" in MQTT_SOURCE,
    "ICMQTTClient must complete pending background flush callbacks when writes drain or the stream closes.",
)
require(
    "_eventValuesByTopic" in SMARTHOME
    and "_eventDatesByTopic" in SMARTHOME
    and "NSISO8601DateFormatter" in SMARTHOME,
    "MQTT scalar topics need companion event timestamps so late delivery can be interpreted by event time.",
)
require(
    "[topic stringByAppendingString:@\"-timestamp\"]" in SMARTHOME,
    "MQTT timestamp companions must be sibling topics and must not change the existing scalar payloads.",
)
require(
    "changedAt:(NSDate*)changedAt" in SMARTHOME
    and "_eventDateForTopic:(NSString*)topic value:(NSString*)value changedAt:(NSDate*)changedAt" in SMARTHOME,
    "MQTT publishing must separate event time from broker delivery time.",
)
require(
    "_fellAsleepResetDate" in SMARTHOME
    and "_motionDetectedResetDate" in SMARTHOME
    and "_expireTransientStatesIfNeeded" in SMARTHOME,
    "Delayed sleep/motion reset events must keep their intended event time instead of using foreground resume time.",
)

for signature in (
    "- (void)appWillResignActive:(NSNotification*)note",
    "- (void)appDidEnterBackground:(NSNotification*)note",
    "- (void)playbackDidEnd:(NSNotification*)note",
    "- (void)sleepTimerDidExpire:(NSNotification*)note",
):
    body = objc_method(SMARTHOME, signature)
    require(
        "_performMQTTBackgroundFlushIfNeeded:" in body,
        f"{signature} must wrap final MQTT publishes in the finite background flush path.",
    )
