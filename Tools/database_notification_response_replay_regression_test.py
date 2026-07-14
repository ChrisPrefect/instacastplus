#!/usr/bin/env python3
"""Pins exact-once notification interactions across protected-data/database startup."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
HEADER = (ROOT / "Classes" / "InstacastAppDelegate.h").read_text()
SCENE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace:index + 1]
    raise AssertionError(f"Unterminated method: {signature}")


will_connect = method_body(
    SCENE,
    "- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions",
)
require(
    "connectionOptions.notificationResponse" in will_connect
    and "handleNotificationResponse" in will_connect,
    "A scene cold launch must enqueue its response through AppDelegate's ordered interaction gate.",
)
startup_gate = will_connect.find("if (appDelegate.databaseStartupState == ICDatabaseStartupStateFailed)")
early_delivery = will_connect.find("handleNotificationResponse")
require(
    "setNotificationSceneReady:NO" in will_connect
    and will_connect.find("setNotificationSceneReady:NO") < early_delivery < startup_gate,
    "SceneDelegate must close the UI gate before either cold-launch callback can enqueue navigation.",
)
require(
    "setNotificationSceneReady:YES" in will_connect,
    "The normal ready path must open the notification UI gate after installing the root controller.",
)
scene_implementation = SCENE[SCENE.find("@implementation InstacastSceneDelegate"):]
scene_ready = method_body(scene_implementation, "- (void)_mainViewControllerDidBecomeReady:")
scene_disconnect = method_body(scene_implementation, "- (void)sceneDidDisconnect:")
require(
    "setNotificationSceneReady:YES" in scene_ready
    and scene_ready.find("setNotificationSceneReady:YES") > scene_ready.find("self.pendingUserActivities = nil"),
    "Migration-held responses must replay only after root attachment and earlier URL/activity handoffs complete.",
)
require(
    "removeObserver:self" in scene_disconnect
    and "InstacastMainViewControllerDidBecomeReadyNotification" in scene_disconnect
    and "setNotificationSceneReady:NO" in scene_disconnect
    and "appDelegate.window == self.window" in scene_disconnect
    and "self.window.windowScene == scene" in scene_disconnect,
    "Only the UIWindowScene that owns AppDelegate's main window may close the notification UI gate; CarPlay and rejected secondary scenes must not block the active window.",
)
require(
    "handleNotificationResponse" in HEADER
    and "setNotificationSceneReady:" in HEADER,
    "SceneDelegate needs public response and UI-readiness handoffs owned by AppDelegate.",
)

modern_response = method_body(
    APP,
    "- (void)userNotificationCenter:(UNUserNotificationCenter *)center",
)
require(
    "didReceiveNotificationResponse:(UNNotificationResponse *)response" in APP
    and "handleNotificationResponse" in modern_response
    and "completionHandler" in modern_response,
    "Running-scene notification responses must use the same gated route and always finish UIKit's callback.",
)

handoff = method_body(APP, "- (void)handleNotificationResponse:")
require(
    "request.identifier" in handoff
    and "handledNotificationResponseIdentifiers" in handoff
    and "UNNotificationDismissActionIdentifier" in handoff,
    "Modern response delivery needs request-ID deduplication and must ignore dismiss actions deliberately.",
)

enqueue = method_body(APP, "- (void)_enqueueNotificationInteractionWithUserInfo:")
require(
    "ICDatabaseStartupStateReady" in enqueue
    and "notificationSceneReady" in enqueue
    and "UNNotificationDefaultActionIdentifier" in enqueue
    and "pendingNotificationInteractions" in enqueue
    and "_performNotificationInteractionWithUserInfo" in enqueue,
    "Default-tap navigation needs both database and Scene readiness; non-UI actions may run once the database is ready.",
)
replay = method_body(APP, "- (void)_replayPendingDatabaseStartupWork")
replay_interactions = method_body(APP, "- (void)_replayPendingNotificationInteractionsIfPossible")
failure = method_body(APP, "- (void)_failPendingDatabaseStartupWork")
require(
    "_replayPendingNotificationInteractionsIfPossible" in replay
    and "notificationSceneReady" in replay_interactions
    and "remainingInteractions" in replay_interactions
    and "blockedByEarlierInteraction" in replay_interactions
    and "_performNotificationInteractionWithUserInfo" in replay_interactions,
    "Database readiness must retain strict FIFO order after the first interaction blocked on Scene readiness.",
)
require(
    "pendingNotificationInteractions.count == 0" in enqueue
    and "_beginPendingDatabaseSystemCallbacksBackgroundTaskIfNeeded" in enqueue,
    "A newer Play action must not overtake an older queued tap, and deferred non-UI actions need execution time.",
)
background_end = method_body(APP, "- (void)_endPendingDatabaseSystemCallbacksBackgroundTaskIfPossible")
background_expiration = method_body(APP, "- (void)_completePendingDatabaseSystemCallbacksWithResult:")
require(
    "_hasPendingNotificationBackgroundAction" in background_end
    and "pendingNotificationInteractions" in background_expiration
    and "UNNotificationDefaultActionIdentifier" in background_expiration,
    "The shared background assertion must remain active for queued Play actions and expire them without discarding UI taps.",
)
require(
    "pendingNotificationInteractions" in failure and "removeAllObjects" in failure,
    "A terminal database failure must release retained notification interactions.",
)

legacy_tap = method_body(
    APP,
    "- (void)application:(UIApplication *)application didReceiveLocalNotification:",
)
legacy_action = method_body(
    APP,
    "- (void)application:(UIApplication *)application handleActionWithIdentifier:",
)
require(
    "_enqueueNotificationInteractionWithUserInfo" in legacy_tap
    and "databaseStartupState != ICDatabaseStartupStateReady" not in legacy_tap,
    "A legacy local-notification tap during migration must be retained, not discarded.",
)
require(
    "_enqueueNotificationInteractionWithUserInfo" in legacy_action
    and legacy_action.count("completionHandler();") == 1
    and "databaseStartupState != ICDatabaseStartupStateReady" not in legacy_action,
    "A legacy notification action must be retained while completing UIKit exactly once.",
)


print("Database notification-response replay regression checks passed")
