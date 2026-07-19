# Transkriptions-, Kapitel- und Sponsor-Pipeline

Stand: 19. Juli 2026

## Ziel und gewählte Architektur

Nach der einmaligen Einrichtung gelten ausschließlich die vorhandenen globalen und
podcastspezifischen Einstellungen. Neue Episoden abonnierter Podcasts werden ohne
weitere Benutzeraktion eingeplant. `SubscriptionManager` übergibt neu angelegte
Episoden direkt an `TranscriptionQueue`; die Einplanung hängt nicht davon ab, ob ein
UI-Observer die Episoden-Notification empfängt.

Ein optionaler Button beantragt auf iOS 26 einen sichtbaren,
langen `BGContinuedProcessingTask` für die aktuell wartende Queue. Er startet damit
diesen Lauf, erteilt aber weder eine dauerhafte Berechtigung noch aktiviert er alle
künftigen Episoden. Unabhängig davon beantragt die App für automatische Arbeit
`BGProcessingTask`s, die iOS opportunistisch startet.

Die Verarbeitung ist bewusst zweigeteilt:

1. Das Audio wird mit WhisperKit auf dem Gerät transkribiert. Im Vordergrund läuft
   WhisperKit mit GPU-Unterstützung; in gewöhnlichen Background-Processing-Läufen
   ausschließlich mit CPU und Neural Engine.
2. Das vom Benutzer ausgewählte Kapitelmodell ist autoritativ; die automatische Queue
   ersetzt es nicht durch einen vermeintlichen Standardanbieter. OpenAI API, OpenAI
   Codex OAuth, Anthropic und Kimi bleiben als bestehende Remote-Anbieter auswählbar.
   Das ausgewählte Remote-Modell erhält das vollständige Transkript mit stabilen
   Cue-IDs und liefert Kapitelstarts, belegte Sponsorgrenzen und die Zusammenfassung
   als ein strikt strukturiertes Ergebnis. Die Audiodatei wird nicht an den
   Modellanbieter übertragen. Nur wenn das OpenAI-API-Modell ausgewählt ist, verwendet
   dieser Anbieterpfad die offizielle Responses API mit `background=true` und einer
   persistierten Response-ID; die anderen Anbieter behalten ihren jeweiligen
   Request-Vertrag.

Lokale GGUF- und Apple-Foundation-Modelle bleiben für die bisherige Kapitel-only-
Funktion verfügbar. Sie werden nicht als gleichwertige Vollanalyse ausgegeben: Für
eine revisionsgebundene Zusammenfassung und evidenzbasierte Sponsorgrenzen ist ein
konfiguriertes Long-Context-Remote-Modell erforderlich.

## Belegte Ursachen aus den Geräte-DebugLogs

Die Diagnose wurde aus den App-Logs und Transkriptionsartefakten eines realen Geräts
mit iOS 26.5.2 und dem installierten Build 25 erstellt. Es wurden keine
Transkriptinhalte in diese Dokumentation übernommen.

| Beobachtung | DebugLog-Beleg | Ursache |
|---|---|---|
| Eine lange Episode benötigte in der Realität 16 h 48 min. | 22 Starts, davon 19 Pausen mit `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`, zwei App-Unterbrechungen; der schlussendlich aktive Lauf benötigte nur 178,6 s. | WhisperKit versuchte Metal-/GPU-Arbeit ohne Background-GPU-Grant. Die Wiederholungen, nicht die eigentliche Transkription, dominierten die Laufzeit. |
| Ein teilweise transkribierter Job verschwand. | Checkpoint mit 91 Cues bis 449,12 s vorhanden, persistierte Queue gleichzeitig leer; davor vier GPU-Abweisungen und eine App-Unterbrechung. | Checkpoint und Queue waren nicht gemeinsam wiederherstellbar; verwaiste Checkpoints wurden nie neu eingeplant. |
| Sponsorenerkennung markierte reine Musik. | Kurzer Lauf: SoundAnalysis 3,4 s, WhisperKit 95,4 s, zwei Kimi-K2.6-Modellaufrufe 27,1 s; Ergebnis `Sponsor: Musik-Outro`, obwohl die letzten Cues nur Musik waren. | Alte zweistufige Prompts hatten keine revisionsgebundenen Cue-Belege und keine harte Musik-/Outro-Ausschlussregel. |
| Publisher-Kapitel verhinderten jede Sponsorprüfung. | Nach erfolgreicher Transkription steht im Episodenlog ausdrücklich `Folge hat bereits Kapitel.` | Die Queue setzte Kapitelerzeugung bei jedem vorhandenen `CDChapter` auf aus, statt Sponsorsegmente über die Publisher-Zeitachse zu legen. |
| Das Entitlement war vorhanden, der GPU-Pfad dennoch nicht verfügbar. | App-Signatur und eingebettetes Provisioning enthalten `com.apple.developer.background-tasks.continued-processing.gpu=true`; `BGTaskScheduler.supportedResources` meldet auf dem Gerät trotzdem `gpuSupported=0`. | Kein Signing-Fehler. Der konkrete System-/Gerätezustand gewährt den Continued-GPU-Pfad nicht. |

## Umgesetzte Ursachenbehebung

### Automatische, persistente Queue

- `SubscriptionManager` speist neue Episoden unmittelbar in `TranscriptionQueue` ein.
  Die bestehende Notification bleibt ein UI-/Integrationssignal, ist aber nicht die
  Zustellgarantie für die automatische Pipeline.
- Problem: Nach einem erfolgreichen Core-Data-Merge konnte der Prozess vor dem
  asynchronen Queue-Dateischreibvorgang enden. Grund: Zwischen Episodenanlage und
  Queue-Snapshot gab es keinen dauerhaften Zustellnachweis. Lösung: Ein kleiner,
  atomar geschriebener Discovery-Outbox-Eintrag hält jeden neuen Episoden-Hash vor
  dem Queue-Handoff fest. Die Queue entfernt einen Hash erst nach einem erfolgreichen
  Queue-Snapshot; das gilt auch für einen bewusst aufgelösten Opt-out. Beim Start
  werden nur die Outbox-Hashes gezielt aus Core Data geladen. Noch nicht vorhandene
  Episoden bleiben für den nächsten Feed-Refresh vorgemerkt, doppelte Übergaben sind
  mengenbasiert idempotent.
- Pro Feed werden `yes`, `no` und `default` exakt gegen die bestehenden globalen
  Einstellungen aufgelöst. Die Implementierung aktiviert keine Einstellung selbst.
- Problem: Ein persistierter Job konnte nach Abbestellen des Podcasts, Abschalten der
  Automatik oder Wechsel des ausgewählten Anbieters trotzdem noch starten. Grund: Die
  Queue behandelte die beim Enqueue gespeicherte Absicht als dauerhaft autoritativ.
  Lösung: Abo-, Feed-, Global-, aktuell ausgewähltes Modell und dessen
  anbieterspezifische Zugangsvoraussetzungen werden vor jedem automatischen Kandidaten
  und ein zweites Mal unmittelbar vor dem semantischen Request aus der aktuellen
  Laufzeitkonfiguration gelesen. Abgewählte Jobs werden entfernt und ein vorhandener
  OpenAI-Background-Auftrag zur Stornierung markiert. Ist das ausgewählte Modell nicht
  bereit, wird genau dieser Grund ausgewiesen; die Queue wechselt nicht stillschweigend
  zu OpenAI oder einem anderen Anbieter. OpenAI API, Codex OAuth, Anthropic, Kimi,
  Apple Foundation Models und das lokale GGUF-Modell bleiben in der Modellauswahl
  erhalten; die unten beschriebene revisionsgebundene Vollanalyse setzt weiterhin ein
  Remote-Modell voraus.
- Die Episoden werden in einem Datenbankdurchlauf nach Hash aufgelöst, statt bei großen
  Feed-Aktualisierungen pro Episode alle Feeds erneut zu durchsuchen.
- Automatischer Ursprung, Analyseabsicht, Retry-Zähler und nächster Retry-Termin werden
  zusammen mit dem Job persistiert.
- Verwaiste `_checkpoint.json`-Dateien werden nur für weiterhin abonnierte und für
  automatische Verarbeitung konfigurierte Podcasts wieder in die Queue aufgenommen.
- Vorübergehende Netzwerk-, HTTP- und Systemunterbrechungen bleiben queued. Der Retry ist
  exponentiell, persistent und auf sechs Stunden Abstand begrenzt; der vorhandene
  Transkriptionscheckpoint bleibt erhalten.
- Solange der Prozess lebt, weckt ein abbrechbarer `retryWakeTask` die Queue zum
  frühesten persistierten Retry-Termin. Zusätzlich beantragt die App einen passenden
  `BGProcessingTask`; dessen tatsächlichen Startzeitpunkt bestimmt iOS.
- Nach einem unerwarteten Prozessende wird ausschließlich die Episode unter dem
  gesetzten Crash-Guard klassifiziert. Automatische Jobs und persistierte
  Remote-Analysen erhalten einen Wiederholungsversuch; nur ein nicht sicher
  fortsetzbarer manueller Job wird für expliziten Retry quarantänisiert. Andere
  automatisch eingeplante Episoden laufen in beiden Fällen weiter.
- Ein bereits fertiges Podcast-Transkript kann direkt in die Analysephase einsteigen.
- Problem: Der Abruf öffentlicher Podcast-Transkripte war mit eigener DNS-Auflösung,
  IP-Filterung, `NWConnection`, TLS-Pinning und einem eigenen HTTP-Parser unnötig
  verkompliziert worden. Grund: Für diese öffentlichen Texte gibt es keine
  projektspezifische Anforderung an einen separaten Netzwerksicherheits- oder
  Pinning-Vertrag; der Sonderpfad erhöhte stattdessen Fehlerfläche und
  Kompatibilitätsrisiko. Lösung: Öffentliche `http`- und `https`-Transkripte werden
  wieder normal mit `URLSession.shared.data(for:)` geladen. Redirects,
  Zertifikatsprüfung und Inhaltskodierung folgen den Systemregeln. Feed-Zugangsdaten
  werden nur an denselben Origin angehängt. Nicht erfolgreiche HTTP-Statuswerte,
  leere Antworten und Inhalte über 16 MiB werden weiterhin explizit abgewiesen; das
  Request-Timeout beträgt 30 Sekunden. Es gibt keine eigene DNS-Auflösung und kein
  DNS-, IP- oder Zertifikat-Pinning mehr.
- Der so geladene Inhalt wird nur mit strikt monotonen expliziten Cue-Zeiten
  importiert. Ohne Zeiten, überlappend oder fehlerhaft bedeutet nicht „Zeiten
  erfinden“: Ist automatische Transkription konfiguriert, durchläuft die Episode
  regulär die Audio-Transkription; Transportfehler bleiben im persistenten Retry.
- Problem: Eine ältere `_analysis.json` konnte nach einem neuen SRT weiter als gültig
  erscheinen. Grund: Cache-Existenz wurde ohne Abgleich gegen die aktuelle
  Transkript-Revision akzeptiert. Lösung: Jeder SRT-Commit invalidiert Analyse-Caches;
  Laden, Queue-Restore und Provider-Finalisierung vergleichen den gespeicherten
  SHA-256-Revisionswert mit dem kanonischen Millisekunden-SRT. Ein absichtlich
  gelöschtes SRT lässt eine bereits fertige Analyse lesbar, ein neu geschriebenes SRT
  macht sie dagegen zwingend neu zu erzeugen.

### Kanonische Whisper-Zeitachse

- Problem: Lange WhisperKit-Läufe teilen Audio in 30-Minuten-Slices und laden pro
  Folgeslice fünf Sekunden Kontext erneut. Dadurch konnten an einer Slice-Grenze
  beispielsweise Cues `1798,0–1800,0` und `1799,6–1802,0` entstehen. Das SRT enthielt
  anschließend beide überlappend; der bewusst strikte Analyse-Loader verwarf deshalb
  das gesamte Transkript.
- Grund: Die Slice-Erkennung darf einen grenzüberschreitenden Cue aus dem erneut
  geladenen Kontext behalten, damit dessen Text nicht verloren geht. Das abschließende
  Postprocessing setzte jedoch voraus, dass WhisperKit bereits eine monotone Zeitachse
  liefert, und normalisierte diese reale Slice-Überlappung vor der SRT-Persistenz nicht.
- Lösung: Vor Fragment-Merge und SRT-Schreibvorgang werden gültige Cues stabil nach
  ihren echten Grenzen sortiert. Ein teilweise überlappender Folgecue beginnt exakt am
  bekannten Ende des vorherigen Cues; seine echte Endgrenze und sein vollständiger Text
  bleiben erhalten. Identische Überlappungsduplikate werden einmalig vereinigt;
  vollständig überdeckter, aber unterschiedlicher Text wird dem belegenden Cue
  angefügt. Ungültige Grenzen werden verworfen statt durch erfundene Zeiten ersetzt.
  Die Diagnose `Transcript cue timeline normalized` protokolliert die Anzahlen für
  gekappte, vereinigte und ungültige Cues. Der strikte Analyse-Loader bleibt unverändert.
- Problem: Der Live-Checkpoint konnte während eines langen Laufs ein Swift-Array lesen,
  während der nächste Whisper-Callback dasselbe Array erweiterte. Grund: Cue-Akkumulator
  und Checkpoint-Fortschritt waren als `nonisolated(unsafe)` markiert; der Callback und
  die Main-Queue besaßen keinen gemeinsamen Synchronisationsvertrag. Lösung: Ein
  eigener lock-geschützter Akkumulator fügt Cue und Fortschritt atomar hinzu und gibt
  nur einen unveränderlichen Array-Snapshot an den Main-Actor-Schreibpfad weiter.
- Problem: Ein atomarer Checkpoint-Schreibfehler wurde zwar geloggt, aber dem
  Lifecycle-Handoff trotzdem als Erfolg gemeldet; die Queue konnte den aktiven Lauf
  danach abbrechen und den nur im Speicher vorhandenen Fortschritt verlieren. Lösung:
  Der Schreibpfad liefert jetzt seinen echten Erfolg bis an die Queue zurück. Eine
  Hintergrundpause oder ein Rechenprofilwechsel darf die laufende Transkription erst
  nach einem erfolgreichen letzten Checkpoint abbrechen; bei einem Schreibfehler
  bleibt sie aktiv und der Status nennt den belegten Persistenzfehler.

### Persistenter WhisperKit-Modellcache

- Problem: Ein App-Neustart konnte wie eine erneute mehrminütige Modellkompilierung
  wirken. Grund: Core ML bindet seinen purgebaren Spezialisierungs-Cache an Pfad und
  Metadaten der kompilierten Modelle; verschobene oder bei jedem Lesen rekursiv neu
  attributierte Dateien invalidieren diesen Cache. Außerdem bezeichnete der alte
  Status auch einen normalen Prewarm-/Load-Vorgang pauschal als Kompilierung.
- Lösung: Die drei benötigten kompilierten Bundles `MelSpectrogram.mlmodelc`,
  `AudioEncoder.mlmodelc` und `TextDecoder.mlmodelc` liegen dauerhaft unter
  Application Support. Ein reiner Verfügbarkeitscheck ändert ihre Attribute nicht;
  Datei-Schutz und Backup-Ausschluss werden nur geschrieben, wenn ihr Wert tatsächlich
  abweicht. Die App prüft zusätzlich, dass die kompilierten Payloads vorhanden,
  nichtleer, lesbar und per `mmap` zugreifbar sind.
- Beim ersten Download bereitet WhisperKit das Modell zunächst ohne automatisches
  Prewarm/Load vor. Danach setzt die App die stabilen Verzeichnisattribute, führt
  `prewarmModels()` aus, validiert alle kompilierten Bundles und entfernt erst dann
  vorhandene `.mlpackage`-/`.mlmodel`-Quellen. Ein normaler Neustart öffnet dagegen die
  vorhandenen `.mlmodelc`, führt den Core-ML-Prewarm beziehungsweise Cache-Check aus und
  lädt sie; er kompiliert nicht jedes Mal erneut aus den Quelldateien.
- Bei der einmaligen Migration aus dem früheren Documents-Pfad wird eine alte
  Modellkopie nur noch gelöscht, wenn das Ziel alle drei kompilierten Bundles bereits
  vollständig validiert. Ist das Ziel unvollständig, ersetzt ausschließlich eine
  zuvor validierte Quellkopie dieses Ziel; ein partieller Zielordner kann den gültigen
  Alt-Cache nicht mehr vernichten.
- `prewarm` ist nicht gleichbedeutend mit einer Neukompilierung. Nur eine entsprechende
  WhisperKit/Core-ML-Meldung wird als „wird kompiliert“ angezeigt. Die DebugLogs
  protokollieren die unveränderten `.mlmodelc`-Änderungszeiten und getrennt
  `prewarmSeconds`, reine `modelLoadSeconds`, Gesamtvorbereitung sowie Encoder-/Decoder-
  Lade- und Spezialisierungszeiten. Da iOS den systemeigenen Core-ML-Cache purgen kann
  und ein Rechenprofilwechsel eine neue Spezialisierung verlangen kann, wäre „nie
  wieder Spezialisierung“ keine belastbare Garantie; ein gewöhnlicher App-Neustart
  verwendet jedoch die persistierten kompilierten Modelle statt sie erneut zu bauen.

### Echter iOS-26-Hintergrundpfad

- Automatische Jobs verwenden `BGProcessingTaskRequest` und werden nur geplant, wenn
  tatsächlich automatische Queue-Arbeit existiert.
- Das erfolgreiche Absenden eines Requests ist noch keine Rechenzeitfreigabe. Erst
  wenn der jeweilige App-Delegate-Handler den Systemtask tatsächlich erhält, setzt die
  Queue einen prozesslokalen Grant. Persistierte Request-/Diagnosewerte werden nicht
  als Grant interpretiert und nach einem Neustart nicht wiederverwendet.
- Der vom Benutzer ausgelöste Button verwendet auf iOS 26
  `BGContinuedProcessingTaskRequest`: Er beantragt `continued-gpu`, wenn das System die
  Ressource meldet, sonst `continued-cpu` ohne GPU-Anforderung. Auch dieser sichtbare
  Lauf kann vom System beendet werden.
- Sobald die App im Hintergrund ist und kein echter Systemgrant aktiv ist, startet
  beziehungsweise führt die Queue weder Transkription noch semantische Analyse fort.
  Das gilt ausdrücklich auch für Chapter-only-Jobs mit bereits vorhandenem
  Transkript; sie bleiben persistent queued.
- Das gewählte Ausführungsprofil wird vor dem WhisperKit-Modellload festgelegt.
  `legacy-processing` (`BGProcessingTask`) und `continued-cpu` verwenden für
  Mel-Spektrogramm, Audio-Encoder und Text-Decoder CPU/Neural Engine. GPU wird nur im
  Vordergrund oder mit tatsächlich aktivem `continued-gpu`-Grant genutzt. Es gibt
  keinen Fehler-Fallback und keinen automatischen Wechsel auf ein kleineres Modell
  oder eine andere Engine.
- Ein bereits mit dem falschen Profil geladenes Core-ML-Modell wird kontrolliert
  freigegeben und mit dem gewünschten Profil neu geladen. Der Wechsel wird als
  `compute-profile-changed` diagnostiziert.
- Problem: Schon ein kurzer Wechsel in eine andere App wurde als Fehler behandelt,
  setzte sichtbaren Fortschritt zurück und plante einen 30-Sekunden-Retry. Außerdem
  konnte der periodisch persistierte Checkpoint bis zu einem Prozent hinter dem
  letzten bereits erkannten Cue liegen. Grund: Eine erwartete Lifecycle-Pause teilte
  denselben Fehlerpfad wie ein echter Transkriptionsfehler, und die Queue hatte beim
  Abbruch keinen synchronen Snapshot des aktuellen Cue-Akkumulators. Lösung: Vor der
  kontrollierten Unterbrechung wird der letzte vollständig erkannte Cue atomar in den
  Checkpoint geschrieben. Der Job bleibt mit seinem Fortschritt sofort queued und
  wird ohne künstliche Retry-Verzögerung im Vordergrund oder bei einem echten
  Systemgrant fortgesetzt. Höchstens das gerade noch unvollständige Sprachsegment
  wird erneut erkannt; die Episode startet nicht von vorn.
- Expiration beendet den aktiven Lauf kontrolliert, persistiert den Retry und lässt den
  Checkpoint unangetastet.
- Problem: Ein ausstehender sichtbarer Continued-Request und ein automatischer
  Processing-Request konnten einander übernehmen oder nach Cold-Launch-Expiration
  beziehungsweise Datenbankfehler als veralteter Besitzer stehen bleiben. Grund:
  Request-Submission wurde wie Task-Zuständigkeit behandelt und alte Requests wurden
  vor erfolgreichem Ersatz gelöscht. Lösung: Ein alter Processing-Request bleibt bis
  zur erfolgreichen Continued-Submission bestehen; erst dann wird er storniert. Die
  Handler sind gegenseitig exklusiv. Jeder frühe Continued-Abbruch räumt Pfad- und
  Request-Key und plant die weiterhin nötige automatische Arbeit neu.
- Problem: iOS konnte einen Systemtask als erfolgreich beendet sehen, obwohl der letzte
  atomare Queue-Snapshot noch lief oder mit Disk-/Protection-Fehler gescheitert war.
  Grund: Quiescence zählte nur aktive Rechenarbeit. Lösung: Processing und Continued
  warten auf alle Queue-Schreibcallbacks und aktive Cancel-/GET-Reconciliation. Ein
  fehlgeschlagener Snapshot wird einmal unmittelbar mit dem aktuellen In-Memory-Stand
  wiederholt; bleibt der belegte Fehler bestehen, erhält iOS `success=false` und die
  Queue bewahrt den Fehler bis zu einem später erfolgreichen Snapshot.
- iPhone- und iPad-Plists enthalten den Processing-Mode und beide erlaubten Task-IDs.

Ein `UIApplication`-Background-Task, eine Background-URLSession oder ein Entitlement
garantiert auf iOS keine unbegrenzte Rechenzeit. `BGProcessingTask` bleibt eine
opportunistische Systementscheidung; `BGContinuedProcessingTask` muss durch eine
sichtbare Benutzeraktion gestartet werden und kann ebenfalls beendet werden. Eine
harte 24/7-Garantie wäre nur mit einer persistenten Server-Queue möglich. Die lokale
Lösung erreicht Unterbrechungsfestigkeit deshalb durch Checkpoints, persistente
Queue-Zustände und Wiederaufnahme statt durch eine nicht existierende
iOS-Dauerlaufgarantie.

Die aktuell verfügbare Toolchain deckt iOS 26.5/26.6 ab. Ein iOS-27-SDK und damit
prüfbare iOS-27-Background-APIs stehen lokal noch nicht zur Verfügung; dafür wurden
keine erfundenen Stub- oder Kompatibilitätspfade eingebaut.

### Provider-Auswahl und gemeinsame Volltranskript-Analyse

- Pro Episode gibt es einen gemeinsamen semantischen Auftrag; die alte separate
  Kapitel- und Sponsor-Runde entfällt. Bei Remote-Modellen liefert derselbe Auftrag
  Kapitel, Sponsorgrenzen und Zusammenfassung aus dem vollständigen Transkript.
- Die gespeicherte Benutzerauswahl entscheidet über den Anbieter. OpenAI API, OpenAI
  Codex OAuth, Anthropic und Kimi verwenden den gemeinsamen strukturierten
  Volltranskript-Vertrag. Apple Foundation Models und das lokale GGUF-Modell bleiben
  als Kapitel-only-Pfade verfügbar; sie werden nicht stillschweigend anstelle eines
  ausgewählten Remote-Modells verwendet.
- Ist das OpenAI-API-Modell ausgewählt, wird eine Response mit `background=true` und
  `store=true` gestartet. Die Response-ID wird zusammen mit Episode,
  Transkript-Revision, Modell und Schema lokal persistiert. Nach App-Unterbrechung
  pollt die Queue dieselbe Response weiter, sobald diese ID empfangen und atomar
  gespeichert wurde, statt die kostenpflichtige Vollanalyse erneut abzusenden.
  Schon vor dem POST persistiert die App einen `submitting`-Zustand. Falls der POST
  möglicherweise angenommen wurde, seine Response-ID aber nicht zurückkommt, sendet
  sie deshalb keinen zweiten kostenpflichtigen Auftrag. Auch ein expliziter Queue-
  Retry löscht diesen uneindeutigen Zustand nicht: Ohne Response-ID lässt sich weder
  exakt pollen noch sicher stornieren. OpenAI dokumentiert für das Erzeugen keine
  Idempotency- oder Suche-nach-Metadaten-Garantie; dieses schmale Fenster kann die
  direkte Geräteintegration daher nicht wahrheitsgemäß vollautomatisch und
  exakt-einmal auflösen. Dafür ist ein serverseitiger Broker mit providerseitiger
  Idempotenz/Reconciliation erforderlich.
- Als serverlose Alternative wurde die offizielle Batch API geprüft: Batch-Objekte
  sind über eine Liste und eigene Metadata wieder auffindbar, unterstützen auch
  `/v1/responses`, haben derzeit aber ausschließlich ein `24h`-Completion-Window und
  benötigen zusätzlich einen verwalteten Input-Datei-Lebenszyklus. Dieser erhebliche
  Latenzwechsel wird nicht stillschweigend als Ersatz für die schnelle Background
  Response eingebaut; er ist eine noch offene Produktentscheidung, falls kein Broker
  verfügbar ist.
- Ein ausdrücklich abgelehnter Create mit HTTP 429 besitzt keine Response-ID und darf
  nach dem persistierten Backoff ersetzt werden. 408, 409, 425 und 5xx bleiben dagegen
  konservativ `submitting`, weil ohne dokumentierten Side-Effect-Vertrag ein
  automatischer Doppel-POST nicht sicher wäre. Abgeschlossene Providerantworten mit
  gültiger Response-ID, einschließlich lokal wegen JSON-, Revisions-, Evidenz- oder
  Sponsorvalidierung verworfener Antworten, dürfen innerhalb eines persistenten
  Kostenbudgets höchstens zweimal ersetzt werden. Job-Key und Response-ID verhindern,
  dass ein Prozessende vor Manifest-Retirement dieselbe Antwort doppelt zählt.
- `store=true` bedeutet gemäß OpenAI-Datenkontrollen mindestens 30 Tage Responses-
  Application-State-Aufbewahrung; Background Mode schreibt zusätzlich temporäre Daten
  für die asynchrone Ausführung. Diese Datenwirkung gehört zur bewussten Modell- und
  Datenschutzentscheidung.
- Problem: Ein dauerhaft vorgemerkter Provider-Abbruch blieb liegen, wenn OpenAI den
  `POST /cancel` wegen einer inzwischen abgeschlossenen Response ablehnte. Grund: Die
  App deutete jede Cancel-Ablehnung nur als Fehler und versuchte die Abstimmung genau
  einmal beim Singleton-Start; ein leerer `BGProcessingTask` konnte zudem enden,
  während der asynchrone Cancel noch lief. Lösung: Nach einer Cancel-Ablehnung ruft
  die App ausschließlich die validierte exakte Response-ID per `GET /responses/{id}`
  ab. Nur ein `404` dieses exakten Endpunkts oder ein terminales Ergebnis mit exakt
  passender Response-ID und `instacast_job_key` entfernt den Tombstone. `queued` und
  `in_progress`, Identitätsabweichungen sowie Netzwerkfehler behalten ihn. Versuch und
  nächster Retry-Termin werden atomar im Manifest gespeichert, im laufenden Prozess
  wieder aufgenommen und zusätzlich über den bestehenden netzgebundenen
  `BGProcessingTask` geplant. Der Systemtask wartet auf den aktiven Cancel-/GET-Lauf,
  bevor er seinen Grant freigibt. Die DebugLogs enthalten Job-Key, Response-ID,
  Providerstatus, Retry-Versuch und den Grund jeder Abstimmung.
- Jede Cue bekommt eine stabile ID (`cue-N`). Ein SHA-256-Hash bindet Ausgabe,
  Sponsorbelege und Summary an die exakte Transkript-Revision.
- Das Schema verlangt Kapitelstarts, Sponsor-Start/-Ende, konkrete Evidence-Cue-IDs und
  eine Zusammenfassung. Unbekannte Felder sind nicht erlaubt.
- Die App verwirft falsche Revisionen, unbekannte oder unsortierte Cue-IDs,
  überlappende Sponsorsegmente, ungültige Zeitachsen und leere Zusammenfassungen,
  bevor ein Sponsor automatisch übersprungen werden kann. Start und Ende müssen exakt
  auf den Grenzen der ersten beziehungsweise letzten Evidence-Cue liegen; die
  Evidence-Liste muss jede Cue dazwischen genau einmal und lückenlos enthalten.
- Reine Musik, Intro, Outro, Jingle und redaktionelle Erwähnungen ohne Werbeaufruf sind
  explizite Nicht-Sponsor-Fälle. False Positives haben im Prompt Priorität.
- Ohne Publisher-Kapitel erzeugt das Modell belegte Themenstarts und konkrete Titel.
- Mit Publisher-Kapiteln muss die Modell-Kapitelliste leer bleiben. Die App löscht
  diese Core-Data-Kapitel nicht, übernimmt ihre Titel und Grenzen als Basis und legt
  ausschließlich validierte Sponsorintervalle darüber. Das Overlay darf ein
  Publisher-Intervall an Sponsorgrenzen teilen, behält aber dessen Titel für die
  verbleibenden Inhaltsstücke und verschiebt keine Publisher-Grenze.
- Problem: Eingebettete Medien-Kapitel einer noch nie abgespielten Folge waren noch
  nicht als `CDChapter` materialisiert; die automatische Queue hielt die Folge deshalb
  fälschlich für kapitellos. Grund: Nur Playback startete den gemeinsamen
  `ICMetadataParser`. Zusätzlich konnte dessen M4A-Pfad bei einer leeren
  Timed-Metadata-Locale ohne Completion hängen, und der Postflight-Index wurde nach
  einem Kapitel mit explizitem Ende nicht erhöht. Lösung: Vor dem Remote-Auftrag bleibt
  ein vorhandener `CDChapter`-Snapshot autoritativ; andernfalls liest die Queue die
  rohen eingebetteten Kapitel mit demselben Parser, validiert Titel/Start/Ende, behebt
  die beiden Parser-Lifecycle-Fehler und speichert ausschließlich diese Publisher-
  Metadaten inklusive expliziter Dauer und Link als `CDChapter`. Erst danach wird das
  Sponsor-Overlay erzeugt. Generierte Kapitel gelangen nie in diese Publisher-
  Persistenz.
- Problem: Ein noch laufender Medien-Metadatenparser für Episode A konnte nach einem
  schnellen Playback-Wechsel seine Kapitel in den Zustand von Episode B schreiben.
  Grund: Der asynchrone Callback hatte zwar den Hash von A erfasst, verglich ihn vor
  KVO, Artwork- und Kapitel-Commit aber nicht erneut mit der aktiven Episode. Lösung:
  Der Callback darf Publisher-Metadaten nur veröffentlichen, wenn der nichtleere,
  beim Start erfasste Episoden-Hash weiterhin exakt zur spielenden Episode gehört.
- Publisher-Links bleiben nur auf Inhaltsfragmenten erhalten, die vollständig im
  ursprünglichen Publisher-Intervall liegen. Sponsorfragmente, neutrale Lücken und
  KI-erzeugte Kapitel erben keinen fremden Link. Explizite Publisher-Enden bleiben
  autoritativ; Vorlauf-, Zwischen- und Postroll-Lücken werden bis zur echten
  Mediendauer abgebildet, ohne die Zeitachse auf das letzte gesprochene Cue zu kürzen.
- Kapitel-/Sponsor-Overlay, Sponsorbelege, Transkript-Revision und Summary werden erst
  nach vollständiger Validierung gemeinsam als eine atomar ersetzte
  `<episodeHash>_analysis.json` gespeichert. Playback und Summary-UI sehen dadurch
  niemals nur einen teilweise geschriebenen Stand. Publisher-Show-Notes und
  Publisher-Kapitel bleiben unverändert.
- Ein validiertes Sponsorsegment trägt intern `isSponsor=true` und zwingend einen
  nichtleeren Titel mit dem exakten Präfix `Sponsor: `. Dieses interne Feld dient der
  Analysevalidierung und dem korrekten Zusammenführen; es ist keine zweite
  Sponsorenerkennung im Player.
- Auf iPhone und iPad ist dieses Overlay zugleich die normale Kapitelquelle des
  Players: Publisher-Inhaltskapitel und dazwischen eingesetzte Sponsor-Kapitel stehen
  gemeinsam in derselben Kapitelliste. Die Publisher-`CDChapter` werden dabei nicht
  verändert; die zusammengeführte Playback-Timeline ist ein revisionsgebundenes,
  persistiertes Analyseartefakt. Der Watch-Transfer liefert derzeit weiterhin nur
  Medien-/Publisher-Kapitel und erhält das KI-Sponsor-Overlay noch nicht.
- Ist der vorhandene Sponsor-Skip-Schalter global oder für den Podcast aktiv, hängt
  Playback lediglich das exakte Keyword `Sponsor: ` an die bereits vorhandene
  Kapitel-Skip-Liste an. Danach laufen Sponsor-Kapitel durch denselben
  case-insensitiven Titel-Matcher, dieselben Start-/End-Offsets, dieselbe Gruppierung
  und denselben Seek-Pfad wie alle anderen Skip-Keywords. Auch die Markierung in der
  Kapitelliste verwendet diesen gemeinsamen Matcher; es gibt keinen zusätzlichen
  Player-Klassifikator. Die Watch verwendet für ihre vorhandenen Kapitel denselben
  Keyword-Vertrag.

## Modellbewertung

Alle Preise sind Listenpreise am 18. Juli 2026 pro eine Million Tokens. Anbieterpreise
können sich ändern.

| Modell | Kontext / max. Ausgabe | Input / Output | Bewertung für diese Pipeline |
|---|---:|---:|---|
| OpenAI GPT-5.6 Terra (offizielle API) | 1,05 M / 128 K | USD 2,50 / 15 | Wenn vom Benutzer ausgewählt: Structured Outputs plus offizielle Background Responses, deren persistierte Response-ID nach Unterbrechungen weiter gepollt wird. Erfordert API-Key und `store=true` mit mindestens 30 Tagen Response-Aufbewahrung. Produktfreigabe bleibt bis zum Live-Goldlauf und zur Lösung des mehrdeutigen Create-Fensters blockiert; die Bewertung beruht auf dem Wiederaufnahmevertrag, nicht auf einer unbelegten Qualitätsbehauptung. |
| OpenAI GPT-5.6 Sol (Codex OAuth) | 1,05 M / 128 K | USD 5 / 30 | Weiterhin auswählbarer Anbieterpfad; höherer Preis. Der private Codex-Pfad verspricht keine gleichwertige, offiziell dokumentierte Background-Response-Wiederaufnahme. |
| Anthropic Claude Sonnet 5 | 1 M / 128 K | bis 31.08.2026 USD 2 / 10, danach USD 3 / 15 | Weiterhin auswählbarer Anbieterpfad mit Structured Output. Der derzeitige direkte Request-Pfad bietet in dieser App keine äquivalente persistierte Provider-Job-ID. |
| Moonshot Kimi K3 | 1.048.576 / anbieterabhängig | Cache-Miss USD 3 / 15 | Weiterhin auswählbarer Pfad mit Strict JSON-Schema; Thinking bleibt modellgemäß aktiv. Der direkte K3-Pfad bietet keine äquivalente persistierte Provider-Job-ID; die unten dokumentierte Qualitätsevidenz stammt aus genau einer Episode. |

Problem: Der absichtlich integrierte Kimi-Zugang war zwischenzeitlich aus Build-Phase,
Bundle und Runtime entfernt worden. Grund: Die bewusste Produktentscheidung wurde ohne
Rückfrage als versehentlich veröffentlichtes Secret umgedeutet. Lösung: Das vorhandene
Build-Script erzeugt wieder die Bundle-Ressource `KimiBuiltin.env`, und der
Credential-Store verwendet diesen integrierten Zugang, sofern der Benutzer keinen
eigenen Kimi-Key im Keychain hinterlegt hat. Ein eigener Key hat immer Vorrang; Backup
und Restore übertragen nur den vom Benutzer hinterlegten Key, nicht den integrierten
Zugang. Kein Modellanbieter wird dadurch zum Standard: Maßgeblich bleibt das vom
Benutzer ausgewählte Kapitelmodell.

Live-Vergleich auf der bereits zuvor an Kimi übertragenen 138-Cue-Testepisode:

- Kimi K3 lieferte 0 Sponsorsegmente, zehn sinnvolle Cue-basierte Kapitel und eine
  inhaltlich brauchbare Zusammenfassung; das reine Musik-Outro wurde korrekt nicht als
  Sponsor markiert.
- Latenz: 103,689 s.
- Nutzung: 7.306 Input- und 3.375 Output-Tokens, davon 2.361 Reasoning-Tokens.
- Geschätzte Cache-Miss-Kosten: USD 0,07254.

Das ist ein einzelner Regressionsbeleg für den beobachteten Fehler, aber weder ein
allgemeiner Qualitäts- noch ein Zuverlässigkeitsnachweis. Ein Modell darf erst nach
einem vollständigen Lauf über den vorhandenen Goldstandard
(`Tools/chapter_gold_standard.json`) zum unveränderlichen Produktstandard erklärt
werden. Haupt-Gate ist Sponsorpräzision; ein False Positive führt sonst zu einem
falschen automatischen Sprung. `Tools/evaluate_chapter_gold_standard.py` misst
zeitgewichtete Sponsorpräzision/-recall, Boundary-F1 und einen Token-F1 der
generierten Kapiteltitel gegen die zeitlich zugeordneten Goldtitel. Letzterer ist ein
reproduzierbares Relevanz-Gate gegen beliebige Titel wie `foo`, aber kein Ersatz für
eine menschliche semantische Bewertung. Der Evaluator prüft die
generierte Timeline unabhängig von den vom Benchmark gemeldeten Fehlern erneut:
nicht leere Kapitel, endliche numerische und streng monotone Grenzen, vollständige
Abdeckung ohne Lücken oder Überlappungen, positive Dauer, Grenzen innerhalb der
Episodendauer, aussagekräftige statt generischer Titel sowie gültige
Sponsorintervalle. Ein struktureller Fehler lässt das Gate immer fehlschlagen.

Es gibt absichtlich keine eingebauten Freigabewerte. Jeder Goldlauf muss die vier
Akzeptanzschwellen explizit angeben; eine Unterschreitung beendet den Prozess mit
einem Fehlerstatus:

```bash
python3 Tools/evaluate_chapter_gold_standard.py \
  --summary MODEL /path/to/summary.json \
  --min-promo-precision "$RELEASE_MIN_PROMO_PRECISION" \
  --min-promo-recall "$RELEASE_MIN_PROMO_RECALL" \
  --min-boundary-f1 "$RELEASE_MIN_BOUNDARY_F1" \
  --min-title-token-f1 "$RELEASE_MIN_TITLE_TOKEN_F1"
```

Damit ist nur das Offline-Gate ausführbar. Der ausstehende echte Anbieter-Goldlauf
braucht weiterhin repräsentative vollständige SRTs/Transkripte, die zu den
Gold-Episoden gehören, sowie gültige OpenAI-, Anthropic- beziehungsweise
Moonshot-Zugangsdaten, um vergleichbare Summary-Dateien zu erzeugen. Diese Inputs
liegen im Repository nicht vor; deshalb wird aus dem einzelnen Kimi-Lauf weiterhin
keine Modellfreigabe abgeleitet.

Als echte, nicht eingecheckte Referenz wurde „The Talk Show“ #450 verwendet. Der
Live-Test liest den offiziellen RSS-Eintrag, genau den führenden ID3-Bereich der
MP3-Datei und das öffentlich erreichbare zeitmarkierte PodSearch-Transkript nur im
Speicher. Der aktuelle Referenzstand enthält 2.585 nichtleere Cues über 99,973 % der
9.885,622 Sekunden sowie elf lückenlose ID3-Kapitel. Die drei Publisher-Sponsor-
Kapitel `Factor`, `Squarespace` und `Finalist` umfassen zusammen 466 Sekunden. Damit
sind Transcript-, Laufzeit-, Kapitel- und Sponsor-Ground-Truth reproduzierbar belegt,
ohne fremdes Audio oder Transkript zu versionieren. Das ist noch kein bestandener
OpenAI-Qualitätslauf: Dafür muss ein gültiger OpenAI-Key lokal eingerichtet sein und
die erzeugte Analyse anschließend gegen diese Referenz ausgewertet werden.

„Bits und so“ wurde ebenfalls geprüft. Der Feed stellt aktuell weder Podcasting-2.0-
Transkript- noch Kapitel-URLs bereit; Kapitel liegen im MP3, die verlinkten
Transkriptseiten beantworten direkte Testclients mit einer Cloudflare-Challenge.
Deshalb ist die Talk-Show-Episode die deterministisch ausführbare Live-Referenz.

OpenAIs Audio-Transkriptionsmodelle wurden nicht als Geräte-ASR gewählt: Die API nimmt
pro Upload höchstens 25 MB an, unterstützt für Audio keine Batch-/Background-Anfrage
und würde für lange Podcasts Audio-Upload plus serverseitige Chunk-Orchestrierung
erfordern. Die DebugLogs zeigen außerdem, dass WhisperKit im erfolgreichen Lauf schnell
war; die reale Ursache war das unzulässige GPU-Ausführungsprofil.

## Regressionen und Diagnose

Kritische Quellpfade sind durch folgende fokussierte Checks festgepinnt:

```bash
python3 Tools/chapter_gold_standard_evaluator_regression_test.py
python3 Tools/transcription_analysis_visibility_regression_test.py
python3 Tools/transcription_automatic_intent_revalidation_regression_test.py
python3 Tools/transcription_automatic_model_contract_regression_test.py
python3 Tools/transcription_automatic_pipeline_regression_test.py
python3 Tools/transcription_background_compute_regression_test.py
python3 Tools/transcription_background_grant_retry_regression_test.py
python3 Tools/transcription_background_persistence_quiescence_regression_test.py
python3 Tools/transcription_background_request_ownership_regression_test.py
python3 Tools/transcription_background_regression_test.py
python3 Tools/transcription_checkpoint_synchronization_regression_test.py
python3 Tools/transcription_discovery_regression_test.py
python3 Tools/transcription_discovery_outbox_regression_test.py
python3 Tools/transcription_embedded_chapters_analysis_regression_test.py
python3 Tools/transcription_existing_chapters_analysis_regression_test.py
python3 Tools/transcription_external_transcript_regression_test.py
python3 Tools/transcription_remote_analysis_regression_test.py
python3 Tools/transcription_remote_cancellation_regression_test.py
python3 Tools/transcription_remote_create_rejection_regression_test.py
python3 Tools/transcription_remote_rejected_replacement_regression_test.py
python3 Tools/transcription_remote_replacement_budget_regression_test.py
python3 Tools/transcription_remote_resume_regression_test.py
python3 Tools/transcription_revision_canonicalization_regression_test.py
python3 Tools/transcription_stale_analysis_regression_test.py
python3 Tools/transcription_status_regression_test.py
python3 Tools/transcription_whisper_overlap_normalization_regression_test.py
python3 Tools/kimi_chapter_integration_regression_test.py
python3 Tools/model_library_settings_regression_test.py
python3 Tools/playback_sponsor_keyword_reuse_regression_test.py
python3 Tools/whisper_model_prewarm_regression_test.py
python3 Tools/core_spotlight_podcast_episode_regression_test.py
RUN_LIVE_PODCAST_REFERENCE_TEST=1 \
  python3 Tools/live_podcast_reference_integration_test.py
```

Zusätzlich deckt `for test in Tools/transcription_*_regression_test.py; do python3
"$test" || exit; done` die älteren benachbarten Transkriptionsregressionen ab.

Die Episodendiagnose protokolliert SRT, Checkpoint, Musik-Timeline, lokale
Kapiteldatei, atomare Episodenanalyse, OpenAI-Auftragsdatei, Episodenlog und
Kapitel-Debugartefakt jeweils mit Existenz, Größe und Änderungszeit. Modelltexte
werden nicht in dieses Architekturprotokoll kopiert.

Die Queue-Ansicht unterscheidet jetzt einen lediglich angeforderten Continued-Lauf
von einem tatsächlich durch iOS aktivierten Background-Grant. Sie zeigt automatische
Retry-Zeitpunkte, den aktuellen lokalisierten Verarbeitungsschritt neben dem Prozent-
wert und berechnet die Restzeit nach einer Wiederaufnahme aus dem neuen
Fortschrittsdelta statt aus der Zeit vor der Pause. Erwartete Background-Pausen werden
nicht mehr als Fehler oder global unterbrochene Queue dargestellt.
