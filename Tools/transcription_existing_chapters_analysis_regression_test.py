from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


queue_source = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
chapter_source = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
paths_source = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
settings_source = (ROOT / "Classes" / "TranscriptionSettingsViewController.m").read_text()
feed_settings_source = (ROOT / "Classes" / "FeedSettingsViewController.m").read_text()


require(
    "existingGeneratedChapters" in queue_source
    and "existingChapters:" in queue_source,
    "Podcast-provided chapters are not passed into semantic analysis for sponsor augmentation.",
)
require(
    "analyzeEpisodeAsync" in queue_source
    and "saveAnalysisResult" in queue_source,
    "The queue still persists chapters independently instead of one validated chapter/sponsor/summary result.",
)
require(
    queue_source.count("generateSemanticArtifacts(") >= 3,
    "Chapter-only and post-transcription queue paths do not share the same semantic-analysis implementation.",
)
require(
    "selectedModel(for: .textToChapters).usesRemoteChapterService" in queue_source,
    "Automatic full episode analysis is not explicitly restricted to a configured long-context remote model.",
)
require(
    "explicitEnd" in queue_source
    and "nextPublisherStart" in queue_source
    and "chapter.duration > 0" in queue_source
    and "cursor < chapter.start" in queue_source
    and "cursor < timelineEnd" in queue_source,
    "Explicit publisher ends and deliberate pre/mid/post-roll gaps are not preserved in the immutable base timeline.",
)
require(
    'detailText: NSLocalizedString("Folge hat bereits Kapitel."' not in queue_source
    and "shouldGenerateChapters = !hasExistingChapters" not in queue_source,
    "Existing podcast chapters still skip semantic sponsor analysis entirely.",
)
require(
    "EpisodeAnalysisResult" in chapter_source
    and "sponsorSegments" in chapter_source
    and "summary" in chapter_source
    and "transcriptRevision" in chapter_source,
    "Chapter, sponsor, and summary output are not represented as one revision-bound analysis result.",
)
require(
    "validateSponsorSegments" in chapter_source
    and "evidenceCueIDs" in chapter_source,
    "Sponsor boundaries are not validated against transcript evidence before automatic skip.",
)
require(
    "chaptersByOverlayingSponsors" in chapter_source
    and '" (Forts.)"' not in chapter_source,
    "Sponsor insertion does not deterministically preserve and split existing chapter intervals.",
)
merged_sponsors = chapter_source.split(
    "private static func mergedSponsorIntervals", 1
)[1].split("/// Compatibility entry point", 1)[0]
require(
    "sponsor.start < previous.end" in merged_sponsors
    and "sponsor.start <= previous.end" not in merged_sponsors,
    "Adjacent advertisements from different sponsors are incorrectly merged under the first sponsor title.",
)
require(
    "analysisJSONURL" in paths_source
    and "saveAnalysisResult" in chapter_source
    and "loadSummary" in chapter_source,
    "AI summaries are not persisted in the revision-bound episode analysis artifact.",
)
analysis_persistence = chapter_source.split("func saveAnalysisResult", 1)[1].split("@objc func loadSummary", 1)[0]
require(
    "AnalysisFile(" in analysis_persistence
    and "analysisJSONURL" in analysis_persistence
    and "saveChaptersThrowing" not in analysis_persistence,
    "Chapters, sponsor evidence, and summary are not committed as one atomic analysis file.",
)
require(
    'fileSnapshot(named: "analysis"' in paths_source,
    "The required DebugLog artifact snapshot does not prove whether the atomic analysis was persisted.",
)
require(
    "KI-Zusammenfassung" in (ROOT / "Classes" / "EpisodeViewController.m").read_text()
    and "analysisJSONURL" in (ROOT / "Classes" / "Model" / "ICSpotlightIndexer.m").read_text(),
    "Generated summaries are not exposed in the episode UI and Spotlight index.",
)
require(
    "verifyAnalysisTranscriptRevision" in queue_source
    and queue_source.count("try await self.saveSemanticArtifacts(") >= 2,
    "A long remote result can still be saved after its persisted transcript changed.",
)
episode_controller_source = (ROOT / "Classes" / "EpisodeViewController.m").read_text()
episodes_controller_source = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
require(
    "removeGeneratedAnalysisForEpisodeHash" in episode_controller_source
    and "removeGeneratedAnalysisForEpisodeHash" in episodes_controller_source,
    "Deleting generated chapters still leaves the derived AI summary and analysis cache behind.",
)
generated_removal = chapter_source.split(
    "private func removeGeneratedAnalysisArtifacts(for episodeHash", 1
)[1].split("private func removeChapterDebug", 1)[0]
require(
    "objectContext.delete" not in generated_removal,
    "Deleting a generated sponsor overlay can still delete publisher-owned Core Data chapters.",
)
require(
    "Vorhandene Podcast-Kapitel bleiben erhalten und werden um erkannte Sponsorsegmente ergänzt." in settings_source
    and "Remote-Kapitelmodelle erstellen zusätzlich eine KI-Zusammenfassung" in settings_source
    and "oberhalb der Shownotes" in settings_source
    and "Neue Folgen analysieren" in settings_source
    and "Neue Folgen analysieren" in feed_settings_source,
    "Transcription settings still promise that existing chapters stay untouched or describe full analysis as chapter-only generation.",
)
