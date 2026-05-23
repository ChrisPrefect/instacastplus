from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


episode_model_source = (ROOT / "Classes" / "Model" / "CDEpisode.m").read_text()
player_info_source = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
cache_manager_source = (ROOT / "Classes" / "CacheManager.m").read_text()
chapter_source = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
backend_source = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text()
engine_source = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
queue_source = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()


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
local_final_prompt_body = source_slice(
    chapter_source,
    "private func buildLocalFinalChaptersPrompt",
    "private func buildLocalMarkerConsolidationPrompt",
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


for name, source in {
    "CDEpisode consumed cleanup": episode_model_source,
    "Player transcript cleanup": player_info_source,
    "CacheManager transcript cleanup": cache_manager_source,
}.items():
    require(
        'pathExtension] isEqualToString:@"trcache"' in source,
        f"{name} still deletes every <episodeHash>_ artifact instead of only transcript cache files.",
    )

require(
    "seekToTime:chapter.timecode tolerance:NO" in player_info_source
    and "playbackChapters[chapter.index]" not in player_info_source,
    "Chapter row selection still indexes runtime playback chapters instead of seeking to the displayed stored chapter timecode.",
)

chapter_selection_body = source_slice(
    player_info_source,
    "- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath",
    "else if ([self _hasBookmarks] && indexPath.section == [self _bookmarksSection])",
)
immediate_chapter_index = chapter_selection_body.find("pman.currentChapter = indexPath.row")
seek_index = chapter_selection_body.find("[pman seekToTime:chapter.timecode tolerance:NO]")
play_index = chapter_selection_body.find("[pman play]")
require(
    immediate_chapter_index != -1
    and seek_index != -1
    and play_index != -1
    and immediate_chapter_index < seek_index < play_index,
    "Chapter taps must mark the tapped row before seeking/playing so the previous chapter cannot flash and restored background playback highlights immediately.",
)

require(
    "_effectiveChapterIndexForPlaybackManager:" in player_info_source
    and "_chapterIndexForPlaybackTime:" in player_info_source,
    "Player chapter highlighting still cannot resolve the current chapter from stored generated chapter timecodes.",
)

pass1_index = chapter_source.find("let prompt = buildTopicExtractionPrompt")
fit_index = chapter_source.find("promptFitsContext(prompt, model: model, maxInputTokens: maxInputTokens)")
respond_index = chapter_source.find("session.respond(to: prompt, generating: GeneratedTopicMarkersList.self)")
require(
    pass1_index != -1 and fit_index != -1 and respond_index != -1 and pass1_index < fit_index < respond_index,
    "Chapter pass 1 still sends prompts to Foundation Models without proving they fit the model context window.",
)

require(
    "return [TranscriptContextWindow(cues: cues)]" in local_chunk_body
    and "return [TranscriptContextWindow(cues: cues)]" in model_chunk_body
    and "windows.append(TranscriptContextWindow" in local_chunk_body
    and "windows.append(TranscriptContextWindow" in model_chunk_body
    and "targetContextWindowOverlapDuration" in chapter_source
    and "nextContextWindowStartIndex" in chapter_source
    and "maximumTopicExtractionSegmentDuration" not in chapter_source
    and "maximumTopicExtractionCueCount" not in chapter_source,
    "Chapter generation still splits transcripts into artificial short chunks instead of full-context first and large overlapping context windows.",
)

require(
    "minimumExpectedChapterCount" not in chapter_source
    and "maximumContentChapterDuration" not in chapter_source
    and "chaptersBySplittingOversizedContentChapters" not in chapter_source
    and "Ein Kapitel darf sehr lang sein" in final_prompt_body,
    "Chapter generation still contains downstream duration/count workarounds instead of letting the model choose real chapter boundaries.",
)

require(
    "promotionSkipTitle" not in chapter_source
    and "isSponsorCueText" not in chapter_source
    and "titleLooksPromotional" not in chapter_source
    and "chaptersByInsertingPromotionChapters" not in chapter_source
    and "chaptersByClearingModelSponsorClaims" not in chapter_source
    and "paypal" not in chapter_source
    and "patreon" not in chapter_source
    and "Sponsor: PLUS-Abo" not in chapter_source,
    "Swift still contains language-specific support/shop/PLUS/rating/promo detectors instead of model-only semantic recognition.",
)

require(
    "Found first token at" in backend_source
    and "Erstes Transkriptsegment erkannt." not in backend_source,
    "WhisperKit still maps every per-window first-token log to the misleading 'first transcript segment' status.",
)

require(
    "Decoding Seek:" in backend_source
    and "Whisper verarbeitet den nächsten Audioblock." not in backend_source,
    "WhisperKit still exposes the low-value per-window decoding log as user-visible status text.",
)

require(
    "cleanedTranscriptText" in engine_source
    and "<\\|[^>]+\\|>" in engine_source,
    "Transcription post-processing still leaves Whisper control/timestamp tokens in transcript text.",
)

require(
    "cleanedSegmentText" in backend_source
    and "<\\|[^>]+\\|>" in backend_source
    and "let text = cleanedSegmentText(segment.text)" in backend_source,
    "Live Whisper checkpoints still persist raw Whisper control/timestamp tokens before final post-processing.",
)

require(
    "Musik-Timeline wird aus Cache geladen" not in queue_source
    and "Musik-Timeline aus Cache geladen" not in queue_source
    and "Audioanalyse gestartet (SoundAnalysis)" in queue_source,
    "Queue still shows cached music-timeline implementation details in the user-visible status/log.",
)

require(
    "transcriptCues:" in chapter_source
    and "firstSpeechStart" in chapter_source
    and "lastSpeechEnd" in chapter_source
    and 'title: "Intro"' in chapter_source
    and 'title: "Outro"' in chapter_source,
    "Generated Intro/Outro chapters are not constrained by transcript cue boundaries, so they can include spoken text.",
)

require(
    "isMostlyCoveredByMusic" not in chapter_source
    and "speechBoundaries(from: transcriptCues, musicSegments: musicSegments)" not in chapter_source,
    "Music-boundary detection still hides spoken cues just because background music overlaps them.",
)

music_boundary_body = source_slice(
    chapter_source,
    "private static func standaloneIntroOutroMusicChapters",
    "private static func speechBoundaries",
)
require(
    "meaningfulSpeechOverlapDuration" in chapter_source
    and "trimmedStandaloneMusicChapter" in music_boundary_body
    and 'title: "Jingle"' not in music_boundary_body,
    "Standalone intro/outro music detection still guesses Intro/Jingle/Outro directly from audio position instead of requiring transcript-bounded standalone music.",
)

require(
    "isLowInformationContentTitle" in chapter_source
    and "contentTitleStopwords" not in chapter_source
    and "Alte Folgen der Sternengeschichten" not in chapter_source
    and "kaloriendefizit" not in chapter_source.lower(),
    "Chapter title repair still uses language- or podcast-specific hardcoded title rules.",
)

require(
    "generateLocalJSONObject(runner: runner" in local_generation_body
    and "grammar: .markers" in local_generation_body
    and "decodeLocalJSON(LocalTopicMarkersResponse.self" in local_generation_body
    and "deterministicLocalTopicMarkers" not in local_generation_body
    and "buildTopicExtractionPrompt(cues: cues,\n                                                allCues: allCues,\n                                                musicSegments: musicSegments" in local_topic_prompt_body
    and "audioContextMarkers" in topic_prompt_body,
    "Pass 1 still bypasses the model or injects structural guesses instead of model-generated semantic markers with neutral audio context.",
)

require(
    "Erzeuge nur Inhaltskapitel" in final_prompt_body
    and "Verwende Intro und Outro nicht" in final_prompt_body
    and "Audiohinweis-Marker" in final_prompt_body
    and "Sound-Sample" in final_prompt_body
    and "Musik am Anfang oder Ende" not in final_prompt_body
    and "Bei Intro-/Outro-Musik" not in local_final_prompt_body,
    "Pass 2 still lacks neutral audio context for Jingle/Sound-Sample chapters or is still allowed to synthesize Intro/Outro.",
)

require(
    "chaptersByMergingAdjacentStructuralChapters" not in chapter_source
    and "Strukturkapitel zusammengefuehrt" not in chapter_source
    and "isSingleShortIntroLeadIn" not in chapter_source,
    "Duplicate structural chapters are still hidden by downstream merging instead of being prevented at chapter recognition.",
)

require(
    "chaptersByInsertingMusicChapter(boundary, to: result, transcriptCues: transcriptCues)" in chapter_source
    and "titleForBoundarySplitFragment" in chapter_source
    and "prefixTeaser: music.title == \"Intro\"" in chapter_source,
    "Music-boundary insertion still copies one content chapter title onto both sides of an intro/jingle split instead of retitling split fragments from their own transcript spans.",
)

require(
    "audioContextMarkers(musicSegments:" in chapter_source
    and "Audiohinweis: Musik/Sound" in chapter_source
    and "previousSpeechSnippet" in chapter_source
    and "nextSpeechSnippet" in chapter_source,
    "Music and sound-analysis boundaries are still not passed to the chapter model as neutral transcript-adjacent context.",
)

require(
    "invalidAudioInterludeChapterIssue" in chapter_source
    and "audioChapterHasMatchingMusicSegment" in chapter_source
    and "normalizedAudioInterludeTitle" in chapter_source,
    "Model-generated Jingle/Sound-Sample chapters are still not validated against actual audio-analysis segments.",
)

require(
    "hasMeaningfulTitleCharacter" in chapter_source
    and "isUsableConciseContentTitle" in chapter_source
    and "unicodeScalars.contains" in chapter_source,
    "Concise chapter title selection can still accept punctuation-only titles.",
)

print("ok")
