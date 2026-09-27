# Kapitelpositionen: Wiederaufnahme und automatische Sprünge

Nachweis vom 27.09.2026, lokaler Arbeitsstand. Eine laufende Paralleländerung
an den temporären **Episoden**positionen in PlaybackManager.m blieb erhalten.
Diese Korrektur betrifft die separaten **Kapitel**positionen.

## Fehler und Ursache

Bei eingeschaltetem `RememberChapterPosition` speicherte die Kapitelauswahl
die Position des verlassenen Kapitels in `ChapterPlaybackPositions`.
Beim Wiederaufnehmen blieb dieser Eintrag bestehen, auch nachdem das Kapitel
anschließend vollständig gehört oder automatisch verlassen wurde.
Die nächste Auswahl verwendete deshalb den alten Zwischenstand.
Automatische Sprünge erzeugten ihn nicht selbst. Manuelle Kapitel-Skip-Aktionen
speicherten dagegen bislang gar keine Kapitelposition.

Reproduktion mit der echten Simulator-App, 24 Sekunden PCM-Audio und Kapiteln
bei 0, 8 und 16 Sekunden:

1. Bei 0:04 aus Kapitel 1 in Kapitel 3 wechseln.
2. Kapitel 1 erneut auswählen: Wiederaufnahme bei 0:04 ist richtig.
3. Über 0:08 hinaus abspielen, dann Kapitel 1 wieder auswählen.
4. Erwartet: 0:00. Vorher tatsächlich: 0:04. Nachher: 0:00.

## Korrektur

Beim erneuten Betreten eines Kapitels wird dessen alter Unterbrechungsmerkpunkt
entfernt. Die Ermittlung benutzt die effektive Position einschließlich eines
laufenden Seeks, nicht den vorübergehend festgehaltenen UI-Kapitelindex.
Nur ein erneutes manuelles Verlassen speichert einen neuen Merkpunkt.
Nächstes/vorheriges Kapitel und der manuelle Kapitelende-Skip verwenden jetzt
dieselbe Speicherlogik. Ihre bisherigen Sprungziele bleiben erhalten.

Es gibt keine pauschale Löschung historischer Einträge: Ohne damaligen
Wiedergabeverlauf kann man einen alten falschen Merkpunkt nicht zuverlässig
von einer tatsächlich noch offenen manuellen Unterbrechung unterscheiden.

## Ergebnis und Umfang

Vorher: **2/14 bestanden**, **12/14 fehlgeschlagen**. Nachher: **14/14 bestanden**.

- Manuelle Auswahl speichert und setzt korrekt fort.
- Fertighören nach direkter Wiederaufnahme und nach natürlichem Wiedereintritt.
- Automatischer Werbesprung bei Offset 0 und bei Offset −2 Sekunden ins vorherige Kapitel.
- Automatisches Ende über Skip-End-Zeit, letztes Werbekapitel und natürliches Medienende.
- Manuelles nächstes/vorheriges Kapitel und Kapitelende-Skip merken die Abgangsposition.

Umgebung: eigener Simulator `Instacast Chapter Resume Regression`, iPhone 17 Pro,
iOS 27.0, UDID `3C62121F-70CC-45E4-97D4-CDF0684BDE51`, Debug-Build mit Entitlements.
Der Testtreiber erzeugt die Fixture in Core Data, öffnet die echte Kapitelansicht,
ruft deren Auswahl-Handler und die Player-Aktionen auf und beobachtet AVPlayer,
NSUserDefaults und automatische Übergänge. Er ersetzt keine Produktionsmethode.
Physische Touch-Gesten, ein Hardware-Audioausgang und reale Podcast-Dateien sind
nicht Teil dieses Laufs. UIKit-Screenshots zeigen die App; zusätzliche
Simulator-Screenshots können den Systemdialog für Mitteilungen enthalten.

## Wiederholen

Im Repository-Verzeichnis; der genannte eigene Simulator muss gestartet sein:

```sh
xcodebuild -quiet -project Instacast.xcodeproj -scheme Instacast -configuration Debug -destination 'platform=iOS Simulator,id=3C62121F-70CC-45E4-97D4-CDF0684BDE51' -derivedDataPath build/ChapterResumeDD -clonedSourcePackagesDirPath build/SimDD/SourcePackages build

python3 Tools/chapter_resume_simulator_test.py --udid 3C62121F-70CC-45E4-97D4-CDF0684BDE51 --app build/ChapterResumeDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --evidence build/chapter-resume/after

python3 Tools/chapter_resume_runtime_test.py
python3 Tools/playback_next_chapter_boundary_regression_test.py
python3 Tools/playback_autoskip_live_settings_runtime_test.py
python3 Tools/playback_replayed_skip_runtime_test.py
git diff --check -- Classes/PlaybackManager.m Tools/chapter_resume_simulator_test.py Tools/fixtures/chapter_resume_probe.m Tools/playback_next_chapter_boundary_regression_test.py Tools/chapter_resume_regression.md
```

Build und alle genannten Prüfungen erfolgreich. Die vier isolierten
Laufzeitprüfungen ergänzen den Simulator-Nachweis; sie ersetzen ihn nicht.

## Aufbewahrte Artefakte

- [Vorher: Soll/Ist-Vergleiche](/Users/Chris/Developer/instacastplus/build/chapter-resume/before-visible/checks.json)
- [Nachher: Soll/Ist-Vergleiche](/Users/Chris/Developer/instacastplus/build/chapter-resume/after/checks.json)
- [Umgebung und Binary-Hashes](/Users/Chris/Developer/instacastplus/build/chapter-resume/after/environment.json)
- [Befehle und Toolausgaben](/Users/Chris/Developer/instacastplus/build/chapter-resume/after/commands.log)
- [Alle Eingaben und Player-/Speicherzustände](/Users/Chris/Developer/instacastplus/build/chapter-resume/after/observations.jsonl)
- [Diagnoseereignisse der App](/Users/Chris/Developer/instacastplus/build/chapter-resume/after/Logs/Diagnostics.jsonl)
- [Kapitelansicht vorher](/Users/Chris/Developer/instacastplus/build/chapter-resume/before-visible/completed-chapter-app.png)
- [Kapitelansicht nachher](/Users/Chris/Developer/instacastplus/build/chapter-resume/after/completed-chapter-app.png)

Audio-Fixture und weitere Screenshots liegen jeweils im selben Nachweisordner.
Der Vorher-Lauf verwendet die vor der Kapitelkorrektur kopierte App unter
`build/chapter-resume/baseline.app`; sein Arbeitsstand-Hash beschreibt den
Quellstand beim Testaufruf, nicht den Ursprung dieses älteren Binary-Snapshots.
