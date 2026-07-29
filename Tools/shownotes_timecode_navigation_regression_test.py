#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def objc_method(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")

    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method body: {signature}")


source = (ROOT / "Classes" / "EpisodeViewController.m").read_text()
navigation = objc_method(
    source,
    "- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler",
)
delegate_branch = navigation.split(
    'if ([[url scheme] isEqualToString:@"delegate"])',
    1,
)[1].split("// do not allow iframes", 1)[0]

require(
    'if ([command isEqualToString:@"play-chapter-timecode"])' in delegate_branch
    and "[self _startPlaybackAtTime:time];" in delegate_branch,
    "Show Notes timecode links must still seek playback to the parsed chapter time.",
)
require(
    "decisionHandler(WKNavigationActionPolicyCancel);\n        return;" in delegate_branch,
    "Handled Show Notes timecode links must cancel the custom-scheme navigation and return immediately.",
)
require(
    "decisionHandler(WKNavigationActionPolicyAllow)" not in delegate_branch,
    "A handled Show Notes timecode link must not call WebKit's decision handler more than once.",
)

print("Show Notes timecode navigation regression checks passed.")
