from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


chapter_source = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
queue_source = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
runner_source = (ROOT / "Classes" / "LocalGGUFModelRunner.swift").read_text()
scene_delegate_source = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
app_delegate_source = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
project_source = (ROOT / "Instacast.xcodeproj" / "project.pbxproj").read_text()


require(
    "chapterQualityIssue(" in chapter_source
    and "erste themenbeschreibung" in chapter_source
    and "Kapitelerkennung fehlgeschlagen - Kapitelmodell lieferte nur ein generisches Gesamtkapitel." in chapter_source,
    "Chapter generation still accepts the observed one-chapter placeholder output instead of rejecting it.",
)

require(
    "validatedGeneratedChapters(" in chapter_source
    and "topicMarkerCount:" in chapter_source
    and "existingChapters == nil" in chapter_source,
    "Generated chapters are not quality-checked with topic-marker context before being returned.",
)

require(
    "_chapter_debug.json" in chapter_source
    and "recordLocalFinalOutput" in chapter_source
    and "recordValidation" in chapter_source,
    "Chapter generation does not persist enough debug trace data to inspect prompts, raw model output, and validation.",
)

require(
    "performanceEvents" in chapter_source
    and "chapter-performance" in chapter_source
    and "local-pass1-segment-derived" in chapter_source
    and "local-pass2-started" in chapter_source
    and "local-pass2-completed" in chapter_source
    and "durationSeconds" in chapter_source,
    "Chapter diagnostics still do not expose per-model-call timing and memory-sampled performance events.",
)

require(
    "recordPass1SegmentStarted" in chapter_source
    and "promptPreview" in chapter_source
    and "pass1-\\(index)-started" in chapter_source,
    "Chapter debugging still cannot show which local prompt is blocking before the model returns.",
)

require(
    "static func recommendedContextTokens() -> Int32 {\n        8_192\n    }" in runner_source
    and "stopAfterFirstJSONObject" in runner_source
    and "firstJSONObject(in:" in runner_source
    and "maxNewTokens: 384" in chapter_source,
    "Local GGUF chapter generation still allocates an oversized context or decodes too long past the completed JSON object.",
)

require(
    "llama_sampler_init_grammar" in runner_source
    and "jsonGrammar" in runner_source
    and "chapterJSONGrammar" in runner_source
    and "markerJSONGrammar" in runner_source
    and "installSampler(grammar:" in runner_source
    and "grammar: .chapters" in chapter_source
    and "grammar: .markers" in chapter_source
    and "case grammarLoadFailed" in runner_source,
    "Local GGUF chapter generation is not constrained to the expected JSON schema at the sampler level, so small local models can emit malformed chapter keys.",
)

require(
    "llama_sampler_accept(handle.sampler, nextToken)" not in runner_source,
    "Local GGUF generation manually accepts tokens after llama_sampler_sample, which already accepts them and crashes grammar sampling.",
)

require(
    "generateLocalJSONObject" in chapter_source
    and "withThrowingTaskGroup" in chapter_source
    and "localGenerationTimeoutNanoseconds" in chapter_source
    and "600 * 1_000_000_000" in chapter_source
    and "3_600 * 1_000_000_000" not in chapter_source
    and "Kapitelmodell hat nicht rechtzeitig geantwortet" in chapter_source,
    "Local GGUF chapter calls can still hang indefinitely instead of failing with an explicit timeout.",
)

require(
    "Kapitelmodell erstellt die finale JSON-Struktur" in chapter_source
    and "progress?(0.95, totalSegments, totalSegments + 1)" in chapter_source,
    "The long final chapter pass still looks like a stuck 98% operation instead of exposing a realistic user-facing status.",
)

require(
    "llama_set_abort_callback" in runner_source
    and "CancellationState" in runner_source
    and "nonisolated func requestCancel()" in runner_source
    and "result == 2" in runner_source,
    "Local GGUF cancellation still does not abort llama_decode at the C runtime boundary.",
)

require(
    "maximumTopicExtractionSegmentDuration" in chapter_source
    and "maximumTopicExtractionCueCount" in chapter_source
    and "maximumTopicExtractionSegmentDuration: Double = 300" in chapter_source
    and "maximumTopicExtractionCueCount = 45" in chapter_source
    and "segEnd - segStart > Self.maximumTopicExtractionSegmentDuration" in chapter_source,
    "Pass 1 still creates oversized single transcript prompts instead of bounded topic-extraction segments.",
)

require(
    "deterministicLocalTopicMarkers" in chapter_source
    and "deterministicMarkerTitle" in chapter_source
    and "local-deterministic-markers" in chapter_source,
    "Local Pass 1 still depends on slow model calls instead of deterministic transcript and music markers.",
)

require(
    "leadingMusicCuePrefixPattern" in chapter_source
    and "Musik Ja" in chapter_source,
    "Chapter title derivation still leaks leading Whisper music marker text into spoken-content chapter titles.",
)

require(
    "isSponsorCueText" in chapter_source
    and "werbepartner" in chapter_source
    and "werbung fuer" in chapter_source
    and "rabattcode" in chapter_source,
    "Chapter title derivation still marks generic mentions of ads as sponsor chapters instead of requiring explicit ad-read language.",
)

require(
    "isOutroCueText" in chapter_source
    and "duration >= 4" in chapter_source
    and "gesamtdauer" in chapter_source
    and "invalidStructuralChapterIssue" in chapter_source,
    "Chapter validation still accepts short music blips as full jingles or generic/outro garbage chapters.",
)

require(
    "sanitizeUnevidencedStructuralChapters" in chapter_source
    and "matchingMusicBoundary(" in chapter_source
    and "contentTitleForChapter(" in chapter_source
    and "isWeakChapterTitle" in chapter_source
    and "Strukturkapitel ohne Musikgrenze normalisiert" in chapter_source
    and "nicht fuer gesprochenen Teaser oder normale Inhaltsabschnitte" in chapter_source,
    "Final chapter generation still allows the model to label spoken cold opens or short music blips as Intro/Jingle/Outro without a matching music boundary.",
)

require(
    "chaptersByRemovingTerminalGenericChapters" in chapter_source
    and "Generische Schlusskapitel entfernt" in chapter_source
    and '"ende"' in chapter_source,
    "Final chapter generation still saves terminal garbage chapters such as 'Gesamtdauer' or 'Ende' after the real outro.",
)

require(
    "Du MUSST mindestens" in chapter_source
    and "nicht laenger als 240 Sekunden" in chapter_source
    and "Nutze die Markerzeiten als Kapitelstarts" in chapter_source,
    "Final chapter generation still lets the local model collapse many detected topic markers into one oversized content chapter.",
)

require(
    '"startedAt": Self.timestampString(Date())' in chapter_source
    and '"completedAt": Self.timestampString(Date())' in chapter_source,
    "Chapter debug traces still do not show exactly which model call is active or completed.",
)

require(
    "musicBoundaryChapters(from:" in chapter_source
    and "leadingMusicEnd" in chapter_source
    and "trailingMusicStart" in chapter_source,
    "Intro/outro chapter insertion still depends only on transcript speech boundaries and misses music-led boundaries.",
)

require(
    "earlyIntroWindow" in chapter_source
    and "chaptersByInsertingMusicChapter" in chapter_source
    and 'title: "Jingle"' in chapter_source,
    "Music-led chapter insertion still misses intro jingles after a cold open or meaningful mid-episode jingles.",
)

require(
    "isMusicOnlyCue" in chapter_source
    and "speechEnd <= lastMusic.start + tolerance" in chapter_source,
    "Outro boundaries still treat transcript-only music placeholders as speech and can create a sub-second outro.",
)

require(
    "missingMusicBoundaryIssue" in chapter_source
    and "Intro-/Outro-Musik wurde nicht als eigenes Kapitel erkannt" in chapter_source,
    "Chapter validation does not reject missing or incorrectly bounded intro/outro music chapters.",
)

require(
    "hasChapterBoundary(" not in chapter_source
    and "result.append(outro)" in chapter_source,
    "Music-led intro/outro insertion still refuses to replace model chapters that already start on the music boundary.",
)

require(
    "@objc func enqueueExistingEpisode" in queue_source
    and "@objc func debugQueueSnapshot" in queue_source
    and "@objc func debugInspection" in queue_source,
    "TranscriptionQueue does not expose the narrow control/inspection hooks needed for remote debugging.",
)

require(
    "@objc func generateChaptersForExistingEpisode" in queue_source
    and "guard ICDownloadableModelStore.selectedChapterModelIsReady()" in queue_source
    and "Kapitelmodell fuer Kapitelerstellung nicht bereit" in queue_source,
    "Remote chapter generation reports success even when the chapter model cannot actually run.",
)

require(
    "func generateChapters(episodeHash: String, episodeTitle: String, feedTitle: String) -> Bool" in queue_source
    and "activeStatuses.contains($0.status)" in queue_source
    and "items.removeAll { $0.episodeHash == episodeHash && ($0.status == .completed || $0.status == .failed) }" in queue_source,
    "Completed queue entries still block remote chapter-only generation for an existing transcript.",
)

require(
    "@objc var chapterOnly = false" in queue_source
    and "item.chapterOnly = true" in queue_source
    and "if candidate.chapterOnly {" in queue_source
    and "startChapterGenerationTask(for: candidate" in queue_source
    and "guard chapterTask == nil else" in queue_source,
    "Chapter-only queue items are not resumed through the chapter-generation path after app lifecycle events.",
)

require(
    "Whisper-Modell vor Kapitelerstellung freigegeben" in queue_source
    and "before-chapter-generation" in queue_source
    and "await WhisperKitBackend.shared.releaseModel()" in queue_source,
    "The queue still keeps WhisperKit resident while loading the local chapter model, causing avoidable memory spikes.",
)

require(
    "ICTranscriptionDebugAutomation.swift" in project_source
    and "[ICTranscriptionDebugAutomation handle:" in scene_delegate_source
    and "[ICTranscriptionDebugAutomation handle:" in app_delegate_source,
    "Debug automation is not compiled and wired into both scene and app URL entry points.",
)

automation_source = (ROOT / "Classes" / "ICTranscriptionDebugAutomation.swift").read_text()

require(
    "startCommandProcessing()" in automation_source
    and "handleLaunchArguments()" in automation_source
    and "command.json" in automation_source
    and "handleCommandDictionary" in automation_source
    and "chapterModelUnavailableReason" in automation_source
    and "downloadChapterModel" in automation_source
    and "modelStatus" in automation_source
    and "startModelDownloadIfNeeded" in automation_source
    and "[ICTranscriptionDebugAutomation startCommandProcessing]" in app_delegate_source
    and "[ICTranscriptionDebugAutomation handleLaunchArguments]" in app_delegate_source,
    "Debug automation cannot be driven reliably from simulator launch arguments or a live command file.",
)

require(
    "ICTranscriptionDebugAutomationLastCommandID" in automation_source
    and "duplicateResponse" in automation_source
    and '"duplicate": true' in automation_source
    and '"ignored": true' in automation_source
    and "removeCommandFile" in automation_source
    and "matching originalData" in automation_source,
    "Debug automation still replays a stale command.json after app restart instead of consuming command files idempotently.",
)
