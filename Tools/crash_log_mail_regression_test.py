#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature):
    require(signature in source, f"{signature} is missing.")
    return source.split(signature, 1)[1].split("\n- (", 1)[0]


LOGGER = read("Classes/TranscriptionEngine.swift")
OPTIONS = read("Classes/OptionsViewController.m")
EN_STRINGS = read("Resources/en.lproj/Localizable.strings")
DE_STRINGS = read("Resources/de.lproj/Localizable.strings")

require("@objc class ICDiagnosticMailAttachment" in LOGGER, "Diagnostic mail attachments must be exposed to Objective-C.")
for property_name in ["fileName", "mimeType", "data"]:
    require(f"@objc let {property_name}" in LOGGER, f"Diagnostic mail attachment must expose {property_name}.")

require("@objc static var isTestFlightBuild: Bool" in LOGGER, "TestFlight detection must remain available to the diagnostic logger.")

require('category: "crash"' in LOGGER and "Vorherige Session unerwartet beendet" in LOGGER, "Unexpected previous sessions must be logged as local crash diagnostics.")
require("previousSessionEndedUnexpectedly" in LOGGER, "Crash log exports must include previous-session crash state.")

attachments = LOGGER.split("@objc func crashLogMailAttachments", 1)[1].split("\n    }", 1)[0]
for file_name in ["Diagnostics.jsonl", "DiagnosticsSessionState.json", "Application.Log"]:
    require(file_name in attachments, f"Crash log mail must attach {file_name}.")
require("combinedCrashLogMailAttachmentData" in attachments, "Crash log mail attachments must be combined into one NSData payload for MFMailComposeViewController.")
require(attachments.count("ICDiagnosticMailAttachment(") == 1, "Crash log mail must create exactly one attachment.")

body = LOGGER.split("@objc func crashLogMailBody", 1)[1].split("\n    }", 1)[0]
for key in ["previousSessionEndedUnexpectedly", "previousSessionState", "appVersion", "build"]:
    require(key in body, f"Crash log mail body must include {key}.")

require("kRowCrashLogs" in OPTIONS, "Settings must define a crash-log mail row.")
require("crashLogMailAvailable" not in OPTIONS, "Settings must not gate the crash-log row by build type.")
require("[ICDiagnosticLogger isTestFlightBuild]" not in OPTIONS, "Settings must not consult TestFlight state for crash-log row visibility.")

row_mapping = method_body(OPTIONS, "- (NSInteger)settingsRowForIndexPath:")
require("kRowCrashLogs" not in row_mapping, "Settings row mapping must never skip the crash-log row.")
row_count = method_body(OPTIONS, "- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:")
require("kRowCrashLogs" not in row_count and row_count.count("rows--") == 2, "Settings row count must include the crash-log row in every build.")

cell_body = method_body(OPTIONS, "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:")
require('"Crash Logs per Mail schicken".ls' in cell_body, "Settings must show the requested crash-log mail button text.")
require('systemImageNamed:@"doc.text.magnifyingglass"' in cell_body, "Crash-log mail row must have a diagnostic document icon.")

selection_body = method_body(OPTIONS, "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:")
require("case kRowCrashLogs" in selection_body and "[self emailCrashLogsClicked]" in selection_body, "Selecting the crash-log row must open the crash-log mail composer.")

mail_body = method_body(OPTIONS, "- (void)emailCrashLogsClicked")
require('setToRecipients:@[@"info@instacast.ch"]' in mail_body, "Crash-log mail must be addressed to info@instacast.ch.")
require("crashLogMailAttachments" in mail_body, "Crash-log mail must use diagnostic logger attachments.")
require("addAttachmentData" in mail_body, "Crash-log mail must attach local diagnostic files.")
require("crashLogMailBody" in mail_body, "Crash-log mail must include diagnostic summary body text.")

for strings, language in [(EN_STRINGS, "English"), (DE_STRINGS, "German")]:
    for key in ["Crash Logs per Mail schicken", "Crash Logs InstacastPlus"]:
        require(f'"{key}" =' in strings, f"{language} localization is missing {key}.")
