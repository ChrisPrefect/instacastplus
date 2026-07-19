from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
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


loader = function_body(QUEUE, "private func loadCuesForChapterGeneration(episodeHash:")
require(
    "async throws" in QUEUE[
        QUEUE.find("private func loadCuesForChapterGeneration") :
        QUEUE.find("private func loadCuesForChapterGeneration") + 180
    ],
    "Podcast transcript download/validation errors are still collapsed into an empty cue list.",
)
require(
    "try await loadPodcastTranscriptData" in loader
    and "lastTransientError" in loader
    and "throw lastTransientError" in loader,
    "External transcript transport failures are not preserved for automatic retry.",
)
require(
    "saveImportedTranscriptCues" in loader
    and "loadCuesFromSRT(url: srtURL)" in loader,
    "A downloaded Podcasting 2.0 transcript is not committed to SRT before analysis.",
)

chapter_task = function_body(QUEUE, "private func startChapterGenerationTask(for item:")
require(
    "try await self.loadCuesForChapterGeneration" in chapter_task
    and 'scheduleRetry(for: item, error: error, stage: "transcript-import")' in chapter_task,
    "A transient external-transcript failure becomes terminal instead of a persisted retry.",
)
require(
    "prepareAutomaticTranscriptionAfterUnusableExternalTranscript" in chapter_task,
    "An automatic analysis job cannot transition to audio transcription when its advertised transcript has no usable timeline.",
)
transition = function_body(QUEUE, "private func prepareAutomaticTranscriptionAfterUnusableExternalTranscript(")
require(
    "item.automaticallyScheduled" in transition
    and 'failure.domain == "TranscriptionQueue.TranscriptValidation"' in transition
    and "TranscriptURLSecurity" not in transition
    and "!engine.hasSRT" in transition
    and "item.chapterOnly = false" in transition
    and "item.shouldGenerateAnalysis" in transition,
    "The unusable-transcript transition is not restricted to the intended automatic full pipeline.",
)

parser = function_body(QUEUE, "private func parseTranscriptData(")
require(
    "return []" in parser and "parsePlainTranscript" not in parser,
    "Untimed plain text is still accepted as a reliable chapter timeline.",
)
require(
    "private func parsePlainTranscript" not in QUEUE and "3153600000.0" not in QUEUE,
    "The fabricated 100-year cue fallback still exists in the analysis pipeline.",
)
normalizer = function_body(QUEUE, "private func normalizeTranscriptCues(")
require(
    "cue.start + 2" not in normalizer
    and "nextCue.start" not in normalizer
    and "end > cue.start" in normalizer
    and "previousEnd" in normalizer
    and "return []" in normalizer,
    "Malformed external transcript timing is still fabricated instead of rejected.",
)

url_attempts = function_body(QUEUE, "private func appendTranscriptURLAttempt(")
require(
    'scheme == "http" || scheme == "https"' in url_attempts
    and 'schemes.append("https")' in url_attempts
    and 'schemes.append("http")' in url_attempts,
    "Podcast transcript discovery does not accept the public HTTP/HTTPS URLs used by feeds.",
)

transport = function_body(QUEUE, "private func loadPodcastTranscriptData(")
require(
    "URLSession.shared.data(for: request)" in transport
    and "timeoutInterval: 30.0" in transport
    and "url.isFileURL" not in transport,
    "Public podcast transcripts no longer use the normal URLSession transport.",
)
require(
    'domain: "TranscriptionQueue.TranscriptHTTP"' in transport
    and '"HTTPStatusCode": httpResponse.statusCode' in transport
    and "data.count <= Self.maximumPodcastTranscriptBytes" in transport,
    "Podcast transcript HTTP failures or the response-size limit are not preserved.",
)
require(
    'message: "Podcast-Transkript geladen"' in transport
    and "Endpunkt validiert" not in transport
    and "sicher geladen" not in transport,
    "Transcript diagnostics still describe public text as a special security transport.",
)
require(
    "import Network" not in QUEUE
    and "import Security" not in QUEUE
    and "NWConnection" not in QUEUE
    and "getaddrinfo" not in QUEUE
    and "ICPodcastTranscriptHTTPParser" not in QUEUE
    and "validatedPodcastTranscriptEndpoint" not in QUEUE,
    "Podcast transcripts still use a duplicate DNS-pinned HTTP stack instead of URLSession.",
)

auth_scope = function_body(QUEUE, "private func podcastTranscriptMayUseFeedCredentials(")
require(
    "episode.feed?.sourceURL" in auth_scope
    and "originTuple" in auth_scope
    and "podcastTranscriptMayUseFeedCredentials(url, episode: episode)" in transport,
    "Private-feed credentials can still be forwarded to a cross-origin transcript host.",
)

save_import = function_body(ENGINE, "func saveImportedTranscriptCues(")
require(
    "writeSRT" in save_import and "invalidateSRTCache(for: episodeHash)" in save_import,
    "Imported timed cues do not atomically commit and invalidate the engine's cached SRT membership.",
)
write_srt = function_body(ENGINE, "private func writeSRT(")
require("atomically: true" in write_srt, "The shared SRT commit is not atomic.")

print("External transcript persistence regression checks passed.")
