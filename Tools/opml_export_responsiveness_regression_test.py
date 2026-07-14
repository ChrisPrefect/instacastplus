#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()
MANAGER = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
HEADER = (ROOT / "Classes" / "Model" / "SubscriptionManager.h").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
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
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


export_start = body(CONTROLLER, "- (void) exportSubscriptions")
export = body(CONTROLLER, "- (void)_beginSubscriptionsExportAfterBusyState")
builder = body(MANAGER, "- (void)opmlDataWithCompletion:")
cell = body(CONTROLLER, "- (UITableViewCell *)tableView:")
present = body(CONTROLLER, "- (void)presentPendingSubscriptionsExportResultIfNeeded")

require("opmlDataWithCompletion:" in HEADER and "- (NSData*) opmlData" not in HEADER,
        "OPML export must expose an asynchronous API instead of a main-thread data builder.")
require("newExportBackgroundContext" in builder and "QOS_CLASS_UTILITY" in builder
        and "NSDictionaryResultType" in builder and "propertiesToFetch" in builder,
        "OPML generation must fetch only its required feed fields on the dedicated export context.")
require("dispatch_get_main_queue" in builder,
        "The asynchronous OPML API must return its result on the main queue.")
require("anyExportInProgress" in export_start and "dispatch_get_global_queue" in export
        and "writeToURL:url options:NSDataWritingAtomic error:" in export,
        "The controller must prevent duplicate exports and check the off-main atomic file write.")
require("UIActivityIndicatorView" in cell and "subscriptionsExportInProgress" in cell,
        "The subscriptions row must show visible activity while its export is running.")
require("pendingSubscriptionsExportURL" in present and "pendingSubscriptionsExportError" in present
        and "self.viewIfLoaded.window" in present,
        "Export completion must wait for a visible settings screen before presenting share or error UI.")


print("OPML export responsiveness regression checks passed")
