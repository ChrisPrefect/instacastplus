#!/usr/bin/env python3
"""Keep browser diagnostics in uploaded logs without changing WebKit recovery."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Classes/WebController.m").read_text()
logger = (ROOT / "Classes/TranscriptionEngine.swift").read_text()


def method(signature):
    assert signature in source, f"Missing browser diagnostic callback: {signature}"
    return source.split(signature, 1)[1].split("\n- (", 1)[0]


provisional = method("didFailProvisionalNavigation:")
assert '_logBrowserFailure:@"provisional-failure"' in provisional
assert "[self _finishLoading]" in provisional, (
    "A provisional failure must balance didStartProvisionalNavigation's loading retain"
)
assert not any(action in provisional for action in (
    "reload", "stopLoading", "dismissViewController", "self.failed =",
)), "Provisional diagnostics must only observe the failure."

finish_loading = method("- (void) _finishLoading")
assert "if (_loading <= 0)" in finish_loading
assert "[App releaseNetworkActivity]" in finish_loading
assert "_loading--;" in finish_loading

for signature, event in (
    ("didStartProvisionalNavigation:", "navigation-start"),
    ("didReceiveServerRedirectForProvisionalNavigation:", "server-redirect"),
    ("didCommitNavigation:", "navigation-commit"),
    ("didFinishNavigation:", "navigation-finish"),
    ("didFailNavigation:", "navigation-failure"),
):
    assert f'@"{event}"' in method(signature), f"Missing event: {event}"

failure = method("- (void)_logBrowserFailure:")
for field in ("errorDomain", "errorCode", "failingURL", "underlyingDomain", "underlyingCode"):
    assert f'@"{field}"' in failure, f"Missing failure detail: {field}"
assert "ICBrowserDiagnosticURL" in failure

event = method("- (void)_logBrowserEvent:")
assert '[[ICDiagnosticLogger shared] logEvent:@"browser"' in event
assert "#if" not in event and "DebugLog(" not in event
for field in ("browserID", "initialURL", "currentURL", "isLoading", "progress", "webViewFrame"):
    assert f'@"{field}"' in event, f"Missing browser state: {field}"
assert '"Diagnostics.jsonl"' in logger.split("@objc func crashLogMailAttachments", 1)[1].split("@objc func crashLogMailBody", 1)[0]

disappear = method("- (void) viewWillDisappear:")
assert disappear.index('@"stop-loading"') < disappear.index("[self.webView stopLoading]")
for field in ("reason", "beingDismissed", "navigationBeingDismissed", "movingFromParent"):
    assert f'@"{field}"' in disappear
failure_callback = method("didFailNavigation:")
assert failure_callback.index("_logBrowserFailure:") < failure_callback.index("kCFURLErrorCancelled")

# Installing this delegate callback disables WebKit's own crash-reload handling.
assert "webViewWebContentProcessDidTerminate:" not in source
assert "decidePolicyForNavigationAction:" not in source, "Keep WebKit's default external-app routing."
response = method("decidePolicyForNavigationResponse:")
assert "navigationResponse.canShowMIMEType" in response
assert "response.URL.isFileURL" in response and "isDirectory" in response
assert response.count("decisionHandler(") == 1
assert "canShow ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyCancel" in response

sanitize = source.split("static NSString* ICBrowserDiagnosticURL", 1)[1].split("@interface", 1)[0]
for field in ("user", "password", "query", "fragment"):
    assert f"components.{field} = nil;" in sanitize

print("Browser diagnostics regression checks passed.")
