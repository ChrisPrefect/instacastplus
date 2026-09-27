# Skip-Ende und erneutes Abspielen — 27.09.2026

## Befund und Zeitpunkt

Gemeldet: InstacastPlus 4.0 (44), iOS 27.0 (24A437). Eine durch Skip-Ende
abgeschlossene Folge startet erneut am Skip-Ende-Punkt und stoppt sofort.
Erwartet: tatsächlich ans Medienende springen, gespeicherte Abspielposition
löschen und als gehört markieren. Das gilt auch beim Wiederhören. Erneutes
Abspielen beginnt am Anfang beziehungsweise am konfigurierten Skip-Anfang.

Die übergebenen `InstacastPlus-CrashLogs.txt` belegen für Folge
`5130cacec6c850f3d5ba5ca11600762a`:

- 26.09.2026, 06:07:14 UTC: erster Skip bei 565 Sekunden, Mediendauer 572,443,
  Skip-Ende 8 Sekunden, zuvor ungehört.
- 26.09.2026, 07:04:08 / 10 / 13 / 17 UTC: vier Starts bei 565 Sekunden mit
  erneutem Skip. Dabei sind `episodeConsumed=1` und `episodePosition=572`.
- Die Sitzung `DCC8550A-AB6D-4047-821C-0C0D385DE214` meldet Build 44.

Die **wiederholte Stoppschleife** wurde durch Commit
`138e3f0833ae391b6f688febcf2fa7deaae3b9cc` vom **11.09.2026, 01:38:42 MESZ**
(Titel `sleep timer fix`) ermöglicht: Die Bedingung `!episode.consumed` wurde
aus dem Skip-Ende-Zweig entfernt. Skip-Ende sollte damit auch beim Wiederhören
gelten. Ein älterer Fehler wurde dadurch zur Schleife: Seit
`5ae0f15cb` vom **22.06.2026, 00:59:22 MESZ** schließt der Skip-Abschluss mit
`closeAndSaveCurrentPosition:NO`, ohne den temporären Resume-Eintrag zu entfernen.
Die normale Abschlussbehandlung entfernt ihn ausdrücklich.

Diese Datierung beschreibt die eingecheckte Codeänderung; sie belegt nicht den
ersten ausgelieferten Build. Die tatsächliche Fehlerschleife ist zusätzlich
durch die Nutzerlogs aus Build 44 und den unveränderten lokalen App-Build belegt.

## Ursache und Änderung

Zwei Positionsspeicher widersprechen sich: Core Data enthält das Episodenende,
`TemporaryPlaybackPositions` enthält noch die Position kurz vor dem Skip. Beim
Öffnen gewinnt der temporäre Wert. `consumed` allein darf keine Wiedergabe
verhindern, weil auch bereits gehörte Folgen erneut hörbar sein müssen.

Der bisherige Skip-Code führte einen eigenen Abschluss aus: Er speicherte die
Mediendauer als Resume-Position und schloss den Player vor dem tatsächlichen Ende.
Die anfängliche Bereinigung des temporären Eintrags behob die Neustart-Schleife,
entsprach aber noch nicht der präzisierten Skip-Ende-Semantik.

Zeit-Skip und letztes übersprungenes Kapitel springen jetzt mit dem exakten
`CMTime` der Mediendauer und Null-Toleranz ans Ende. Erst das echte
`AVPlayerItemDidPlayToEndTimeNotification` führt den vorhandenen regulären
Abschluss aus: gehört setzen, Core-Data-Position auf 0 zurücksetzen, temporären
Resume-Eintrag entfernen, speichern und gegebenenfalls die nächste Folge starten.
Die duplizierten Skip-Abschlüsse entfallen. Das vorhandene Skip-Flag verhindert
überlappende Sprünge und wird bei einem abgebrochenen Seek wieder freigegeben.

Beim Öffnen einer durch ältere Builds abgeschlossenen Folge wird deren veralteter
temporärer Eintrag weiterhin bereinigt. Eine teilweise wiedergehörte Folge
behält ihre normale Resume-Logik. Skip-Ende bleibt für gehörte Folgen aktiv.

## Reproduzierbarer App-Test

`Tools/playback_skip_end_simulator_test.py` erstellt eine 24 Sekunden lange
PCM-WAV mit 8 kHz und einen Podcast samt Folge in der echten Core-Data-Datenbank.
Der Testtreiber ruft dieselbe Player-Präsentation wie die Episodenauswahl auf.
AVPlayer, Zeit-Observer, Skip, Persistenz, Schließen und erneutes Öffnen laufen
unverändert im gebauten App-Prozess. Es werden keine Produktionsmethoden ersetzt.
Skip-Anfang: 2 Sekunden; Skip-Ende: 8 Sekunden. Die Kapitelvariante verwendet
ein Hauptkapitel von 0–16 und ein übersprungenes Outro von 16–24 Sekunden.
Die Altbestandsvariante beginnt mit `consumed=YES`, Position 24 und temporär 16.

Umgebung: eigener iPhone-18-Pro-Simulator mit iOS 27.0 (24A430), Xcode 27 SDK,
signierter Debug-Simulatorbuild. UDID:
`A6062D65-08EF-45B9-AF82-4D0812029282`.

```sh
xcrun simctl boot A6062D65-08EF-45B9-AF82-4D0812029282
xcodebuild -quiet -project Instacast.xcodeproj -scheme Instacast -configuration Debug -destination 'platform=iOS Simulator,id=A6062D65-08EF-45B9-AF82-4D0812029282' -derivedDataPath build/SimDD ONLY_ACTIVE_ARCH=YES build
python3 Tools/playback_skip_end_simulator_test.py --udid A6062D65-08EF-45B9-AF82-4D0812029282 --app build/SimDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --evidence build/skip-end-regression/seek-final
python3 Tools/playback_skip_end_simulator_test.py --udid A6062D65-08EF-45B9-AF82-4D0812029282 --app build/SimDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --evidence build/skip-end-regression/seek-final-completed --completed
python3 Tools/playback_skip_end_simulator_test.py --udid A6062D65-08EF-45B9-AF82-4D0812029282 --app build/SimDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --evidence build/skip-end-regression/seek-final-chapter --chapter
python3 Tools/playback_replayed_skip_runtime_test.py
python3 Tools/playback_autoskip_live_settings_runtime_test.py
git diff --check -- Classes/PlaybackManager.m Tools/playback_replayed_skip_runtime_test.py
```

Der vor der neuen Produktionsänderung erweiterte App-Test (`seek-before`)
scheiterte am fehlenden echten Medienende, der fehlenden regulären
Abschlussbenachrichtigung und der Position 24 statt 0 in der SQLite-Datenbank.
Er beobachtet AVPlayer und App-Abschlussbenachrichtigung bei Erst- und Wiederhören
und liest die gespeicherte Position direkt aus SQLite. Der ältere Test prüfte
nur die Resume-Schleife; dessen Befunde liegen separat unter `before-*`/`after*`.

Der erste Lauf nach der Seek-Änderung (`seek-after`) bestand die sechs
Abschlussprüfungen, verlor aber den unmittelbar neu geöffneten Player. Der
damalige Test entfernte die alte Player-Ansicht selbst, während deren regulärer
verzögerter Dismiss-Aufruf noch ausstand. `PlayerController` schließt bei diesem
Aufruf einen noch nicht bereiten Player. Das ist ein anderer Ablauf als eine
erneute Episodenauswahl aus der wieder sichtbaren Liste. Der Test wartet jetzt
auf `root.presentedViewController == nil`, bevor er erneut öffnet; er erzwingt
keine Dismissals und fügt keine feste Wartezeit hinzu. Die Beobachtung
`ready-to-replay` hält diesen UI-Zustand fest. Am Produktions-Dismiss-Pfad wurde
nichts geändert.

Die abschließenden drei App-Läufe (`seek-final`, `seek-final-completed`,
`seek-final-chapter`) bestehen jeweils **alle neun Prüfungen**: echtes Medienende
bei 24 Sekunden und genau ein regulärer Abschluss pro Durchlauf, gespeicherte
Position 0, temporärer Eintrag entfernt, gehört gesetzt, erfolgreicher Neustart
nahe Skip-Anfang und erneuter vollständiger Abschluss. Die direkte SQLite-Abfrage
liefert jeweils `(ZPOSITION, ZCONSUMED) = (0, 1)`. Simulatorbuild sowie beide
fokussierten Laufzeittests sind erfolgreich.

Die Verzeichnisse `build/skip-end-regression/` enthalten je Lauf die genaue
Befehlsliste, Umgebung, WAV, JSON-Zustände, Ergebnis, Screenshots und App-Logs.
Zusätzlich liegt unter `persisted-completion.json` die verwendete SQL-Abfrage
samt Episode-ID und gespeichertem Zustand. Medienuhr 24 und Resume-Position 0
sind bewusst unterschiedliche Werte: Der Player erreicht das Ende, während die
abgeschlossene Folge keinen gespeicherten Wiedereinstiegspunkt mehr hat.

Der vorhandene isolierte Laufzeittest führt die Produktionsmethoden für
Skip-Anfang, Skip-Ende, Seek und regulären Abschluss aus. Er prüft weiterhin
Erst-/Wiederhören, globale/Podcast-Werte, nächste Folge und SharePlay-Berechtigung.
Hinzu kommen der noch unveränderte Zustand während des ausstehenden Sprungs
und die Bereinigung erst beim Endereignis. Die SharePlay-Rollenentscheidung wird
hier isoliert geprüft, da im Simulator keine echte Gruppensitzung verbunden ist.
Die tatsächliche AVPlayer-Endebenachrichtigung belegt ausschließlich der App-Test.

Parallel entstanden weitere Änderungen an der Kapitelpositions-Speicherung in
`PlaybackManager.m`. Diese wurden erhalten und sind nicht Teil dieser Korrektur.
Unter `seek-build/PlaybackManager.m` liegt der unmittelbar vor dem neuen Build
gesicherte Stand der Playback-Datei; die Übereinstimmung wird nach dem Build
und nach den App-Läufen geprüft. Build- und fokussierte Testprotokolle liegen
unter `seek-build/`. Der Bericht beansprucht keine Validierung sachfremder
paralleler Arbeit.

## Grenzen

Kein Test auf dem physischen iPhone oder in einer aktiven SharePlay-Sitzung.
Die Player-Präsentation wird programmatisch ausgelöst, nicht durch einen
automatisierten Fingertipp. Ein Systemdialog zur Mitteilungsberechtigung kann
die aufbewahrten Screenshots überdecken; die Bewertung beruht auf tatsächlichem
AVPlayer-, Core-Data- und Resume-Zustand samt Diagnoseprotokoll. Es wurde kein
TestFlight-Build veröffentlicht.
