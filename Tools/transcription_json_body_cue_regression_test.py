#!/usr/bin/env python3
"""JSON podcast transcripts using `body` must render as timed text, not raw JSON.

Regression: TestFlight build 4.0 (35) displayed an array of objects with
`speaker`, `startTime`, `endTime`, and `body` verbatim in the player.
"""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLAYER = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing declaration: {signature}")
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
    raise SystemExit(f"Unterminated declaration: {signature}")


fixture = json.loads(
    '[{"speaker":"","startTime":7323.172999999998,'
    '"endTime":7328.762999999999,"body":"Das war ein interessanter Beitrag."}]'
)
cue = fixture[0]
require(cue["startTime"] < cue["endTime"], "Fixture must contain a timed transcript cue.")
require(cue["body"] == "Das war ein interessanter Beitrag.", "Fixture must model the reported body text.")

player_extractor = body(PLAYER, "static NSString* ICTranscriptStringFromJSONDictionary")
require(
    '@"body"' in player_extractor,
    "The player JSON transcript parser ignores the reported `body` cue text and falls back to raw JSON.",
)
require(
    '@"startTime"' in body(PLAYER, "static void ICTranscriptCollectJSONCues")
    and '@"endTime"' in body(PLAYER, "static void ICTranscriptCollectJSONCues"),
    "The player parser must retain the fixture's timed cue bounds.",
)

queue_extractor = body(QUEUE, "private func firstTranscriptTextValue(in dict: [String: Any])")
require(
    '"body"' in queue_extractor,
    "Chapter generation imports the same JSON format, so it must recognize `body` too.",
)

print("JSON body transcript regression checks passed")
