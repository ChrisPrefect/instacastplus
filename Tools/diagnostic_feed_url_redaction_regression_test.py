#!/usr/bin/env python3
"""Pins redaction of credential-bearing feed URLs in exportable diagnostics."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Classes" / "UtilityFunctions.h").read_text()
IMPLEMENTATION = (ROOT / "Classes" / "UtilityFunctions.m").read_text()
LOGGER = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
BRIDGE = (ROOT / "Instacast-Bridging-Header.h").read_text()
DIRECT_LOG_SOURCES = "\n".join(
    (ROOT / path).read_text()
    for path in (
        "Classes/InstacastBackupImporter.m",
        "Classes/Model/EpisodeLoadingManager.m",
        "Classes/Model/CDFeed.m",
        "Classes/Parser/ICFeedParser.m",
        "Classes/Model/SubscriptionManager.m",
    )
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("ICRedactedURLStringForLogging" in HEADER and
        "ICRedactedURLStringForLogging" in IMPLEMENTATION,
        "Feed URL redaction needs one shared Objective-C/Swift helper.")
require("UtilityFunctions.h" in BRIDGE,
        "The diagnostic logger must use the same URL redactor as Objective-C error logs.")

redactor_start = IMPLEMENTATION.find("NSString* ICRedactedURLStringForLogging")
redactor_end = len(IMPLEMENTATION)
require(redactor_start != -1 and redactor_end != -1, "URL redactor implementation boundary is missing.")
redactor = IMPLEMENTATION[redactor_start:redactor_end]
for secret_component in ("components.user = nil", "components.password = nil",
                         "components.path =", "components.query = nil", "components.fragment = nil"):
    require(secret_component in redactor,
            f"URL redactor must remove every credential/token-bearing component: {secret_component}")
require("CC_SHA256" in redactor,
        "Redacted URLs need only a stable one-way fingerprint for correlation.")

logger_method_start = LOGGER.find("private func stringifiedMetadata")
logger_method_end = LOGGER.find("private func currentMemorySnapshot", logger_method_start)
require(logger_method_start != -1 and logger_method_end != -1,
        "Diagnostic metadata conversion boundary is missing.")
logger_method = LOGGER[logger_method_start:logger_method_end]
require('range(of: "url", options: .caseInsensitive)' in logger_method and
        "ICRedactedURLStringForLogging" in logger_method,
        "Every URL-labelled Diagnostics.jsonl metadata value must be centrally redacted.")

for raw_expression in (
    "resolvedFeedURL, saveError",
    "database is unavailable: %@\", feedURL",
    "[self.sourceURL absoluteString], [error description]",
    "elementContent, [self.url absoluteString]",
    "url.absoluteString, error.localizedDescription",
):
    require(raw_expression not in DIRECT_LOG_SOURCES,
            f"Application.Log still contains a raw feed URL call site: {raw_expression}")
require(DIRECT_LOG_SOURCES.count("ICRedactedURLStringForLogging") >= 10,
        "All direct feed URL diagnostics must use the shared redactor.")

print("Diagnostic feed URL redaction regression checks passed")
