#!/usr/bin/env python3
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
CHAPTER_GENERATOR = (ROOT / "Classes" / "ChapterGenerator.swift").read_text(encoding="utf-8")
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text(encoding="utf-8")
WHISPER_BACKEND = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text(encoding="utf-8")
DE_STRINGS = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text(encoding="utf-8")
EN_STRINGS = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body for: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace:index + 1]
    raise SystemExit(f"Unterminated body for: {signature}")


def strings_value(source: str, key: str):
    escaped = re.escape(key)
    match = re.search(rf'^"{escaped}"\s*=\s*"((?:[^"\\]|\\.)*)";', source, re.MULTILINE)
    return match.group(1) if match else None


LOCALIZED_ERROR_KEYS = [
    "Die vollständige Kapitel-, Sponsor- und Zusammenfassungsanalyse benötigt ein Remote-Kapitelmodell.",
    "Episodenanalyse abgebrochen - die vorhandenen Podcast-Kapitel haben keine gültige Zeitachse.",
    "OpenAI-Hintergrundanalyse benötigt einen stabilen Episoden-Hash für die Wiederaufnahme.",
    "Episodenanalyse verworfen - das Modell hat nicht die angeforderte Transkript-Revision analysiert.",
    "Episodenanalyse verworfen - das Modell wollte vorhandene Podcast-Kapitel ersetzen.",
    "Episodenanalyse benötigt ein vollständiges Transkript.",
    "Episodenanalyse abgebrochen - die Transkript-Cues haben keine gültige chronologische Zeitachse.",
    "Episodenanalyse verworfen - ein Kapitelstart hat keine gültige Cue-ID oder keinen Titel.",
    "Episodenanalyse verworfen - die generierten Kapitel decken den Transkriptanfang nicht ab.",
    "Episodenanalyse verworfen - zwei Kapitelstarts bilden kein gültiges Zeitintervall.",
    "Episodenanalyse verworfen - ein Sponsorsegment hat keine gültigen Cue-Grenzen oder keinen Sponsor-Titel.",
    "Episodenanalyse verworfen - ein Sponsorsegment enthält einen unbekannten Transkript-Beleg.",
    "Episodenanalyse verworfen - Sponsorgrenzen sind nicht vollständig durch zusammenhängende Transkript-Cues belegt.",
    "Sponsor-Erkennung verworfen - das Transkript wurde seit der Analyse geaendert.",
    "Sponsor-Erkennung verworfen - die Transkript-Cues haben keine gueltige chronologische Zeitachse.",
    "Sponsor-Erkennung verworfen - Sponsorsegmente wurden ohne Transkript-Belege geliefert.",
    "Sponsor-Erkennung verworfen - Sponsorsegmente sind ungueltig, ueberlappend oder nicht chronologisch sortiert.",
    "Sponsor-Erkennung verworfen - ein Sponsorsegment hat keinen Titel.",
    "Sponsor-Erkennung verworfen - ein Sponsorsegment hat keinen eindeutigen Sponsor-Titel.",
    "Sponsor-Erkennung verworfen - ein Sponsorsegment hat keine eindeutigen Transkript-Belege.",
    "Sponsor-Erkennung verworfen - Sponsorgrenzen liegen nicht exakt auf belegten Transkript-Cues.",
    "Sponsor-Erkennung verworfen - der automatische Skip-Bereich ist nicht lückenlos durch Transkript-Cues belegt.",
    "Sponsor-Erkennung verworfen - ein Transkript-Beleg fehlt, ist veraltet oder nicht chronologisch.",
    "Sponsor-Erkennung verworfen - ein Beleg liegt ausserhalb des behaupteten Sponsorsegments.",
    "Episodenanalyse verworfen - das Modell hat keine Zusammenfassung geliefert.",
    "OpenAI-Hintergrundanalyse wurde mit einer unpassenden Modell- oder Schema-Identität gestartet.",
    "Für diese Episode läuft bereits dieselbe OpenAI-Hintergrundanalyse.",
    "OpenAI-Auftragsdatei ist aktiv, enthält aber keine Response-ID.",
    "Der letzte OpenAI-Auftrag wurde möglicherweise angenommen, aber seine Response-ID konnte nicht bestätigt werden. Ein automatischer Doppel-POST wird verhindert.",
    "Die abgeschlossene OpenAI-Antwort hat die lokale Evidenzprüfung nicht bestanden.",
    "OpenAI-Auftragserstellung wurde unterbrochen, bevor eine Response-ID bestätigt werden konnte. Der Auftrag wird nicht automatisch doppelt gesendet.",
    "OpenAI hat die Auftragserstellung bestätigt, aber keine Response-ID geliefert.",
    "OpenAI-Antwort-ID oder Metadaten stimmen nicht mit dem persistierten Auftrag überein.",
    "OpenAI-Auftragsdatei wurde während des Abrufs ersetzt oder entfernt.",
    "Abgerufene OpenAI-Antwort stimmt nicht mit Response-ID und Auftrags-Fingerprint überein.",
    "Die OpenAI-Antwort wurde bereits durch die lokale Evidenzprüfung verworfen.",
    "OpenAI-Auftragsdatei enthält keine vollständige Identität.",
    "OpenAI-Auftragsdatei konnte nicht sicher gelesen werden: %@",
    "Ein möglicherweise gesendeter OpenAI-Auftrag hat keine bestätigte Response-ID und kann deshalb nicht sicher ersetzt werden.",
    "OpenAI-Response-ID enthält unzulässige Zeichen.",
    "OpenAI-Auftragserstellung wurde mit HTTP %d abgelehnt.",
    "OpenAI-Hintergrundauftrag endete mit Status %@.",
    "unbekannt",
    "Episodenanalyse konnte nicht gespeichert werden - Hash, Revision oder Zusammenfassung fehlt.",
    "Zusammenfassungsdatei enthaelt keine vollstaendige Analyse.",
    "Episodenanalyse ist unvollständig.",
    "Episodenanalyse enthält keine Kapitel.",
    "Episodenanalyse verworfen — das gespeicherte Transkript wurde während der Analyse geändert.",
    "Das gespeicherte Transkript enthält keine gültigen Zeitmarken.",
    "Episode für das Podcast-Transkript wurde nicht gefunden.",
    "Podcast-Transkript enthält keine verlässlichen Zeitmarken und kann nicht für Kapitelgrenzen verwendet werden.",
    "Zeitcodiertes Podcast-Transkript konnte nicht stabil gespeichert werden.",
    "Kein verwendbares zeitcodiertes Podcast-Transkript gefunden.",
    "Podcast-Transkript ist leer.",
    "Podcast-Transkript konnte nicht geladen werden. HTTP %d",
    "Podcast-Transkript hat keine verlässlichen Zeitmarken. Die Audiodatei wird transkribiert.",
    "Podcast-Transkripte dürfen automatisch nur von öffentlichen HTTPS-Adressen geladen werden.",
    "Podcast-Transkript verweist auf eine lokale oder private Netzwerkadresse.",
    "Podcast-Transkript enthält zu viele Weiterleitungen.",
    "Podcast-Transkript enthält eine unsichere Weiterleitungsschleife.",
    "Podcast-Transkript lieferte keine sichere HTTPS-Antwort.",
    "Podcast-Transkript enthält zu viele oder ungültige Weiterleitungen.",
    "Podcast-Transkript-Adresse konnte nicht aufgelöst werden.",
    "Vorhandene Podcast-Kapitel haben überlappende explizite Grenzen.",
    "Vorhandene Podcast-Kapitel haben ungültige Endgrenzen.",
    "Episodenanalyse enthält keine Transkript-Revision.",
    "Episodenanalyse gehört zu einer anderen Transkript-Version.",
    "Rechenprofil wird gewechselt.",
]

for key in LOCALIZED_ERROR_KEYS:
    de_value = strings_value(DE_STRINGS, key)
    en_value = strings_value(EN_STRINGS, key)
    require(de_value is not None, f"German localization is missing: {key}")
    require(en_value is not None, f"English localization is missing: {key}")
    require(en_value != key, f"English UI would expose the raw German error: {key}")

for signature in (
    "private static func sponsorValidationError",
    "private static func analysisValidationError",
    "private func openAIAmbiguousCreateError",
    "private func openAIBackgroundManifestError",
):
    body = method_body(CHAPTER_GENERATOR, signature)
    require("NSLocalizedString(description" in body,
            f"{signature} must localize its literal description before exposing it.")

for raw_literal in (
    'NSLocalizedDescriptionKey: "Für diese Episode läuft bereits dieselbe OpenAI-Hintergrundanalyse."',
    'NSLocalizedDescriptionKey: "Episodenanalyse konnte nicht gespeichert werden - Hash, Revision oder Zusammenfassung fehlt."',
    'NSLocalizedDescriptionKey: "Zusammenfassungsdatei enthaelt keine vollstaendige Analyse."',
    'NSLocalizedDescriptionKey: "Episodenanalyse ist unvollständig."',
    'NSLocalizedDescriptionKey: "Episodenanalyse enthält keine Kapitel."',
):
    require(raw_literal not in CHAPTER_GENERATOR,
            f"New analysis error bypasses localization: {raw_literal}")

require('NSLocalizedString("Episodenanalyse verworfen — das gespeicherte Transkript wurde während der Analyse geändert."' in QUEUE,
        "The transcript-revision rejection must remain a localized queue error.")
require('NSLocalizedString("Rechenprofil wird gewechselt."' in WHISPER_BACKEND,
        "The compute-profile switch status must remain localized.")

print("Transcription analysis localization regression checks passed.")
