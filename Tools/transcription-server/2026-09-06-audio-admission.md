# Audioabgleich vor ASR und bewegliches Player-Cover

## Anforderungen und Ursachen

Ein Serverauftrag darf erst nach dem Vergleich mit der vollständigen Audioquelle der App zur Spracherkennung gelangen. Bisher fehlte der Client-Audiohash im Auftrag; die App konnte eine Abweichung erst vor dem Import ablehnen. Der rote API-/Worker-Test zeigte: Ein Auftrag ohne Hash wurde angenommen, das Hashfeld war sogar als unbekannt verboten.

Beim Aufziehen des Covers schalteten beide Player-Header-Layoutpfade `tableView.scrollEnabled` anhand der aktuell sichtbaren Kapitel/Lesezeichen/Warteschlange/Fehlermeldung aus. Während der Audioprüfung gab es weder freigegebene Kapitel noch einen Fehler; die Geste blieb deshalb gesperrt, bis der asynchrone Zustand wechselte. Der Test führt die tatsächlichen Scroll-Zuweisungen für offene, fehlgeschlagene und fertige Prüfung aus: vier rote Fälle vor dem Fix, alle sechs danach grün. Die Blockade dieses Pfads war eine explizite Gestensperre, kein Nachweis einer synchronen Hashberechnung auf dem Main-Thread.

## Verbindlicher Ablauf

1. Die App benötigt die vollständige lokal gecachte Folge. Fehlt sie, wird kein Serverauftrag gesendet; die Rückmeldung fordert zum vollständigen Download auf. Die Änderung startet keinen zusätzlichen automatischen Download.
2. Der tatsächliche Dateiinhalt wird inkrementell in einem Utility-Task gehasht. Die App persistiert die Prüfsumme zusammen mit der unveränderlichen Request-UUID, bevor sie POST sendet. Nach den asynchronen Übergängen werden Eigentümerschaft und Dateisnapshot erneut geprüft. Austausch/Abbruch verhindern POST.
3. Die API verlangt `client_audio_sha256`. Eine UUID mit anderer Quelle wird abgelehnt. Gleiche Episoden verschiedener Nutzer behalten getrennte Prüfsummen; der Episoden-URL wird keine Audioidentität unterstellt.
4. Nach dem tatsächlichen Serverdownload berechnet der Worker den Hash. Unter derselben Datenbanksperre wie die Annahme veröffentlicht er die bestätigte Quelle des aktuellen Jobs und lehnt abweichende Nutzeraufträge einzeln ab. Passt kein aktueller Nutzerauftrag, beginnt keine ASR. Passende Nutzer dürfen die gemeinsame Arbeit weiterverwenden.
5. Später hinzukommende Nutzer werden gegen die bereits bestätigte Jobquelle bzw. ein fertiges Ergebnis geprüft. Eine neue Worker-Übernahme verwirft den alten Job-Nachweis und prüft die erhaltene/heruntergeladene Quelle erneut vor ASR.
6. Die App prüft weiterhin vor dem Artefaktabruf, vor dem Speichern und beim Laden/Anzeigen die aktuelle Audiozuordnung. Fertige Artefakte werden nur bei passender Quelle wiederverwendet. Eine gemeinsame Warnung über bloße Dauerangaben kann einen exakten Hashnachweis nicht mehr überschreiben; tatsächliche Zeitgrenzen bleiben strikt geprüft.
7. Ein verlorener POST oder Neustart behält UUID und Audiohash. Alte Aufträge ohne Hash dürfen keine neue ASR beginnen; die Rückmeldung fordert einen neuen, dann quellgeprüften Auftrag. Fehlende Prüfdaten werden nicht als unterschiedliche Audiodateien ausgegeben. Eine belegte Abweichung wird nicht ohne Inhaltsbeleg als dynamische Werbung bezeichnet.
8. Das Cover bleibt unabhängig von allen Transkriptzuständen scrollbar. Kapitel, Sprünge und Auto-Skip bleiben davon getrennt an ihre gültigen Audio-/Zeitnachweise gebunden.

Die Worker-Vor-ASR-Pflicht betrifft Geräteaufträge (`api_episode` und `api_episode_recovery`). Unabhängig vom Gerät konfigurierte Betreiber-/Feed-Verarbeitung besitzt keine behauptete Client-Audioidentität. Deren Ergebnisse dürfen ebenfalls nur bei passendem Gerätehash importiert werden.

## Auslieferung und Belege

Zehn Dateien wurden nach erneutem Vergleich mit dem tatsächlichen Serverstand ausgeliefert. Zwei additive Datenbankspalten speichern Geräte-/Job-Audiohashs. Backup: `var/backups/audio-admission-20260906`; Code, Berechtigungen und vorherige Request-/aktive Jobdaten gesichert. API und Worker neu gestartet, öffentliche Bereitschaft danach bestätigt. Öffentliche API meldet Schema `2026-09-06.3` und das erforderliche Hashfeld.

Release-Testbuild 4.0 (37), Transkription am optimierten Binary aktiviert geprüft und Signatur verifiziert, auf Chris’ iPhone installiert. Kein TestFlight-Upload. Der abschließende sichtbare Geräteabruf ist noch offen: Die App wechselte beim Start vor der Wiedergabe-Wiederherstellung in den Hintergrund; ein erneuter Vordergrundstart scheiterte an der Geräteverbindung. Dafür ist kein Erfolg behauptet.

[Patch](2026-09-06-audio-admission.patch), [Dateimanifest](2026-09-06-audio-admission-manifest.json), [Prüfprotokoll](2026-09-06-audio-admission-verification.json).

## Ausgeführte Prüfungen

```sh
python3 Tools/server_transcription_audio_admission_regression_test.py
python3 Tools/server_transcription_cancellation_runtime_test.py
python3 Tools/server_transcription_admission_runtime_test.py
python3 Tools/server_transcription_errors_runtime_test.py
python3 Tools/server_poll_lifecycle_runtime_test.py
python3 Tools/transcription_audio_identity_runtime_test.py
python3 Tools/server_transcript_source_binding_regression_test.py
python3 Tools/player_transcript_audio_binding_regression_test.py
python3 Tools/player_chapter_scroll_availability_regression_test.py
python3 Tools/player_audio_notice_state_regression_test.py
python3 Tools/server_transcription_client_contract_regression_test.py
python3 Tools/localization_coverage_regression_test.py
git diff --check
```

Server mit produktiver Python-Umgebung, isolierten Testdaten: `tools/audio_admission_regression.py` (9), `tools/queue_admission_mysql_regression.py --audio-admission` (9; temporäre Datenbank danach entfernt), `tools/lifecycle_regression.py` (56). Die Tests umfassen fehlende/wechselnde Identität, parallele Nutzer, spätes Hinzukommen, fertige Ergebnisse, Wiederholung, einzelne Abbrüche und Neustart/Claim-Abgrenzung.

Zusätzlich `tools/audio_download_preflight_regression.py --source-url-file <private-datei>`: vollständiger realer öffentlicher Sternengeschichten-Download mit absichtlich falschem Clienthash, echter API-/Worker-/Hashpfad, isolierte Datenbank. Abbruch vor Dauerprüfung und ASR, null ASR-Aufrufe, Ablehnung anschließend über die Request-API geprüft. Keine Produktionsaufträge angelegt und keine Modellinferenz gestartet. Dieser zusätzliche Test liegt als Patch/Prüfwerkzeug vor, wurde nicht als laufender Produktionsdienst eingerichtet.
