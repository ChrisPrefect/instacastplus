#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def source_between(source, start, end):
    require(start in source, f"{start} is missing.")
    require(end in source, f"{end} is missing.")
    return source.split(start, 1)[1].split(end, 1)[0]


TRANSCRIPTION_ENGINE = read("Classes/TranscriptionEngine.swift")
OPTIONS = read("Classes/OptionsViewController.m")


attachments_body = source_between(
    TRANSCRIPTION_ENGINE,
    "@objc func crashLogMailAttachments() -> [ICDiagnosticMailAttachment] {",
    "    @objc func crashLogMailBody() -> String {",
)
clear_body = source_between(
    TRANSCRIPTION_ENGINE,
    "@objc func clearCrashLogMailArtifacts()",
    "    @objc func logStorageLayout",
)
mail_finish = source_between(
    OPTIONS,
    "- (void)mailComposeController:(MFMailComposeViewController*)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError*)error",
    "@end",
)

for file_name in ["Diagnostics.jsonl", "Application.Log"]:
    require(file_name in attachments_body, f"Crash-log mail must export {file_name}.")
    require(file_name in clear_body, f"Sent crash-log cleanup must remove exported {file_name}.")

require(
    "queue.sync" in clear_body,
    "Sent crash-log cleanup must finish before the mail delegate returns, otherwise old logs can survive app suspension.",
)
require(
    "queue.async" not in clear_body,
    "Sent crash-log cleanup must not be fire-and-forget.",
)
require(
    "initializeLoggers" in clear_body,
    "After deleting Application.Log, the app logger must be reopened so future errors write to a fresh visible log file.",
)
require(
    "clearCrashLogMailArtifacts" in mail_finish and "result == MFMailComposeResultSent" in mail_finish,
    "Crash-log artifacts must be cleared after Mail reports the crash-log message as sent.",
)
