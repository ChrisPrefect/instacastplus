# iOS 27: Siri-Integration und Kapitelvergleich

Stand: 15. September 2026. Xcode 27.0 (27A266a), iPhone 17 Pro mit iOS 27.0 (24A435).

## Ergebnis des Modellvergleichs

Folge: **Spektrum-Podcast – „Hantavirus auf Kreuzfahrtschiff: Wie gefährlich ist der Ausbruch?“** Vier Originalkapitel des Publishers. Das vorhandene Transkript reicht bis 1.219,2 Sekunden; die Originalkapitel bis 1.231 Sekunden.

| Messung | Server: gpt-5.6-sol | Apple lokal: iOS 27 |
|---|---:|---:|
| Laufzeit der Generierung | 8,57 s | 12,57 s |
| Generierte Kapitel | 4 | 3 |
| Originalgrenzen innerhalb ±5 s | 3 von 4 | 0 von 4 |
| Originalgrenzen innerhalb ±30 s | 3 von 4 | 1 von 4 |
| Spätester erzeugter Kapitelstart | 825,38 s | 106,98 s |

**In diesem Direktvergleich liefert der Server deutlich bessere Kapitel.** Er trifft die drei späteren Themenwechsel mit Abweichungen von 2,53 / 0,06 / 2,93 Sekunden. Das erste Thema beginnt beim Server zu früh, bereits bei 0 statt 119,19 Sekunden.

Das lokale Modell liefert Starts bei 0 / 22,68 / 106,98 Sekunden. Die späteren Themenwechsel fehlen. Außerdem übernimmt es den Transkriptfehler „Hunter-Virus“ in einen Titel, obwohl der Episodentitel die korrekte Schreibweise enthält. Der eine zeitliche Treffer innerhalb 30 Sekunden belegt keine korrekte inhaltliche Zuordnung: Der lokale Titel betrifft bereits den Schiffsausbruch.

## Testverfahren und Grenzen

- Beide Modelle erhielten denselben vollständigen Text, denselben vom produktiven Server erzeugten Aufgaben-Prompt und dieselbe Systemanweisung. Originalkapitel und Sponsorhinweise wurden den Modellen nicht gezeigt.
- Beide Antworten wurden durch dieselbe produktive Funktion `normalize_ai_topic_chapters` ausgewertet. Sie löst Gruppenverweise in Zeiten auf. Die lokalen Rohantworten enthielten dreimal `startTime: 0`; die oben genannten Zeiten stammen aus den zugehörigen `startIndex`-Werten.
- Grenzzuordnung: chronologisch, höchstens ein Kandidat je Originalgrenze; maximale Anzahl Treffer innerhalb der Toleranz, danach minimale Gesamtabweichung. Publisher-Kapitel sind eine redaktionelle Referenz, keine einzig mögliche Einteilung.
- Je Modell **ein** erfolgreicher Generierungslauf. Keine Aussage über Streuung oder eine generelle Rangfolge. Kein Vergleich mit dem alten iOS-26-Modell.
- Apple meldet auf diesem iPhone **8.192 Kontext-Tokens**. Der vollständige Request benötigt laut Apples Tokenzähler 6.349 Tokens. Das Antwortbudget beträgt 1.024 Tokens, entsprechend dem bestehenden Budget der App. Ein vorheriger Vorbereitungslauf mit 2.600 reservierten Antwort-Tokens wurde vor der Inferenz als zu groß abgelehnt; dabei entstand keine Modellantwort.
- Der lokale Lauf nutzt `SystemLanguageModel.default`, freie JSON-Ausgabe und Temperatur 0,6. Der Server verwendet seine produktive Codex-Konfiguration. Modell-Tokenizer und Sampling-Einstellungen sind unterschiedlich; Tokenzahlen sind deshalb kein direkter Effizienzvergleich.
- Gemessen wurde Kapitelgenerierung einschließlich des jeweiligen Aufrufs, ohne neue Transkription, Audiodownload, Import oder Kapitel-Sprünge. Die mehrstufige, strukturierte lokale Kapitelpipeline der App wurde in diesem Direktvergleich **nicht** ausgeführt.
- Der Mac meldete `modelNotReady`; die erfolgreiche lokale Messung lief in der separaten **Chapter Benchmark**-App auf dem iPhone.
- Der Benchmark schreibt keine Produktionsaufträge oder bestehenden Podcast-Ergebnisse. Der Serververbrauch ist im Ergebnis als ChatGPT-Abonnementverbrauch erfasst, nicht als kostenloser API-Aufruf.

Hashes, Rohantworten, normalisierte Kapitel und Messwerte: [results.json](results.json). Das vollständige Testinput liegt lokal unter `build/ios27-readiness-20260915/spektrum/input.json`; es wird nicht ins Repository kopiert.

## Umgesetzte App-Anpassungen

- iOS-27-Audioschemata für Podcast, Episode und Abspielen; Titelsuche, Vorschläge und Auflösung bestehender Feed-/Universal-Links.
- Wiedergabe sowie Einfügen als nächster/letzter Eintrag über die bestehende AudioSession. Nicht unterstützte Shuffle-/Repeat-Anforderungen erhalten eine lokalisierte Fehlermeldung.
- Identifikatoren an Podcast-/Episodenzellen, Episodendetails und Player. Leeren oder Wiederverwenden einer Ansicht entfernt ihre bisherige Zuordnung.
- Bestehende Spotlight-Einträge erhalten die neuen Audio-Entity-Typen. Kapitel-/Transkript-Metadaten bleiben im vorhandenen Index. Versionsgebundene Neuindizierung über den separaten Hintergrund-Coordinator; Abschlussmarker erst nach bestätigter Indexierung.
- Bisherige Entity-Typen für gespeicherte Kurzbefehle und iOS-17-Mindestversion bleiben erhalten. DE/EN-Texte ergänzt.

Die lokale FoundationModels-Integration verwendet bereits das Systemmodell und dessen tatsächliche Kontextgröße. Für den Modellwechsel mit iOS 27 ist keine zusätzliche Modellauswahl nötig. Der Direktvergleich rechtfertigt keinen automatischen Wechsel vom Server zur lokalen Verarbeitung.

## Validierung

Erfolgreich: iOS-27-Simulator-Build und Start, exportierte App-Intents-Metadaten, fünf fokussierte Source-/Lokalisierungstests sowie ein `AppIntentsTesting`-Lauf gegen die installierte App. Der Laufzeittest prüft beide neuen Entity-Queries und den Fall ohne Treffer auf einer leeren Testbibliothek. Eine positive Bildschirmauflösung und gesprochene Siri-Befehle wurden damit nicht nachgewiesen.

```sh
xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Debug -destination 'platform=iOS Simulator,id=675CC86D-C1EA-41D7-A244-0318E0EE1121' -derivedDataPath build/SimDD build
python3 Tools/ios27_audio_schema_regression_test.py build/SimDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app
python3 Tools/core_spotlight_podcast_episode_regression_test.py
python3 Tools/ios_integration_metadata_regression_test.py
python3 Tools/siri_media_intent_handling_regression_test.py
python3 Tools/localization_coverage_regression_test.py
python3 Tools/ios27_benchmark_project.py build/ios27-readiness-20260915/spektrum/input.json build/ios27-readiness-20260915/iphone-benchmark --intents-tests
xcodebuild -project build/ios27-readiness-20260915/iphone-benchmark/ChapterBenchmark.xcodeproj -scheme AudioSchemaTests -destination 'platform=iOS Simulator,id=675CC86D-C1EA-41D7-A244-0318E0EE1121' -derivedDataPath build/ios27-readiness-20260915/intent-test-DD test
```

Die nötige Serverkorrektur ist im [Serverprotokoll](../../transcription-server.md) dokumentiert: CLI 0.154.0 war installiert, aber nur 0.152.1 zugelassen. Erst nach fehlgeschlagenem Reproduktionstest und erfolgreicher Prüfung der neuen CLI wurde die Versionsfreigabe aktualisiert. 17 Adaptertests, fünf Usage-Tests und der echte Test `tools=[]` bestanden; `/health` bestätigt wieder `ok:true`.

## Layout, Siri und Apple-Programmstatus

Die App behält ihre Navigation und Bedienung. iOS 27 verfeinert die Liquid-Glass-Darstellung; die neue Siri-Anbindung ergänzt das Verständnis sichtbarer Inhalte. Quellen: [UIKit-Neuerungen](https://developer.apple.com/documentation/updates/uikit), [Modernize UIKit](https://developer.apple.com/videos/play/wwdc2026/278/).

Die Verfügbarkeit der neuen Siri hängt zusätzlich von Apples Sprach-/Regionsfreigaben ab; Deutsch ist in der Ankündigung vom 14. September nicht als Startsprache aufgeführt. [Apple-Ankündigung](https://www.apple.com/newsroom/2026/09/siri-ai-a-profoundly-more-capable-and-personal-assistant-is-here/)

**Small Business:** Apple bestätigt in der E-Mail vom 15. September, 23:21 Uhr, den Eingang der Anmeldung und kündigt die Prüfung an. Die Aufnahme ist zu diesem Zeitpunkt noch nicht bestätigt. Das zuvor blockierte Formular enthielt ein „Yes“ bei der Entscheidungsbefugnis über ein weiteres Entwicklerkonto.

Private Cloud Compute wurde nicht aktiviert. Apple nennt eine bestätigte Small-Business-Teilnahme, die Downloadgrenze und die entsprechende Berechtigung als Zugangsvoraussetzungen. [Apple Private Cloud Compute](https://developer.apple.com/private-cloud-compute/)
