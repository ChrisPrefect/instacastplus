from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
CONTROLLER = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()
APP_DELEGATE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    raise SystemExit(f"Unterminated function: {signature}")


automatic_schedule = body(QUEUE, "private func scheduleAutomaticBackgroundProcessing(")
require(
    "cancel(taskRequestWithIdentifier:" not in automatic_schedule,
    "Automatic scheduling deletes the previous valid wake before a replacement submit succeeds.",
)
require(
    '"ICTranscriptionActiveContinuedPath"' in automatic_schedule,
    "Automatic BGProcessing can still be submitted while a visible continued request owns the queue.",
)

continued_submit = body(CONTROLLER, "- (void)_submitContinuedBackgroundTask")
submit_index = continued_submit.find("submitTaskRequest:request")
cancel_index = continued_submit.find("cancelTaskRequestWithIdentifier:ICTranscriptionProcessingTaskIdentifier")
require(
    submit_index >= 0 and cancel_index > submit_index and "if (submitError)" in continued_submit,
    "A successful visible continued request does not retire the competing pending processing request safely.",
)

processing_handler = body(APP_DELEGATE, "- (void)_handleTranscriptionProcessingTask:")
continued_handler = body(APP_DELEGATE, "- (void)_handleTranscriptionContinuedProcessingTask:")
pending_expiration = body(APP_DELEGATE, "- (void)_expireTranscriptionTask:")
database_defer = body(APP_DELEGATE, "- (BOOL)_deferTranscriptionTaskUntilDatabaseReady:")
database_failure = body(APP_DELEGATE, "- (void)_failPendingDatabaseStartupWork")
require(
    "ICTranscriptionActiveContinuedPath" in processing_handler
    and "setTaskCompletedWithSuccess:NO" in processing_handler,
    "A delivered processing task can overwrite a pending continued grant.",
)
require(
    "activeTranscriptionTaskExpirationHandlers.count" in continued_handler
    and "setTaskCompletedWithSuccess:NO" in continued_handler
    and "_scheduleTranscriptionProcessingTask" in continued_handler,
    "Continued processing lacks mutual exclusion or fails to restore automatic scheduling afterward.",
)
for lifecycle_body, label in (
    (pending_expiration, "cold-launch expiration"),
    (database_defer, "already-failed database startup"),
    (database_failure, "deferred database startup failure"),
):
    require(
        "_retireDeferredTranscriptionTaskOwnership" in lifecycle_body,
        "A deferred Continued request leaves stale ownership after " + label + ".",
    )

retire_ownership = body(APP_DELEGATE, "- (void)_retireDeferredTranscriptionTaskOwnership:")
require(
    "BGContinuedProcessingTask.class" in retire_ownership
    and "removeObjectForKey:ICTranscriptionActiveContinuedPath" in retire_ownership
    and "setBool:NO forKey:ICTranscriptionBackgroundTaskRequested" in retire_ownership
    and "_scheduleTranscriptionProcessingTask" in retire_ownership,
    "Deferred Continued ownership is not atomically cleared before automatic scheduling resumes.",
)

print("Background request ownership regression checks passed.")
