# Client-Fehleranalyse vor isolierten Regressionen (27.09.2026)

Beobachtung: Nutzer sehen keine verständliche Bestätigung der Übergabe und keine belastbare Auskunft über aktuelle Serverarbeit. Bei Dienststörungen stehen interne Zuständigkeiten („operator“, „worker“, „resources“) im nutzerseitigen Status.

Erwartung: Eine validierte Annahme bestätigt den gespeicherten Auftrag; nur reale Verarbeitungsdaten beschreiben Fortschritt. Störungen beschreiben die konkrete Auswirkung und die nächste Aktion, keine Infrastrukturrollen.

Abgrenzung der isolierten Client-Prüfung: Der echte Simulator-App-HTTP-Ablauf wird separat erweitert und belegt Übergabe, Phasen, Import, Transportfehler und Neustart. Fehlerhafte, veraltete oder inkonsistente Fortschrittsantworten werden hier an den tatsächlich kompilierten Produktionsmethoden geprüft; diese Matrix lässt sich nicht verlässlich gegen den produktiven Server erzeugen, ohne falsche Messwerte oder defekte Zustände in Produktion zu schreiben. Der Test ersetzt HTTP/Cache-Schnittstellen, kopiert aber weder Zustandsautomat noch Persistenz-/Auswertelogik.

Konkrete Fehlergrenzen vor Teständerungen:
- Ablehnung vor Annahme darf niemals behaupten, dass ein Serverauftrag läuft oder später automatisch fortgesetzt wird.
- Dienstpause nach bestätigter Annahme muss den Auftrag erhalten und seine automatische Fortsetzung benennen; keine „Betreiber“-Handlungsaufforderung an den Nutzer.
- Empfangene Messdaten dürfen weder verworfen noch zu einem erfundenen Gesamtfortschritt umgerechnet werden.
- Messwerte einer vorherigen Phase dürfen nach Phasenwechsel, Fehler, neuer Anfrage oder Import nicht weiter angezeigt werden.
- Fehlende oder ungültige Messdaten dürfen weder Prozentwerte noch Restzeiten erzeugen. Ein Messwert größer als sein Gesamtwert, ein negatives Gesamtmaß und eine unbekannte Einheit sind keine gültigen Fortschrittsbelege.
- Der letzte bestätigte Messstand muss einen Neustart überstehen; neue Bestätigungen müssen sichtbare Queue-Benachrichtigungen auslösen.

Plattform: Swift-6-Laufzeit auf macOS, Produktions-Manager mit kontrollierter Netzwerk-/Dateigrenze. Kommando: `python3 Tools/server_transcription_admission_runtime_test.py`.

## Ergebnis

Vor Produktionsänderung schlugen die Sprachregression (4 Pflichten) und danach die Work-Regression (12 Pflichten) am echten Manager fehl. Die Tests prüfen keine Quelltextschreibweise; sie dekodieren kontrollierte Antworten, wenden die echten Übergänge an, lesen die echten Objective-C-Properties und laden die atomar persistierte Queue in einer neuen Managerinstanz.

Umgesetzt: `episode.work` wird pro Phase als typisierter Messstand übernommen und persistiert. Gemessene Bytes/Audiosekunden und die serverseitige Schrittrestdauer werden unverändert exponiert; daraus entsteht kein erfundener Gesamtanteil. Fehlende Gesamtgröße bleibt unbekannt. Ungültige Messdaten stoppen die Statusbehauptung mit erhaltener Auftragsidentität. Phasenwechsel, Import und Endzustände löschen vorherige Messwerte. Eine angenommene Dienstpause bleibt explizit als Pause erkennbar. Nutzertexte nennen den gespeicherten Auftrag und die automatische Fortsetzung statt Infrastrukturrollen.

Verifikation (alle bestanden):
- `python3 Tools/server_transcription_admission_runtime_test.py`
- `python3 Tools/server_transcription_cancellation_runtime_test.py`
- `python3 Tools/server_transcription_errors_runtime_test.py`
- `python3 Tools/server_transcription_storage_runtime_test.py`
- `python3 Tools/server_transcription_retry_interval_runtime_test.py`
- `python3 Tools/server_poll_lifecycle_runtime_test.py`
- `git diff --check -- Classes/ServerTranscriptionManager.swift Classes/TranscriptionQueue.swift`

Die gesonderten App-E2E- und UIKit-Nachweise werden vom Gesamtablauf ergänzt. Diese isolierten Läufe sind allein kein E2E-Nachweis.
