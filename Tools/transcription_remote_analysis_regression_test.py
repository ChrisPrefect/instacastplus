from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHAPTERS = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
ENGINE = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    raise SystemExit(f"Unterminated body: {signature}")


for identifier, remote_name in [
    ("openai-codex-gpt-5.6-sol-oauth", "gpt-5.6-sol"),
    ("openai-gpt-5.6-terra-api-key", "gpt-5.6-terra"),
    ("anthropic-claude-sonnet-5-api-key", "claude-sonnet-5"),
    ("kimi-k3-api-key", "kimi-k3"),
]:
    require(
        f'identifier: "{identifier}"' in ENGINE
        and f'remoteModelName: "{remote_name}"' in ENGINE,
        f"Current remote analysis model is missing: {identifier} -> {remote_name}",
    )

selected_model = function_body(ENGINE, "static func selectedModel(for role:")
for old_identifier, new_identifier in [
    ("openai-codex-oauth", "openai-codex-gpt-5.6-sol-oauth"),
    ("anthropic-claude-opus-4.7-api-key", "anthropic-claude-sonnet-5-api-key"),
    ("kimi-k2.6-api-key", "kimi-k3-api-key"),
]:
    require(
        f'"{old_identifier}": "{new_identifier}"' in ENGINE,
        f"Selected legacy model is not migrated to its explicit successor: {old_identifier}",
    )
require(
    "legacyChapterModelSuccessors[identifier]" in selected_model,
    "Legacy model migration is not scoped to the selected chapter model.",
)
require(
    '"openai-chatgpt-5.5-api-key": "openai-gpt-5.6-terra-api-key"' not in ENGINE,
    "A legacy private request is silently migrated to stored OpenAI Background Responses without explicit user selection.",
)

analysis = function_body(CHAPTERS, "func analyzeEpisodeAsync(fromCues cues:")
require(
    "RemoteEpisodeAnalysisResponse" in CHAPTERS
    and "remoteEpisodeAnalysisSchema" in CHAPTERS,
    "The single structured chapter/sponsor/summary response is missing.",
)
require(
    "buildRemoteEpisodeAnalysisPrompt" in analysis
    and "generateRemoteJSONObject" in analysis,
    "Remote episode analysis does not submit one full-transcript structured request.",
)
require(
    "timelineDuration: Double" in CHAPTERS[
        CHAPTERS.find("func analyzeEpisodeAsync(fromCues cues:") :
        CHAPTERS.find("func analyzeEpisodeAsync(fromCues cues:") + 500
    ]
    and "timelineDuration: timelineDuration" in analysis,
    "Full analysis is not bound to the complete media timeline beyond the first/last speech cue.",
)
require(
    analysis.count("generateRemoteJSONObject") == 1,
    "Remote episode analysis must use exactly one model request; no second sponsor or summary pass.",
)
require(
    "makeAnalysisResult" in analysis
    and "existingChapters" in analysis,
    "The analysis response is not validated and overlaid onto publisher chapters.",
)

sponsor_conversion = function_body(
    CHAPTERS,
    "private static func generatedSponsorSegments(from segments:",
)
generated_chapters = function_body(
    CHAPTERS,
    "private static func generatedChapters(from starts:",
)
require(
    "offset == 0 ? 0" in generated_chapters
    and "timelineDuration" in generated_chapters
    and "cues.last!.end" not in generated_chapters,
    "Generated base chapters still omit non-speech pre-roll or post-roll from the media timeline.",
)
require(
    "evidenceIndices == Array(startIndex...endIndex)" in sponsor_conversion,
    "A sponsor's automatic skip interval is not fully anchored by contiguous evidence cues.",
)
sponsor_validation = function_body(
    CHAPTERS,
    "@objc func validateSponsorSegments(_ sponsorSegments:",
)
require(
    "expectedEvidenceIndices == Array(segmentStartCueIndex...segmentEndCueIndex)" in sponsor_validation,
    "Persisted sponsor intervals can still extend beyond their transcript evidence.",
)
require(
    "isValidSponsorChapterTitle(title)" in sponsor_conversion
    and "isValidSponsorChapterTitle(title)" in sponsor_validation
    and 'private static func isValidSponsorChapterTitle(_ title: String)' in CHAPTERS
    and 'let prefix = "Sponsor: "' in CHAPTERS
    and "title.hasPrefix(prefix)" in CHAPTERS
    and "dropFirst(prefix.count)" in CHAPTERS,
    "Remote sponsor results do not enforce the exact visible `Sponsor: ` prefix with a nonempty chapter name.",
)

prompt = function_body(CHAPTERS, "private func buildRemoteEpisodeAnalysisPrompt(")
for token in [
    "transcriptRevision",
    '"cue-\\(index)"',
    "existingChapters",
    "musicSegments",
    "Reine Musik",
    "Outro",
    "False Positives",
    "jede Cue-ID zwischen startCueID und endCueID",
    "Self.sponsorRecognitionRule",
    "Self.promotionSegmentationRule",
    "Self.promotionAuditRule",
]:
    require(token in prompt, f"Full-transcript analysis prompt is missing the grounding rule: {token}")

schema_start = CHAPTERS.find("private static let remoteEpisodeAnalysisSchema")
schema_end = CHAPTERS.find("private func", schema_start)
schema = CHAPTERS[schema_start:schema_end]
for key in [
    '"transcriptRevision"',
    '"chapterStarts"',
    '"startCueID"',
    '"sponsorSegments"',
    '"endCueID"',
    '"evidenceCueIDs"',
    '"summary"',
    '"additionalProperties": false',
]:
    require(key in schema, f"Strict episode-analysis schema is missing {key}.")

anthropic = function_body(CHAPTERS, "private func generateAnthropicJSONObject(")
require(
    '"output_config"' in anthropic
    and '"format"' in anthropic
    and '"type": "json_schema"' in anthropic,
    "Anthropic Structured Outputs must use Messages output_config.format.json_schema.",
)
require(
    '"temperature"' not in anthropic
    and '"top_p"' not in anthropic
    and '"top_k"' not in anthropic,
    "Claude Sonnet 5 must not receive unsupported sampling controls.",
)
require(
    "stop_reason" in CHAPTERS and "refusal" in CHAPTERS and "max_tokens" in CHAPTERS,
    "Anthropic refusals/truncated results are not rejected before JSON decoding.",
)

kimi_body = function_body(CHAPTERS, "private func kimiChatCompletionsBody(")
require(
    '"response_format"' in kimi_body
    and '"json_schema"' in kimi_body
    and '"strict": true' in kimi_body,
    "Kimi K3 analysis must keep strict JSON-schema output.",
)
require(
    '"thinking"' not in kimi_body,
    "Kimi K3 must use its required thinking mode; do not send thinking disabled.",
)

require(
    "func generateChaptersAsync(fromCues cues:" in CHAPTERS,
    "The existing chapter-only API must remain source-compatible.",
)
