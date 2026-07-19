from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHAPTERS = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, "Missing function: " + signature)
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    raise SystemExit("Unterminated function: " + signature)


openai = function_body(CHAPTERS, "private func generateOpenAIAPIJSONObject(")
require(
    "isDefiniteOpenAICreateRejection" in openai
    and 'reason: "resume-after-definite-create-rejection"' in openai
    and "removeOpenAIBackgroundAnalysisJob" in openai,
    "A persisted HTTP create rejection without a response ID permanently blocks every automatic retry.",
)
require(
    openai.find("isDefiniteOpenAICreateRejection")
    < openai.find('request.httpMethod = "POST"'),
    "The definite create rejection is not reconciled before issuing the replacement POST.",
)

classifier = function_body(CHAPTERS, "private func isDefiniteOpenAICreateRejection(")
for token in [
    "job.state == .terminal",
    "job.responseID == nil",
    'job.providerStatus == "create_http_429"',
]:
    require(token in classifier, "Unsafe create-rejection classifier: " + token)
require(
    "hasPrefix" not in classifier,
    "A potentially side-effecting 5xx response is still treated as a definitely rejected create.",
)
require(
    "isPotentiallyAmbiguousOpenAICreateStatus" in openai
    and 'reason: "create-outcome-ambiguous"' in openai
    and "job.state = .submitting" in openai,
    "OpenAI create 408/409/425/5xx outcomes are not kept in the non-duplicating ambiguous state.",
)

print("Remote create rejection regression checks passed.")
