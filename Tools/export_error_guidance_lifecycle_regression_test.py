#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


for property_name in [
    "pendingFullExportURL", "pendingFullExportError",
    "pendingSubscriptionsExportURL", "pendingSubscriptionsExportError",
    "pendingBookmarksExportURL", "pendingBookmarksExportError",
]:
    require(f"- (void)set{property_name[0].upper() + property_name[1:]}:" in SOURCE,
            f"{property_name} must use shared storage so results survive controller replacement.")

for method in [
    "- (void)presentPendingFullExportResultIfNeeded",
    "- (void)presentPendingSubscriptionsExportResultIfNeeded",
    "- (void)presentPendingBookmarksExportResultIfNeeded",
]:
    method_body = body(method)
    require("error.localizedDescription" in method_body,
            "Export errors must show their concrete cause instead of always claiming storage is full.")
    require("[self _presentExportURL:url]" in method_body,
            "A successful export must be handed to the system share sheet.")

share = body("- (void)_presentExportURL:")
require("UIActivityViewController" in share and "completionWithItemsHandler" in share,
        "Export sharing must use the retained system activity controller and finish its lifecycle on dismissal.")


print("Export error-guidance lifecycle regression checks passed")
