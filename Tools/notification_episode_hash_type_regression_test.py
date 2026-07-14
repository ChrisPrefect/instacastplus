#!/usr/bin/env python3
"""Pins notification episode identifiers to validated string payloads."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


interaction = method_body("- (void)_performNotificationInteractionWithUserInfo:")
top_level_value = interaction.find('userInfo[@"episode_hash"]')
top_level_check = interaction.find("[topLevelEpisodeHash isKindOfClass:NSString.class]", top_level_value)
nested_value = interaction.find('aps[@"episode_hash"]')
nested_check = interaction.find("[nestedEpisodeHash isKindOfClass:NSString.class]", nested_value)
length_use = interaction.find("episodeHash.length")
require(
    -1 < top_level_value < top_level_check < length_use
    and -1 < nested_value < nested_check < length_use,
    "Both top-level and aps episode_hash values must be type-checked before NSString selectors are used.",
)

print("Notification episode-hash type regression checks passed")
