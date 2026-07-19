from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENGINE = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
TRANSCRIPTION_SETTINGS = (ROOT / "Classes" / "TranscriptionSettingsViewController.m").read_text()
FEED_SETTINGS = (ROOT / "Classes" / "FeedSettingsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


global_auto_toggle = TRANSCRIPTION_SETTINGS.split("- (void)_autoToggle:", 1)[1].split(
    "#pragma mark - Selection", 1
)[0]
feed_auto_toggle = FEED_SETTINGS.split("- (void) _transcriptionToggleChanged:", 1)[1].split(
    "- (void) toggleShowUnavailableEpisodes:", 1
)[0]
runtime_intent = QUEUE.split("private func revalidatedAutomaticRuntimeIntent", 1)[1].split(
    "private func", 1
)[0]

require(
    "supportsReliableAutomaticAnalysis" not in ENGINE,
    "The model catalog still declares OpenAI as the only automatic-analysis provider.",
)

for source, owner in [
    (runtime_intent, "automatic queue"),
    (global_auto_toggle, "global transcription settings"),
    (feed_auto_toggle, "per-podcast transcription settings"),
]:
    require(
        "supportsReliableAutomaticAnalysis" not in source
        and "GPT-5.6 Terra" not in source,
        f"The {owner} still hard-codes OpenAI Terra instead of honoring the user's selected provider.",
    )

require(
    "selectedChapterModelCanGenerate" in global_auto_toggle
    and "selectedChapterModelUnavailableReason" in global_auto_toggle
    and "hasOpenAIAPIKey" not in global_auto_toggle
    and "kChapterAutoDefault" in global_auto_toggle,
    "Global automatic analysis does not validate the currently selected provider generically.",
)
require(
    "selectedChapterModelCanGenerate" in feed_auto_toggle
    and "selectedChapterModelUnavailableReason" in feed_auto_toggle
    and "hasOpenAIAPIKey" not in feed_auto_toggle
    and "kFeedPropertyAutoChapters" in feed_auto_toggle,
    "Per-podcast automatic analysis does not validate the currently selected provider generically.",
)

require(
    "ICDownloadableModelStore.selectedChapterModelCanGenerate()" in runtime_intent
    and "ICDownloadableModelStore.selectedChapterModelUnavailableReason()" in runtime_intent
    and "hasOpenAIAPIKey" not in runtime_intent,
    "Runtime automatic analysis does not honor readiness and credentials of the user's selected provider.",
)

print("Automatic analysis model contract regression checks passed.")
