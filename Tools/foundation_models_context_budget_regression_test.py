#!/usr/bin/env python3
"""Pin schema- and response-aware Foundation Models context budgeting.

TestFlight build 4.0 (32) failed chapter generation with
`exceededContextWindowSize` even though the visible prompt had passed the
preflight check. Guided generation adds its schema and response to the same
context window, so all three inputs must share one explicit budget.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.index(signature)
    brace = SOURCE.index("{", start)
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated declaration: {signature}")


require(
    "foundationMaximumResponseTokens" in SOURCE
    and "foundationContextSafetyTokens" in SOURCE,
    "Foundation Models requests still have no explicit response and safety budget.",
)

fits = body("private func foundationPromptFitsContext")
require(
    "Content.generationSchema" in fits
    and "model.tokenCount(for: schema)" in fits,
    "The preflight check still ignores the guided-generation schema tokens.",
)
require(
    "promptTokens + schemaTokens + Self.foundationMaximumResponseTokens"
    in fits
    and "Self.foundationContextSafetyTokens" in fits
    and "model.contextSize" in fits,
    "Prompt, schema, bounded response, and safety tokens do not share the model's real context budget.",
)

for generated_type in ("GeneratedTopicMarkersList", "GeneratedChaptersList"):
    require(
        f"foundationPromptFitsContext" in SOURCE
        and f"generating: {generated_type}.self" in SOURCE,
        f"Context preflight is not tied to the exact {generated_type} schema.",
    )

responses = SOURCE.count(
    "options: GenerationOptions(maximumResponseTokens: Self.foundationMaximumResponseTokens)"
)
require(
    responses == SOURCE.count("LanguageModelSession()"),
    "Every Foundation Models session must enforce the same response-token limit used by preflight.",
)

print("Foundation Models context-budget regression checks passed")
