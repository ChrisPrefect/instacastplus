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


SUBSCRIPTION_MANAGER = read("Classes/Model/SubscriptionManager.m")
TRANSCRIPTION_ENGINE = read("Classes/TranscriptionEngine.swift")
OPTIONS = read("Classes/OptionsViewController.m")


parser_error_block = source_between(
    SUBSCRIPTION_MANAGER,
    "feedParser.didEndWithError = ^(NSError* error) {",
    "    [self.parserQueue addOperation:feedParser];",
)

require(
    "dispatch_async(dispatch_get_main_queue(), ^{" in parser_error_block,
    "Feed parser errors from pull-to-refresh must dispatch to the main queue before touching refresh state, notifications, completions, or UI-facing managed objects.",
)

main_dispatch_index = parser_error_block.index("dispatch_async(dispatch_get_main_queue(), ^{")
for ui_facing_statement in [
    "completion(NO, nil, error)",
    "SubscriptionManagerWillParseFeedNotification",
    "_markFeedFailedForURL:url",
    "_finishParsingFeed:feed",
]:
    require(ui_facing_statement in parser_error_block, f"{ui_facing_statement} is missing from the parser error path.")
    require(
        main_dispatch_index < parser_error_block.index(ui_facing_statement),
        f"{ui_facing_statement} must run inside the main-queue parser error handling block.",
    )

require(
    "[self.refreshingFeedURLs containsObject:url]" not in parser_error_block,
    "The parser error block must not read refresh state on the parser operation thread before dispatching to main.",
)


attachments_body = source_between(
    TRANSCRIPTION_ENGINE,
    "@objc func crashLogMailAttachments() -> [ICDiagnosticMailAttachment] {",
    "    @objc func crashLogMailBody() -> String {",
)

require(
    "combinedCrashLogMailAttachmentData" in attachments_body,
    "Crash-log mail attachments must be combined into one generated file for simpler handling.",
)
require(
    attachments_body.count("ICDiagnosticMailAttachment(") == 1,
    "Crash-log mail must create exactly one attachment.",
)
require(
    '"Diagnostics.jsonl"' in attachments_body
    and '"DiagnosticsSessionState.json"' in attachments_body
    and '"Application.Log"' in attachments_body,
    "The single crash-log attachment must still include diagnostics, session state, and application log contents.",
)

require(
    "@objc func clearCrashLogMailArtifacts()" in TRANSCRIPTION_ENGINE,
    "ICDiagnosticLogger must expose a method to clear sent crash-log artifacts.",
)

clear_body = source_between(
    TRANSCRIPTION_ENGINE,
    "@objc func clearCrashLogMailArtifacts()",
    "    @objc func logStorageLayout",
)
require(
    "Diagnostics.jsonl" in clear_body and "Application.Log" in clear_body,
    "Clearing sent crash logs must remove the diagnostic and application log files.",
)
require(
    "DiagnosticsSessionState.json" not in clear_body,
    "Clearing sent crash logs must preserve the live session-state file so future crash detection still works.",
)

require(
    "@property (nonatomic) BOOL sendingCrashLogMail;" in OPTIONS,
    "OptionsViewController must track whether the active mail composer is a crash-log mail.",
)
require(
    "self.sendingCrashLogMail = YES;" in OPTIONS,
    "Crash-log mail presentation must mark the composer as crash-log mail.",
)

mail_finish = source_between(
    OPTIONS,
    "- (void)mailComposeController:(MFMailComposeViewController*)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError*)error",
    "@end",
)
require(
    "result == MFMailComposeResultSent" in mail_finish,
    "Crash logs must only be cleared after Mail reports a sent message.",
)
require(
    "clearCrashLogMailArtifacts" in mail_finish,
    "OptionsViewController must clear crash-log artifacts after a successful crash-log mail send.",
)
require(
    "self.sendingCrashLogMail = NO;" in mail_finish,
    "OptionsViewController must reset the crash-log mail flag after any mail composer result.",
)
