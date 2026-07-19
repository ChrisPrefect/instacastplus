from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHAPTERS = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()


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


token = function_body(CHAPTERS, "func terminalOpenAIBackgroundJobToken(")
retire = function_body(
    CHAPTERS,
    "func retireTerminalOpenAIBackgroundJobAfterPersistedRetry(",
)
for method, label in ((token, "token"), (retire, "retirement")):
    require(
        "job.state == .terminal || job.state == .rejected" in method,
        "A locally rejected billed response is excluded from automatic replacement " + label + ".",
    )
    require(
        "job.responseID" in method,
        "Rejected-response replacement is not tied to a confirmed billed response ID.",
    )

retry = function_body(QUEUE, "private func scheduleRetry(for item:")
require(
    "let terminalOpenAIJob = chapterGen.terminalOpenAIBackgroundJobToken" in retry
    and "Self.isTransientPipelineError(error) || hasConfirmedTerminalOpenAIJob" in retry,
    "A locally rejected billed response remains permanently failed instead of entering the bounded replacement path.",
)
require(
    "maximumAutomaticRemoteAnalysisReplacements" in retry
    and "remoteAnalysisReplacementAttempts += 1" in retry
    and "retireTerminalOpenAIBackgroundJobAfterPersistedRetry" in retry,
    "Rejected output replacement bypasses the existing persisted cost budget.",
)

print("Remote rejected response replacement regression checks passed.")
