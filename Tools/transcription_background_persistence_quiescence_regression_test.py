from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUEUE_SOURCE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
APP_DELEGATE_SOURCE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


persist_body = method_body(QUEUE_SOURCE, "private func persistQueue(")

require(
    "private var pendingQueuePersistenceCount = 0" in QUEUE_SOURCE
    and "@objc var hasPendingQueuePersistence: Bool" in QUEUE_SOURCE
    and "private var lastQueuePersistenceError: NSError?" in QUEUE_SOURCE
    and "@objc var queuePersistenceError: NSError?" in QUEUE_SOURCE,
    "TranscriptionQueue does not expose whether an asynchronous queue snapshot is still being committed.",
)
require(
    "pendingQueuePersistenceCount += 1" in persist_body
    and persist_body.index("pendingQueuePersistenceCount += 1")
    < persist_body.index("ICWritePersistedTranscriptionQueueData"),
    "Queue persistence is not marked pending before the asynchronous atomic write starts.",
)
require(
    "Task { @MainActor in" in persist_body
    and "self.lastQueuePersistenceError = error" in persist_body
    and "pendingQueuePersistenceCount -= 1" in persist_body
    and "pendingQueuePersistenceCount == 0" in persist_body
    and "postQueueChangeNotification()" in persist_body,
    "The queue does not publish a main-actor queue change when all asynchronous persistence writes drain.",
)
require(
    "lastQueuePersistenceError = error as NSError" in persist_body
    and "postQueueChangeNotification()" in persist_body.split("} catch {", 1)[1],
    "A synchronous queue encoding failure is not retained or published to the owning BG task.",
)

for signature, task_completion in (
    ("- (void)_handleTranscriptionProcessingTask:", "[processingTask setTaskCompletedWithSuccess:success]"),
    ("- (void)_handleTranscriptionContinuedProcessingTask:", "[continuedTask setTaskCompletedWithSuccess:success]"),
):
    body = method_body(APP_DELEGATE_SOURCE, signature)
    require(
        "completionRequested" in body
        and "if (!executionPathCompleted)" in body
        and "completeBackgroundExecutionPathWithSuccess:requestedSuccess reason:requestedReason" in body
        and "if (queue.hasPendingQueuePersistence) {" in body
        and task_completion in body
        and body.index("completeBackgroundExecutionPathWithSuccess:requestedSuccess reason:requestedReason")
        < body.index("if (queue.hasPendingQueuePersistence) {")
        < body.index(task_completion),
        f"{signature} can still tell iOS it completed before the final queue snapshot is durable.",
    )
    require(
        "else if (!success)" in body
        and "requestedSuccess = NO;" in body
        and "wartet auf Queue-Persistenz" in body,
        f"{signature} does not preserve expiration/failure or diagnose a deferred persistence wait.",
    )
    require(
        "queue.queuePersistenceError" in body
        and "requestedSuccess = NO;" in body
        and "queue-persistence-failed" in body
        and body.index("queue.queuePersistenceError") < body.index(task_completion),
        f"{signature} reports success to iOS even when the final queue snapshot failed.",
    )
    observer_body = body.split('addObserverForName:@"ICTranscriptionQueueDidChangeNotification"', 1)[1]
    require(
        "if (completionRequested)" in observer_body
        and "completeTask(requestedSuccess, requestedReason);" in observer_body,
        f"{signature} does not retry deferred completion when queue persistence becomes quiescent.",
    )


print("Transcription background persistence quiescence regression checks passed.")
