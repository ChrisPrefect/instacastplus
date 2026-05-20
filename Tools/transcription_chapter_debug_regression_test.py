from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


chapter_source = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
queue_source = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
runner_source = (ROOT / "Classes" / "LocalGGUFModelRunner.swift").read_text()
app_delegate_source = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def source_slice(source: str, start_marker: str, end_marker: str) -> str:
    start = source.find(start_marker)
    end = source.find(end_marker, start + len(start_marker)) if start != -1 else -1
    require(start != -1 and end != -1, f"Could not locate source slice {start_marker!r}.")
    return source[start:end]


local_generation_body = source_slice(
    chapter_source,
    "private func generateWithLocalGGUF",
    "private func buildLocalTopicExtractionPrompt",
)
local_topic_prompt_body = source_slice(
    chapter_source,
    "private func buildLocalTopicExtractionPrompt",
    "private static func transcriptCueTitle",
)
sponsor_classifier_prompt_body = source_slice(
    chapter_source,
    "private func buildLocalSponsorClassificationPrompt",
    "private func localChaptersByClassifyingSponsors",
)
local_marker_budget_body = source_slice(
    chapter_source,
    "private func localMarkerMaxNewTokens",
    "private static func isTerminalOnlyMarker",
)
topic_prompt_body = source_slice(
    chapter_source,
    "private func buildTopicExtractionPrompt",
    "private func markersFittingFinalPrompt",
)
final_prompt_body = source_slice(
    chapter_source,
    "private func buildFinalChaptersPrompt",
    "private static func allowedChapterStartSeconds",
)
remote_generation_body = source_slice(
    chapter_source,
    "private func generateWithRemoteChapterModel",
    "private enum RemoteResponseShape",
)
local_chunk_body = source_slice(
    chapter_source,
    "private func transcriptContextWindowsForLocalModel",
    "private func localPromptFitsContext",
)
model_chunk_body = source_slice(
    chapter_source,
    "private func transcriptContextWindowsForModel",
    "private static func nextContextWindowStartIndex",
)
transcript_context_body = source_slice(
    chapter_source,
    "private static func transcriptContextSnippet",
    "private static func deduplicatedMarkers",
)
retry_body = source_slice(
    queue_source,
    "@objc func retry(episodeHash: String)",
    "private func cleanupBrokenArtifacts(for item:",
)
cleanup_body = source_slice(
    queue_source,
    "private func cleanupBrokenArtifacts(episodeHash: String, chapterOnly: Bool)",
    "/// Number of items currently queued",
)


require(
    "chapterQualityIssue(" in chapter_source
    and "erste themenbeschreibung" in chapter_source
    and "Kapitelerkennung fehlgeschlagen - Kapitelmodell lieferte nur ein generisches Gesamtkapitel." in chapter_source,
    "Chapter generation still accepts the observed one-chapter placeholder output instead of rejecting it.",
)

require(
    "singleChapterUndersegmentationIssue" in chapter_source
    and "questionCueCount >= 3" in chapter_source
    and "dialogisches Transkript zu einem einzelnen Gesamtkapitel reduziert" in chapter_source,
    "Chapter generation still saves the observed one-chapter Gemma output for a multi-question dialogue transcript.",
)

require(
    "validatedGeneratedChapters(" in chapter_source
    and "topicMarkerCount:" in chapter_source
    and "existingChapters == nil" in chapter_source,
    "Generated chapters are not quality-checked with topic-marker context before being returned.",
)

require(
    "validateRawGeneratedChapterTiming(rawChapters" in chapter_source
    and "rawGeneratedChapterTimingIssue" in chapter_source
    and "Kapitelmodell hat die Folge nicht bis zum Ende abgedeckt" in chapter_source
    and "Kapitelzeiten ausserhalb der Transkriptdauer" in chapter_source
    and chapter_source.count("validateRawGeneratedChapterTiming(rawChapters") >= 3,
    "Raw model chapter times are still normalized before contract violations are rejected.",
)

require(
    "_chapter_debug.json" in chapter_source
    and "recordLocalFinalOutput" in chapter_source
    and "recordValidation" in chapter_source
    and "performanceEvents" in chapter_source
    and "chapter-performance" in chapter_source
    and "local-pass1-segment-generated" in chapter_source
    and "local-pass2-started" in chapter_source
    and "local-pass2-completed" in chapter_source,
    "Chapter diagnostics still do not persist prompts, validation, and per-model-call timing.",
)

require(
    "recordPass1SegmentStarted" in chapter_source
    and "promptPreview" in chapter_source
    and "pass1-\\(index)-started" in chapter_source,
    "Chapter debugging still cannot show which local prompt is active before the model returns.",
)

require(
    "static func recommendedContextTokens() -> Int32 {\n        32_768\n    }" in runner_source
    and "llama_model_n_ctx_train(model)" in runner_source
    and "targetInputContextRatio" in runner_source
    and "stopAfterFirstJSONObject" in runner_source
    and "firstJSONObject(in:" in runner_source
    and "localMarkerMaxNewTokens" in chapter_source,
    "Local GGUF chapter generation still wastes Gemma's context window or decodes past completed JSON.",
)

require(
    "localContextTokens(forPromptCharacters:" in chapter_source
    and "contextTokens: requestedContextTokens" in chapter_source
    and "LocalGGUFModelRunner.recommendedContextTokens()" in chapter_source
    and "8_192" not in chapter_source
    and "16_384" not in chapter_source,
    "Local GGUF chapter generation still downshifts context instead of giving the model the largest available context window.",
)

require(
    "buildLocalDirectChaptersPrompt" in chapter_source
    and "buildDirectChaptersPrompt" in chapter_source
    and "transcriptPromptBlockLines" in chapter_source
    and "Transkript-Bloecke" in chapter_source
    and "cue.end > blockStart" in chapter_source
    and "existingChapters == nil, totalSegments == 1" in local_generation_body
    and "local-direct-chapters-started" in local_generation_body
    and "direct-full-transcript" in local_generation_body
    and "grammar: .chapterStarts" in local_generation_body
    and "chaptersFromGeneratedStarts" in chapter_source
    and "Ein einzelnes Kapitel ueber fast die ganze Folge ist nur erlaubt" in chapter_source
    and "eigenen Nutzensprung" in chapter_source
    and "Promotion wieder in redaktionellen Inhalt uebergeht" in chapter_source
    and "Ein Oberthema reicht nicht als Kapitel" in chapter_source
    and "Vermeide Sammelkapitel" in chapter_source
    and "Ticketverfuegbarkeit" in chapter_source
    and "zusammenhaengenden Unterstuetzungs-, Abo-, Spenden-, Preis-, Zahlungs- oder Mitgliedschaftsblocks" in chapter_source
    and "Reine Servicehinweise zum bestehenden Podcast" in chapter_source,
    "Local GGUF still asks the model for redundant direct end times instead of deriving ends from recognized chapter starts.",
)

require(
    "validateRemoteChapterStartEvidence" in chapter_source
    and "rawChapterStartEvidenceIssue" in chapter_source
    and "evidenceText(evidence, matchesTranscriptContext: context)" in chapter_source
    and "remote-chapter-evidence-validation-failed" in chapter_source
    and "remote-chapter-evidence-retry-started" in chapter_source,
    "Remote chapter starts are not grounded against their evidence text, so a later sponsor can still be saved at an earlier editorial start.",
)

require(
    "zwei verschiedene Promotion-Segmente nacheinander" in chapter_source
    and "spaetere Sponsoren auf deren eigene Startzeit" in chapter_source,
    "Evidence retry still lets a later sponsor brand be reused for an earlier adjacent promotion segment.",
)

require(
    "sponsorRecognitionRule" in chapter_source
    and "nicht nur als externe Werbung" in chapter_source
    and "Calls-to-Action fuer eigene Produkte, Events oder Services" in chapter_source
    and "Bezahlter oder limitierter Zugang zu einem eigenen Angebot" in chapter_source
    and "nur Details eines eigenen Angebots" in chapter_source
    and "Neutrale Erwaehnungen von Plattformen" in chapter_source
    and "eigene Angebote, eigene Events und andere eigene Podcasts" in chapter_source
    and "ueber fast die ganze kurze Folge" in chapter_source,
    "Sponsor/promo prompting still lets the model treat creator-owned paid announcements as normal content.",
)

require(
    "buildLocalSponsorClassificationPrompt" in chapter_source
    and "localChaptersByClassifyingSponsors" in chapter_source
    and "local-sponsor-classification-started" in chapter_source
    and "local-sponsor-classification-completed" in chapter_source
    and 'eventPrefix: "local-sponsor-classification"' in chapter_source
    and "chaptersByApplyingSponsorClassification" in chapter_source
    and "Sponsor- und Eigenpromo-Segmente werden semantisch geprueft." in chapter_source
    and "localSponsorOutput" in chapter_source,
    "Local chapter generation still mixes boundary generation and sponsor classification in one unreliable model task.",
)

require(
    "llama_sampler_init_grammar" in runner_source
    and "jsonGrammar" in runner_source
    and "chapterJSONGrammar" in runner_source
    and "chapterStartsJSONGrammar" in runner_source
    and "markerJSONGrammar" in runner_source
    and "installSampler(grammar:" in runner_source
    and "grammar: .chapterStarts" in chapter_source
    and "grammar: .chapters" in chapter_source
    and "grammar: .markers" in chapter_source,
    "Local GGUF chapter generation is not constrained to the expected JSON schema at the sampler level.",
)

require(
    '\\"endSeconds\\":123' not in chapter_source
    and '\\"timeSeconds\\":123' not in chapter_source
    and '\\"title\\":\\"Kurzer Titel\\"' not in chapter_source,
    "Local prompts still include concrete sample JSON values that bias models into copying fake chapter times or titles.",
)

require(
    "formatModelSecond" in chapter_source
    and "Transkript (0:00-" not in chapter_source
    and "prompt += \"Gesamtdauer: \\(formatTime" not in chapter_source,
    "Model prompts still use clock-formatted timestamps that models can misread as seconds, e.g. 15:38 -> 1538.",
)

require(
    "timelineCoverageRule" in chapter_source
    and "Kapitel muessen die komplette Zeitachse lueckenlos abdecken" in chapter_source
    and "promotionSegmentationRule" in chapter_source
    and "Mische redaktionellen Inhalt und Promotion in keiner Richtung im selben Kapitel" in chapter_source,
    "Local prompts do not explicitly require gap-free chapter coverage and separate sponsor/promo chapters.",
)

require(
    "maximumTopicMarkerCount" not in chapter_source
    and "minimumTopicMarkerCount" not in chapter_source
    and "maximumReasonableChapterCount" not in chapter_source
    and "shortInternalContentChapterIssue" not in chapter_source
    and "Erzeuge hoechstens" not in chapter_source
    and "Erzeuge \\(minimumMarkers) bis \\(maximumMarkers) Marker" not in chapter_source
    and "Kleinstkapitel" not in chapter_source
    and "zu kurzes Inhaltskapitel" not in chapter_source,
    "Chapter generation still contains mechanical count or duration rules instead of leaving semantic chapter decisions to the model.",
)

require(
    '"markers\\"" ws ":" ws "[" ws marker ("," ws marker)* "]"' in runner_source
    and '"markers\\"" ws ":" ws "[" ws (marker ("," ws marker)*)?' not in runner_source,
    "Local marker grammar still permits empty marker arrays.",
)

require(
    "llama_sampler_accept(handle.sampler, nextToken)" not in runner_source,
    "Local GGUF generation manually accepts tokens after llama_sampler_sample, which already accepts them and can crash grammar sampling.",
)

require(
    "generateLocalJSONObject" in chapter_source
    and "withThrowingTaskGroup" in chapter_source
    and "localGenerationTimeoutNanoseconds" in chapter_source
    and "600 * 1_000_000_000" in chapter_source
    and "Kapitelmodell hat nicht rechtzeitig geantwortet" in chapter_source,
    "Local GGUF chapter calls can still hang indefinitely instead of failing with an explicit timeout.",
)

require(
    "progress?(0, 0, 1)" in remote_generation_body
    and "progress?(0.05, 0, 1)" not in remote_generation_body
    and "progress?(0.2, 0, 1)" not in remote_generation_body
    and "musicSegments: nil" in remote_generation_body.split("chapters = try Self.validatedGeneratedChapters(chapters", 1)[1],
    "Remote chapter generation still shows fake percentage progress or rejects model output with local music-boundary validation.",
)

require(
    "cueCount * 4" not in local_marker_budget_body
    and "2_048" in local_marker_budget_body,
    "Local marker generation still scales output budget with raw cue count or semantic chapter-count guesses.",
)

require(
    "cleanupBrokenArtifacts(for: item)" in retry_body
    and "removeGeneratedChapters" not in cleanup_body,
    "Retrying an interrupted chapter-only job still deletes the last good chapters before replacement chapters are saved.",
)

require(
    "maximumTopicExtractionSegmentDuration" not in chapter_source
    and "maximumTopicExtractionCueCount" not in chapter_source
    and "minimumTopicExtractionCueCountForDurationSplit" not in chapter_source
    and "targetContextWindowOverlapDuration" in chapter_source
    and "nextContextWindowStartIndex" in chapter_source
    and "windows.append(TranscriptContextWindow" in local_chunk_body
    and "windows.append(TranscriptContextWindow" in model_chunk_body
    and "return [TranscriptContextWindow(cues: cues)]" in local_chunk_body
    and "return [TranscriptContextWindow(cues: cues)]" in model_chunk_body
    and "das vollständige Transkript passt nicht in das Kontextfenster" not in chapter_source,
    "Pass 1 still uses artificial short chunks or aborts long transcripts instead of large overlapping context windows.",
)

require(
    "splitUndersegmentedTopicSegment" not in chapter_source
    and "undersegmentedTopicSegmentIssue" not in chapter_source
    and "pass1-segment-undersegmented" not in chapter_source
    and "local-pass1-segment-undersegmented" not in chapter_source,
    "Pass 1 still retries by splitting undersegmented chunks instead of letting the full-context model decide chapter granularity.",
)

require(
    "Ein zusammenhaengendes Thema darf sehr lang sein" in local_topic_prompt_body
    and "Ein zusammenhaengendes Thema darf sehr lang sein" in topic_prompt_body
    and "Sprechakt" in topic_prompt_body
    and "angekuendigte Sache" in topic_prompt_body
    and "Keine reinen Kategorie-, Schlagwort- oder Oberbegriff-Titel" in topic_prompt_body
    and "Die JSON-Liste MUSS mindestens" not in chapter_source
    and "ein langer Podcast-Abschnitt mit nur einem Marker ist ungueltig" not in chapter_source
    and "ein langer Abschnitt mit nur einem Marker ist ungueltig" not in chapter_source,
    "Pass 1 still forces duration-based subchapters instead of allowing long coherent chapters.",
)

require(
    "generateLocalJSONObject(runner: runner" in local_generation_body
    and "grammar: .markers" in local_generation_body
    and "decodeLocalJSON(LocalTopicMarkersResponse.self" in local_generation_body
    and "deterministicLocalTopicMarkers" not in local_generation_body,
    "Local Pass 1 still bypasses the chapter model instead of asking it for semantic markers.",
)

require(
    "Podcast-Kontext" in topic_prompt_body
    and "episodeTitle:" in chapter_source
    and "feedTitle:" in chapter_source
    and "chaptersByApplyingEpisodeTitleToSingleContentChapter" in chapter_source
    and "episodeTitleNumberSignals" in chapter_source
    and "episodeTitle: item.episodeTitle" in queue_source
    and "feedTitle: item.feedTitle" in queue_source,
    "Chapter prompts still omit episode/feed metadata that the model needs to title short announcements and ambiguous transcript spans.",
)

require(
    "chaptersFromTopicMarkers" in chapter_source
    and '"mode": "topic-markers"' in chapter_source
    and "finalMarkers = topicMarkers" in chapter_source
    and "rawChapters = Self.chaptersFromTopicMarkers(finalMarkers" in chapter_source,
    "Local new-chapter generation still lets a final JSON pass drop concrete topic markers or rewrite titles into vague fragments.",
)

require(
    "preserveTopicMarkerTitles" in chapter_source
    and "if !preserveTopicMarkerTitles" in chapter_source
    and "chaptersByReplacingVerboseContentTitles" in chapter_source.split("if !preserveTopicMarkerTitles", 1)[1].split("chapters = Self.chaptersByAddingMusicBoundaryChapters", 1)[0],
    "Marker-built local chapters still run through transcript-snippet title repairs that can replace concrete model titles.",
)

require(
    "contentChapterCount > 1" in chapter_source
    and "words.count > 14" in chapter_source
    and "words.count > 8" not in chapter_source,
    "Verbose title repair can still replace a single model-generated full-episode title with the first transcript sentence.",
)

require(
    chapter_source.count("chapters = Self.chaptersByAddingMusicBoundaryChapters(chapters") == 3,
    "Music boundary insertion still runs more than once per chapter-generation path.",
)

require(
    "minimumExpectedChapterCount" not in chapter_source
    and "Du MUSST mindestens" not in chapter_source
    and "nicht laenger als 240 Sekunden" not in chapter_source
    and "maximumContentChapterDuration" not in chapter_source
    and "chaptersBySplittingOversizedContentChapters" not in chapter_source
    and "oversizedContentChapterIssue" not in chapter_source
    and "Ein Kapitel darf sehr lang sein" in final_prompt_body,
    "Final chapter generation still contains downstream max-duration or minimum-count workarounds.",
)

require(
    "promotionSkipTitle" not in chapter_source
    and "isSponsorCueText" not in chapter_source
    and "titleLooksPromotional" not in chapter_source
    and "chaptersByInsertingPromotionChapters" not in chapter_source
    and "chaptersByClearingModelSponsorClaims" not in chapter_source
    and "chaptersByReplacingUnsupportedPromotionalTitles" not in chapter_source
    and "paypal" not in chapter_source
    and "das universum" not in chapter_source.lower()
    and "Sponsor: PLUS-Abo" not in chapter_source,
    "Swift still contains language-specific sponsor/promo detectors instead of leaving semantic detection to the model.",
)

require(
    "isSponsor: $0.isSponsor" in chapter_source
    and "isSponsor: title.hasPrefix(\"Sponsor: \")" in chapter_source
    and "isSponsor: false" in chapter_source,
    "Model sponsor decisions are no longer preserved from structured output or Sponsor-prefixed semantic markers.",
)

require(
    "contentTitleStopwords" not in chapter_source
    and "Alte Folgen der Sternengeschichten" not in chapter_source
    and "kaloriendefizit" not in chapter_source.lower()
    and '"hallo liebe"' not in chapter_source
    and "shortTranscriptTitle" in chapter_source
    and "A-Za-zÄÖÜ" not in chapter_source,
    "Chapter title repair still contains podcast-, German-, or topic-specific hardcoded title rules.",
)

require(
    "Transkriptkontext pro Marker umfasst den Abschnitt bis zum naechsten Marker mit Grenzkontext" in final_prompt_body
    and ".prefix(14)" not in transcript_context_body
    and "text.prefix(1200)" not in transcript_context_body
    and "return text" in transcript_context_body,
    "Final chapter titles are still based on tiny context snippets instead of the full marker interval.",
)

require(
    "buildTopicExtractionPrompt(cues: cues,\n                                                allCues: allCues,\n                                                musicSegments: musicSegments" in local_topic_prompt_body
    and "audioContextMarkers" in topic_prompt_body
    and "Erzeuge nur Inhaltskapitel" in final_prompt_body
    and "Verwende Intro und Outro nicht" in final_prompt_body
    and "Audiohinweis-Marker" in final_prompt_body
    and "Sound-Sample" in final_prompt_body,
    "Chapter recognition still feeds guessed structural labels instead of neutral audio markers for Jingle/Sound-Sample decisions.",
)

require(
    "chaptersByRemovingTerminalGenericChapters" in chapter_source
    and "Generische Schlusskapitel entfernt" in chapter_source
    and '"ende"' in chapter_source,
    "Final chapter generation still saves terminal garbage chapters such as 'Gesamtdauer' or 'Ende' after the real outro.",
)

require(
    "Marker sind Startpunkte von Themenbloecken" in chapter_source
    and "Der erste Marker muss am Abschnittsanfang" in chapter_source
    and "Setze timeSeconds nie ans Abschnittsende" in chapter_source,
    "Pass 1 prompt still describes vague topic changes instead of enforcing chapter-start markers.",
)

require(
    "chaptersByMergingAdjacentStructuralChapters" not in chapter_source
    and "Strukturkapitel zusammengefuehrt" not in chapter_source
    and "isSingleShortIntroLeadIn" not in chapter_source,
    "Duplicate structural chapters are still hidden by downstream merging instead of being prevented at recognition/validation.",
)

require(
    "standaloneMusicDuration = 4.0" in chapter_source
    and "invalidStructuralChapterIssue" in chapter_source
    and "invalidAudioInterludeChapterIssue" in chapter_source
    and "audioChapterHasMatchingMusicSegment" in chapter_source,
    "Chapter validation still accepts short music blips or unsupported audio chapters.",
)

require(
    "if let firstToken = tokens.first" in chapter_source
    and "musicTokens.contains(firstToken)" in chapter_source
    and "tokens.count <= 12" in chapter_source,
    "Short music-led jingle/lyric cues are still treated as meaningful speech and can block outro chapter recognition.",
)

require(
    "leadingMusicCuePrefixPattern" in chapter_source
    and "Musik Ja" in chapter_source,
    "Chapter title derivation still leaks leading Whisper music marker text into spoken-content chapter titles.",
)

require(
    "llama_set_abort_callback" in runner_source
    and "CancellationState" in runner_source
    and "nonisolated func requestCancel()" in runner_source
    and "result == 2" in runner_source,
    "Local GGUF cancellation still does not abort llama_decode at the C runtime boundary.",
)

require(
    "UIApplication.shared.beginBackgroundTask(withName: \"InstacastPlus.TranscriptionQueue\")" in queue_source
    and "backgroundContinuationTask" in queue_source
    and "endBackgroundContinuationIfNeeded" in queue_source,
    "TranscriptionQueue still has no UIKit background task while model/transcription/chapter work is active.",
)

print("ok")
