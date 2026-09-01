from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()


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


logger = QUEUE.split("@objc class TranscriptionLogger", 1)[1].split(
    "// MARK: - Queue Item", 1
)[0]
append = function_body(logger, "@objc func append(")
persist = function_body(logger, "private func persist(episodeHash:")
clear = function_body(logger, "@objc func clearLog(")
reset = function_body(logger, "@objc func resetLog(")

require(
    "private let persistenceQueue = DispatchQueue(" in logger and "qos: .utility" in logger,
    "Transcription log persistence still has no serial utility queue.",
)
require(
    "private struct StoredEntry: Codable, Sendable" in logger,
    "Immutable transcription log snapshots are not explicitly sendable to the persistence queue.",
)
require(
    append.find("cache[episodeHash] = entries") < append.find("persist(episodeHash: episodeHash)"),
    "A log append can persist before the main-actor cache contains the new entry.",
)
require(
    "let storedSnapshot =" in persist
    and "let destinationURL =" in persist
    and "persistenceQueue.async" in persist
    and persist.find("let storedSnapshot =") < persist.find("persistenceQueue.async")
    and persist.find("let destinationURL =") < persist.find("persistenceQueue.async")
    and persist.find("JSONEncoder().encode(storedSnapshot)") > persist.find("persistenceQueue.async")
    and persist.find("data.write(to: destinationURL") > persist.find("persistenceQueue.async"),
    "Log snapshots are not encoded and written off the main actor in FIFO order.",
)
require(
    "JSONEncoder().encode" not in persist.split("persistenceQueue.async", 1)[0]
    and "data.write" not in persist.split("persistenceQueue.async", 1)[0],
    "Transcription log encoding or disk writing still runs on the main actor.",
)
for body, operation in ((clear, "clear"), (reset, "reset")):
    require(
        "cache[episodeHash] = []" in body
        and "removePersistedLog(episodeHash: episodeHash)" in body
        and "removeItem" not in body,
        f"Transcription log {operation} is not ordered with pending writes or can reload stale disk state.",
    )

remove = function_body(logger, "private func removePersistedLog(episodeHash:")
require(
    "let destinationURL =" in remove
    and "persistenceQueue.async" in remove
    and remove.find("removeItem(at: destinationURL)") > remove.find("persistenceQueue.async"),
    "Log removal still performs disk I/O on the main actor or races queued snapshots.",
)
require(
    "asyncAfter" not in logger and "sleep(" not in logger,
    "Transcription log persistence must not rely on timing delays.",
)


print("transcription logger async persistence regression: ok")
