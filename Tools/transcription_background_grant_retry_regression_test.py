#!/usr/bin/env python3
"""Pins retry wakeups and real iOS background-grant boundaries."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
CONTROLLER = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()
APP_DELEGATE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def declaration_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""
    brace = source.find("{", start)
    if brace < 0:
        return ""
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    return ""


failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


# A BGProcessingTaskRequest is only a request to iOS, not an in-process wakeup.
# While the app remains alive/foregrounded, the queue must wake itself at the
# earliest persisted retry date and actually ask processNext() to re-evaluate it.
retry_wake = declaration_body(QUEUE, "private func scheduleRetryWakeIfNeeded(")
schedule_retry = declaration_body(QUEUE, "private func scheduleRetry(for item:")
has_real_wake_primitive = any(
    token in retry_wake
    for token in ("asyncAfter", "Task.sleep", "scheduledTimer", "Timer(")
)
check(
    bool(retry_wake)
    and "retryWake" in QUEUE
    and "earliestAutomaticRetryDate" in retry_wake
    and has_real_wake_primitive
    and "processNext()" in retry_wake
    and "scheduleRetryWakeIfNeeded" in schedule_retry,
    "Retry scheduling has no cancellable in-process wake that calls processNext() at the earliest nextRetryAt.",
)


# A manual local-model job involved in a previous crash must remain stopped for
# explicit retry, but it must not return out of resumeIfNeeded before unrelated
# automatic jobs get a chance to run.
resume = declaration_body(QUEUE, "@objc func resumeIfNeeded()")
protected_return = declaration_body(resume, "if hasCrashGuardProtectedItems {")
check(
    "item.requiresExplicitRetryAfterCrash = true" in resume
    and "processNext()" in resume
    and "!$0.requiresExplicitRetryAfterCrash" in QUEUE
    and (not protected_return or "return" not in protected_return),
    "A crash-protected manual job still returns from resumeIfNeeded and blocks eligible automatic jobs.",
)


# submit() merely registers a request with iOS. The active execution grant starts
# only when AppDelegate receives the BGTask launch callback. Grant state must be
# process-local so a killed process cannot resurrect a stale permission bit.
submit_processing = declaration_body(CONTROLLER, "- (void)_submitProcessingBackgroundTask")
submit_continued = declaration_body(CONTROLLER, "- (void)_submitContinuedBackgroundTask")
handle_processing = declaration_body(APP_DELEGATE, "- (void)_handleTranscriptionProcessingTask:")
handle_continued = declaration_body(APP_DELEGATE, "- (void)_handleTranscriptionContinuedProcessingTask:")
active_path_start = QUEUE.find("private var activeBackgroundExecutionPath")
active_path_end = QUEUE.find("private var hasActiveWhisperKitBackgroundExecution", active_path_start)
active_path_section = QUEUE[active_path_start:active_path_end] if active_path_start >= 0 and active_path_end > active_path_start else ""
submit_marks_active = any(
    "activateBackgroundExecutionPath" in body
    or 'setBool:YES forKey:@"TranscriptionBackgroundTaskActive"' in body
    for body in (submit_processing, submit_continued)
)
check(
    bool(submit_processing)
    and bool(submit_continued)
    and not submit_marks_active
    and "activateBackgroundExecutionPathWithPath" in handle_processing
    and "activateBackgroundExecutionPathWithPath" in handle_continued
    and "UserDefaults" not in active_path_section,
    "Submitting a BG request is still treated as an active system grant before the AppDelegate launch handler runs.",
)

# The button starts one visible/requested run; it is not a durable permission.
# Completion or rejection must clear its requested UI state.
check(
    "setBool:NO forKey:ICTranscriptionBackgroundTaskRequested" in handle_processing
    and "setBool:NO forKey:ICTranscriptionBackgroundTaskRequested" in handle_continued,
    "A completed background run leaves the one-shot start button displayed as permanently active.",
)


# Turning off the user-started iOS 26 continued run must not cancel the shared
# BGProcessing request used by fully automatic configured-podcast work. Legacy
# explicit BGProcessing can still be cancelled, but the automatic queue must be
# reconciled immediately afterwards.
continue_toggle = declaration_body(CONTROLLER, "- (void)_continueInBackground")
continued_active_branch = declaration_body(continue_toggle, "if (self.backgroundTaskActive)")
legacy_processing_cancel = declaration_body(continued_active_branch, "if (!isContinuedRequest)")
check(
    bool(continued_active_branch)
    and "isContinuedRequest" in continued_active_branch
    and "cancelTaskRequestWithIdentifier:ICTranscriptionContinuedTaskIdentifier" in continued_active_branch
    and "cancelTaskRequestWithIdentifier:ICTranscriptionProcessingTaskIdentifier" in legacy_processing_cancel
    and "scheduleAutomaticBackgroundProcessingIfNeeded" in continued_active_branch
    and continued_active_branch.find("deactivateBackgroundExecutionPathWithReason")
    < continued_active_branch.find("scheduleAutomaticBackgroundProcessingIfNeeded"),
    "Disabling the visible continued run can still cancel or strand the shared automatic BGProcessing request.",
)


# Chapter-only analysis can be as long-running as transcription. In background it
# may start only under an active BGProcessing/BGContinuedProcessing grant, never
# merely because chapterOnly bypasses the WhisperKit-specific pause predicate.
chapter_pause = declaration_body(QUEUE, "private var shouldPauseChapterOnlyForBackground")
process_next = declaration_body(QUEUE, "private func processNext()")
has_active_grant_check = (
    "hasActiveSystemBackgroundGrant" in chapter_pause
    or "hasActiveBackgroundExecution" in chapter_pause
    or "hasActiveWhisperKitBackgroundExecution" in chapter_pause
)
check(
    bool(chapter_pause)
    and "UIApplication.shared.applicationState == .background" in chapter_pause
    and has_active_grant_check
    and "shouldPauseChapterOnlyForBackground" in process_next
    and "$0.chapterOnly || !shouldPauseWhisperKitForBackground" not in process_next,
    "Chapter-only work can still start in the background without an active system execution grant.",
)


if failures:
    raise SystemExit("\n".join(f"- {failure}" for failure in failures))

print("transcription background grant/retry regression checks passed")
