# Kostenprüfung vom 5. September 2026

Quelle: direkte lesende Abfragen der produktiven MariaDB sowie der authentifizierten DeepSeek-Endpunkte `/user/balance` und `/models`. Zeitpunkt vor dem Wechsel auf OpenAI.

## Guthaben und historische Kosten

DeepSeek meldet `is_available: false` und USD `-0.00`: Es steht kein Guthaben mehr zur Verfügung. Der Guthaben-Endpunkt liefert keine Zahlungshistorie; die vom Nutzer genannten ursprünglichen 10 USD lassen sich damit nicht vollständig abrechnen.

Die Serverdaten enthalten 3.458 KI-Aufrufe seit dem 10. Juli und insgesamt 7,51395 USD **interne Schätzungen**, davon DeepSeek 5,79039 USD und Kimi 1,72356 USD. Kimi ist ein separates Anbieterkonto. Für DeepSeek wurden 3.376 erfolgreiche und 31 fehlgeschlagene Aufrufe gespeichert. 878 erfolgreiche Aufrufe haben keine Episoden-Zuordnung; eine zuverlässige nachträgliche Zuordnung ist nicht möglich.

Die bisherige Buchhaltung übernahm Tokens erst nach erfolgreicher Inhaltsvalidierung. Dadurch fehlten Kosten bezahlter, aber ungültiger oder abgeschnittener Antworten. Zusätzlich sind die gespeicherten Tokenpreise heute veraltet. Ohne Abrechnungsexport des Anbieters ist die Differenz zwischen 5,79 USD Schätzung und einer Aufladung von 10 USD nicht beweisbar aufteilbar.

## Kosten einer Episode

Die eigentliche Spracherkennung läuft lokal auf dem Server mit Whisper `large-v3-turbo` / int8. Der externe Anbieter analysiert Text für Werbung, Kapitel und Zusammenfassungen. Serverbetrieb und Rechenzeit kommen wirtschaftlich hinzu.

Die folgenden Beträge sind historische Schätzungen über die gesamte gespeicherte Lebensdauer einer Episode, inklusive möglicher Wiederholungen, **keine garantierten Einzelpreise**:

| Episode | Dauer | KI-Aufrufe | Gespeicherte Schätzung |
| --- | ---: | ---: | ---: |
| Sternengeschichten Folge 713 | 11,4 min | 3 | 0,001894 USD |
| Angriff auf die Informationsfreiheit | 59,2 min | 46 | 0,060967 USD |
| 630: Repeat 600 Times | 130,1 min | 337 | 0,586289 USD |

87,4 % der geschätzten DeepSeek-Kosten entfielen auf Sponsorprüfungen. Die aktuelle Pipeline besitzt begrenzte, überlappende Prüfintervalle und zusätzliche Detailprüfungen; sie enthält keine unbegrenzte Prüfschleife. Bei 60 Minuten entstehen allein für die erste Analyse und Gegenprüfung ungefähr 22 Aufrufe. Vollständige erfolgreiche Prüfschritte werden als Checkpoints wiederverwendet.

## Verfügbare Modelle und Abrechnungsarten

Der reale DeepSeek-Modellendpunkt liefert `deepseek-v4-flash`, `deepseek-v4-pro` und `deepseek-v4-flash-vision-exp`. Die [offizielle Preistabelle](https://api-docs.deepseek.com/quick_start/pricing/) nennt am Prüftag für Flash je Million Tokens: nicht gecachte Eingabe 0,22 USD außerhalb / 0,44 USD innerhalb der Spitzenzeit, Ausgabe 0,66 / 1,32 USD. Pro kostet jeweils das Dreifache. Diese aktuellen Tarife dürfen nicht rückwirkend als historische Rechnung ausgegeben werden.

Das separat angemeldete OpenAI-Konto bietet laut offiziellem Codex `model/list`: `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`, `gpt-5.4-mini` und `gpt-5.3-codex-spark`. Die Serverintegration wurde für `gpt-5.6-sol` geprüft. Ein Wechsel des Modells erfordert auch einen dafür geprüften lokalen Modellkatalog.

ChatGPT-Anmeldung nutzt das Kontingent des Abonnements; API-Schlüssel werden separat nach API-Nutzung abgerechnet. Siehe [offizielle Codex-Authentifizierung](https://developers.openai.com/codex/auth). Inklusivvolumen hat keinen belastbaren USD-Preis je Auftrag und wird deshalb ausdrücklich als `chatgpt_subscription` mit Tokens und unbekanntem Einzelpreis ausgewiesen. Die Integration kauft keine Credits und löst keine Nutzungs-Resets aus.

Neue Nutzungsdatensätze enthalten Anbieter, Modell, Zweck, Job-ID und Abrechnungsart. Auch bei ungültigen oder abgeschnittenen Antworten werden tatsächlich gemeldete Tokens erfasst. Fehlende Nutzungsangaben gelten nicht als Nachweis kostenloser Verarbeitung.
