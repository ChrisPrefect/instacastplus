# Fehlende Kapitel / falsche Audiozuordnung — 6. September 2026

Gemeldet: iPhone, Sternengeschichten Folge 719, Player bei 0:19, keine Kapitel und abgeschnittener Hinweis zur Audioversion. Erwartet: passende Kapitel erscheinen; generierte Transkripte werden ausschließlich zur nachgewiesenen Audiodatei geladen. Keine Behauptung dynamischer Werbung ohne Beleg.

## Bestätigte Ursache

Die vollständige iPhone-MP3 (11.076.565 Bytes) stimmt per SHA-256 exakt mit der Quelle von Analyse und SRT überein. Der Server verwendete jedoch `ffprobe format=duration`, einschließlich MP3-Endpadding. Das letzte Kapitel endete bei 772,885 Sekunden, das tatsächlich abgespielte iOS-Asset bei 772,843174603 Sekunden. Die strikte Timelineprüfung lehnte deshalb alle vier Kapitel ab. Keine abweichende Werbeversion; keine Lockerung der Schutzprüfung.

Der rote Test reproduzierte die Differenz sowohl mit einer real erzeugten 0,25-Sekunden-MP3 als auch mit der betroffenen Datei. Der Server misst jetzt die präsentierten decodierten Samples, einschließlich der Decoderinformationen zu Priming/Endpadding. Worker und Chunkplanung verwenden dieselbe Messung. Dauergrenze, Prozessabbruch, Ressourcenprüfung und harte Messdeadline bleiben erhalten. MP3, AAC, WAV und Opus sind gezielt geprüft.

Fünf Serverdateien wurden nach Vergleich mit dem tatsächlichen Produktivstand ausgeliefert; Backup: `var/backups/decoded-duration-20260906`. Die vier Artefakte der Folge 1414 wurden mit den bestehenden, quellverifizierten Ergebnissen und den tatsächlichen Assembly-Funktionen neu zusammengesetzt. Letztes Kapitelende jetzt 772,843 Sekunden; SRT unverändert, keine neuen KI-Aufrufe. Alte Artefakte und Datenbankwerte bleiben im Backup erhalten. Andere historische Folgen wurden nicht pauschal umgeschrieben.

Belege: [Server-Patch](2026-09-06-decoded-duration.patch), [Datei-Prüfsummen](2026-09-06-decoded-duration-manifest.json), [Reparatur](2026-09-06-sternengeschichten-duration-repair.json).

## App-Korrektur

- Vor dem Herunterladen der vier Server-Artefakte muss die vollständig gecachte Audiodatei vorhanden sein und ihr berechneter SHA-256 mit der Serverquelle übereinstimmen. Fehlende Identität, fehlende Datei und abweichender Hash werden abgelehnt. Nach den asynchronen Arbeiten wird die Datei vor dem Speichern erneut auf Austausch geprüft.
- Generierte Transkripte werden erst nach erfolgreicher Prüfung der tatsächlich aktuellen Wiedergabequelle geladen. Das gilt für Datei-/Netzwerkladen, Prefetch, asynchrone Rückgaben und beide UI-/Speichercaches. Episoden-, Audio- oder SRT-Wechsel entziehen den alten Nachweis. Publisher-Transkripte behalten ihren gesonderten Quellpfad.
- Scheitert nur der lokale Import eines fertigen Server-Ergebnisses, behält „Erneut versuchen“ die angenommene Anfrage und lädt das fertige Ergebnis erneut. Der Zustand ist über einen App-Neustart persistent; kein DELETE/neuer POST und keine erneute Server-Transkription durch diesen Retry.
- Eine laufende Audioprüfung wird nicht als Fehler dargestellt. Der beanstandete lange Text ist aus DE/EN entfernt. Die tatsächlichen Footer-Methoden verwenden mehrzeiligen Text und automatische Höhe; DE/EN bei 320 Punkten Breite und Schriftgrößen 13/44 geprüft.

**Grenze:** Die Prüfung vor dem Artefaktabruf ist umgesetzt. Ein Protokoll zur Prüfung des Client-Audiohashs bereits vor einer neuen Server-ASR ist noch nicht umgesetzt. Eine Abweichung allein beweist keine dynamische Werbung. Die App kann keine passenden Zeitmarken für eine anders ausgelieferte Datei erfinden.

## Tatsächliches iPhone-Ergebnis

Release-Testbuild 4.0 (37), Transkription am optimierten Binary als aktiviert geprüft, Signatur geprüft, installiert und gestartet. Kein TestFlight-Upload.

Nach dem finalen Neustart am 06.09.2026 um 06:23 Uhr Schweiz:

- `04:23:24.764Z`: Analyse und SRT passen zur aktuellen Audioquelle, beide Snapshots aktuell.
- `04:23:24.766Z`: erst anschließend beginnt der Transkript-Ladevorgang.
- `04:23:24.768Z`: `audioIdentityVerified=1`, `timelineVerified=1`, vier Kapitel; Assetdauer 772,843174603, letztes Ende 772,843.
- `04:23:24.781Z`: 117 Transkript-Cues erfolgreich geladen.
- Screenshot des tatsächlichen App-Fensters visuell geprüft: alle vier Kapitel vollständig in der Liste, kein Fehlerfooter. Lokal: `/tmp/instacast-final-iphone.png`.

Server nach Auslieferung über `/health` geprüft: verfügbar, Worker aktiv, kein Anbieter-/Ressourcenfehler. Der vorhandene Job der reparierten Folge bleibt abgeschlossen; keine neue Verarbeitung dieser Folge.

## Wiederholbare Prüfungen

```sh
python3 Tools/player_transcript_audio_binding_regression_test.py
python3 Tools/server_transcript_source_binding_regression_test.py
python3 Tools/server_transcription_import_episode_deletion_runtime_test.py
python3 Tools/server_transcription_admission_runtime_test.py
python3 Tools/server_transcription_cancellation_runtime_test.py
python3 Tools/server_transcription_errors_runtime_test.py
python3 Tools/server_poll_lifecycle_runtime_test.py
python3 Tools/server_transcript_duration_bounds_regression_test.py
python3 Tools/player_audio_notice_state_regression_test.py
python3 Tools/player_audio_notice_layout_regression_test.py --width 320 --locale de
python3 Tools/player_audio_notice_layout_regression_test.py --width 320 --locale en
python3 Tools/playback_artifact_freshness_runtime_test.py
python3 Tools/player_generated_timeline_visibility_regression_test.py
python3 Tools/localization_coverage_regression_test.py
git diff --check
```

Server (mit produktiver venv, isolierte Testdaten): `tools/decoded_audio_duration_regression.py`, `tools/worker_edge_cases_regression.py`, `tools/pipeline_resume_regression.py`. Sechs Dauertests, 19 Worker-Grenzfalltests und zwölf Wiederaufnahmetests bestanden. Keine Modellinferenz in diesen Regressionstests.
