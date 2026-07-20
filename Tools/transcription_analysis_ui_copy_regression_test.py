#!/usr/bin/env python3
"""Regression contract for chapter/summary actions and Show Notes presentation."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


episode_view = read("Classes/EpisodeViewController.m")
episode_list = read("Classes/EpisodesTableViewController.m")
settings = read("Classes/TranscriptionSettingsViewController.m")
german = read("Resources/de.lproj/Localizable.strings")
english = read("Resources/en.lproj/Localizable.strings")
template = read("Resources-iPhone/ShowNotesTemplateIPhone.html")
daylight = read("Resources-iPhone/ShowNotesDaylightAppearance.css")
night = read("Resources-iPhone/ShowNotesNightAppearance.css")


for source, surface in ((episode_view, "episode detail"), (episode_list, "episode list")):
    require(
        "usesRemoteChapterService" in source
        and 'NSLocalizedString(@"Kapitel und Zusammenfassung erstellen", nil)' in source
        and 'NSLocalizedString(@"Kapitel erstellen", nil)' in source,
        f"The {surface} menu does not describe remote summary creation without promising it for local models.",
    )
    require(
        "loadSummaryFor:" in source
        and 'NSLocalizedString(@"Kapitel und Zusammenfassung löschen", nil)' in source
        and 'NSLocalizedString(@"Kapitel löschen", nil)' in source
        and "removeGeneratedAnalysisForEpisodeHash" in source,
        f"The {surface} menu does not accurately label deletion of the persisted analysis package.",
    )
    require(
        'NSLocalizedString(@"Generierte Analyse löschen", nil)' not in source,
        f"The {surface} menu still exposes the internal term 'generated analysis'.",
    )

require(
    'NSLocalizedString(@"Kapitel, Sponsoren & KI-Zusammenfassung", nil)' in settings
    and "Remote-Kapitelmodelle erstellen zusätzlich eine KI-Zusammenfassung" in settings
    and "oberhalb der Shownotes" in settings,
    "Local transcription settings do not explain AI summaries and where they appear.",
)

for localized, language in ((german, "German"), (english, "English")):
    for key in (
        "Kapitel und Zusammenfassung erstellen",
        "Kapitel und Zusammenfassung löschen",
        "Kapitel erstellen",
        "Kapitel löschen",
        "Kapitel, Sponsoren & KI-Zusammenfassung",
        "Sponsoren-Kapitel können automatisch übersprungen werden. Vorhandene Podcast-Kapitel bleiben erhalten und werden um erkannte Sponsorsegmente ergänzt. Remote-Kapitelmodelle erstellen zusätzlich eine KI-Zusammenfassung, die oberhalb der Shownotes angezeigt wird.",
    ):
        require(f'"{key}" =' in localized, f"{language} localization is missing: {key}")

require(
    "#ai-summary" in template
    and "padding:" in template.split("#ai-summary", 1)[1].split("}", 1)[0]
    and "margin:" in template.split("#ai-summary", 1)[1].split("}", 1)[0]
    and "border-radius:" in template.split("#ai-summary", 1)[1].split("}", 1)[0],
    "The AI summary still lacks padded card layout in Show Notes.",
)
require(
    "#ai-summary" in daylight
    and "background-color:" in daylight.split("#ai-summary", 1)[1].split("}", 1)[0],
    "The AI summary has no light-mode background treatment.",
)
require(
    "#ai-summary" in night
    and "background-color:" in night.split("#ai-summary", 1)[1].split("}", 1)[0],
    "The AI summary has no dark-mode background treatment.",
)

print("Transcription analysis UI copy regression checks passed.")
