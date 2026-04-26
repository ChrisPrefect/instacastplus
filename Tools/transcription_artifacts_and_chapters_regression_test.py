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
    "splitTranscriptIntoModelChunks" in chapter_source,
    "Chapter generation still uses only character-count chunking instead of model-token-checked chunks.",
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
