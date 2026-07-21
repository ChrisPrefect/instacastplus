#!/usr/bin/env python3
"""Pins background callbacks across asynchronous database preparation."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = APP.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = APP.find("{", start)
    depth = 0
    for index in range(brace, len(APP)):
        if APP[index] == "{":
            depth += 1
        elif APP[index] == "}":
            depth -= 1
            if depth == 0:
                return APP[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


launch = method_body("- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:")
registration = method_body("- (void)_registerTranscriptionBackgroundTasks")
require(
    registration.count("registerForTaskWithIdentifier:") >= 2
    and registration.count("usingQueue:dispatch_get_main_queue()")
    == registration.count("registerForTaskWithIdentifier:"),
    "BGTask launch/state checks and Ready replay must share the main queue atomically.",
)
for queue in (
    "pendingTranscriptionBackgroundTasks",
    "pendingDatabaseRemoteNotifications",
    "pendingDatabaseFetchCompletionHandlers",
):
    require(queue in launch, f"Cold launch must initialize {queue} before callbacks can arrive.")
require(
    "pendingDatabaseSystemCallbacksBackgroundTask = UIBackgroundTaskInvalid" in launch,
    "Queued UIKit callbacks need an explicit OS-managed background-time owner.",
)

processing = method_body("- (void)_handleTranscriptionProcessingTask:")
continued = method_body("- (void)_handleTranscriptionContinuedProcessingTask:")
require(
    "_deferTranscriptionTaskUntilDatabaseReady" in processing
    and "_deferTranscriptionTaskUntilDatabaseReady" in continued,
    "Both transcription task types must be retained while database preparation is in progress.",
)

defer_task = method_body("- (BOOL)_deferTranscriptionTaskUntilDatabaseReady:")
require(
    "pendingTranscriptionBackgroundTasks" in defer_task
    and "_installTranscriptionTaskExpirationHandler" in defer_task
    and "setTaskCompletedWithSuccess:NO" in defer_task
    # Rescheduling runs through the shared ownership-retire helper.
    and ("_scheduleTranscriptionProcessingTask" in defer_task
         or "_retireDeferredTranscriptionTaskOwnership" in defer_task),
    "Deferred BGTasks need expiry completion, and legacy processing must be rescheduled instead of being lost.",
)
expire_task = method_body("- (void)_expireTranscriptionTask:")
require(
    "pendingTranscriptionBackgroundTasks" in expire_task
    and "activeTranscriptionTaskExpirationHandlers" in expire_task,
    "One expiration path must cover both deferred and already-replayed task ownership.",
)
replay = method_body("- (void)_replayPendingDatabaseStartupWork")
require(
    "task.expirationHandler = nil" not in replay
    and "activeTranscriptionTaskExpirationHandlers" in APP,
    "Replay must not create a gap by clearing the only expiration handler before active cancellation is installed.",
)

remote = method_body(
    "- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:"
)
fetch = method_body(
    "- (void)application:(UIApplication *)application performFetchWithCompletionHandler:"
)
require(
    "pendingDatabaseRemoteNotifications" in remote
    and "_beginPendingDatabaseSystemCallbacksBackgroundTaskIfNeeded" in remote
    and "UIBackgroundFetchResultFailed" in remote,
    "Silent/iCloud pushes must queue while preparing and fail explicitly only after database startup fails.",
)
require(
    "pendingDatabaseFetchCompletionHandlers" in fetch
    and "_beginPendingDatabaseSystemCallbacksBackgroundTaskIfNeeded" in fetch
    and "UIBackgroundFetchResultFailed" in fetch,
    "Background fetch callbacks must queue while preparing instead of being discarded as NoData.",
)

background_time = method_body("- (void)_beginPendingDatabaseSystemCallbacksBackgroundTaskIfNeeded")
require(
    "beginBackgroundTaskWithName" in background_time
    and "expirationHandler" in background_time
    and "_completePendingDatabaseSystemCallbacksWithResult" in background_time,
    "Waiting uses UIKit's real expiration signal, not an arbitrary timer or an unbounded completion queue.",
)
expire_background_time = method_body("- (void)_expirePendingDatabaseSystemCallbacksBackgroundTaskForGeneration:")
require(
    "pendingDatabaseSystemCallbacksBackgroundTaskGeneration" in APP
    and "pendingDatabaseSystemCallbacksBackgroundTaskGeneration" in background_time
    and "_expirePendingDatabaseSystemCallbacksBackgroundTaskForGeneration:" in background_time
    and "dispatch_async" not in background_time
    and "pendingDatabaseSystemCallbacksBackgroundTaskGeneration != generation" in expire_background_time
    and "pendingDatabaseSystemCallbacksBackgroundTask == UIBackgroundTaskInvalid" in expire_background_time
    and "_completePendingDatabaseSystemCallbacksWithResult:UIBackgroundFetchResultFailed" in expire_background_time,
    "Background expiration must synchronously expire only the task generation that owns the queued callbacks; a stale handler must not clear a newer task.",
)
complete_callbacks = method_body("- (void)_completePendingDatabaseSystemCallbacksWithResult:")
end_background_time = method_body("- (void)_endPendingDatabaseSystemCallbacksBackgroundTaskIfPossible")
require(
    "pendingBackgroundURLSessionEvents" in complete_callbacks
    and "pendingDatabaseRemoteNotifications" in complete_callbacks
    and "pendingDatabaseFetchCompletionHandlers" in complete_callbacks
    and "_endPendingDatabaseSystemCallbacksBackgroundTaskIfPossible" in complete_callbacks
    and "endBackgroundTask" in end_background_time
    and end_background_time.find("UIBackgroundTaskInvalid") < end_background_time.find("endBackgroundTask"),
    "Expiration/failure must finish every queued UIKit callback and release background time exactly once.",
)

startup = method_body("- (void) _startUpApplicationWithLaunchOptions:")
require(
    startup.find("ICDatabaseStartupStateReady") < startup.find("_replayPendingDatabaseStartupWork"),
    "Queued work may replay only after all database-dependent services are ready.",
)
require(
    "UIApplicationLaunchOptionsRemoteNotificationKey" not in startup,
    "UIKit redelivers a cold-launch remote notification through the fetch delegate; manually reading launch options processes it twice.",
)
require(
    APP.count("_failPendingDatabaseStartupWork") >= 3,
    "Every startup failure path must complete queued system callbacks instead of leaking them.",
)

print("Database background-work replay regression checks passed")
