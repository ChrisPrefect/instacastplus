from pathlib import Path
from typing import Optional, Tuple


ROOT = Path(__file__).resolve().parents[1]
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    raise SystemExit(f"Unterminated function: {signature}")


for field in (
    "lastCountedRemoteAnalysisJobKey",
    "lastCountedRemoteAnalysisResponseID",
):
    require(QUEUE.count(field) >= 6, f"Remote replacement identity is not durably round-tripped: {field}")

retry = function_body(QUEUE, "private func scheduleRetry(for item:")
require(
    "terminalOpenAIJob.jobKey" in retry
    and "terminalOpenAIJob.responseID" in retry
    and "lastCountedRemoteAnalysisJobKey" in retry
    and "lastCountedRemoteAnalysisResponseID" in retry,
    "A confirmed terminal response is not deduplicated by its persisted provider identity.",
)
require(
    "remoteAnalysisReplacementAttempts += 1" in retry
    and "terminalOpenAIJob != nil" not in retry,
    "The replacement budget still counts an unconfirmed create failure or counts one response twice.",
)


def count_once(state: dict, token: Optional[Tuple[str, str]]) -> None:
    if token is None:
        return
    if token == state.get("last"):
        return
    state["attempts"] += 1
    state["last"] = token


state = {"attempts": 0, "last": None}
count_once(state, None)  # create 429/5xx: no confirmed provider identity
count_once(state, ("job-a", "resp-a"))
count_once(state, ("job-a", "resp-a"))  # kill before manifest retirement
count_once(state, ("job-b", "resp-b"))
require(state == {"attempts": 2, "last": ("job-b", "resp-b")}, (
    "The replacement state-machine fixture did not preserve exactly-once counting."
))

print("Remote replacement budget regression checks passed.")
