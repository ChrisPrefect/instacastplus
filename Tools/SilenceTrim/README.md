# Sprechpausen kürzen (Silence Trim)

## Funktionsweise

`Classes/SilenceTrim/ICSilenceCompressor.swift` verkürzt Pausen, ohne Sprache anzufassen. Das entspricht dem, was Overcast für Smart Speed beschreibt: Stille wird stärker beschleunigt als der Rest (Marco Arment, TechCrunch 2014).

- **Erkennung:**
  - 10-ms-Frames eines mit 100 Hz hochpassgefilterten Mono-Signals.
  - Die Schwelle passt sich lokal an: Perzentile P10 (Grundrauschen) und P90 (Sprechpegel) über 15 s zurück und 5 s voraus.
  - Schwelle = max(Rauschboden + max(6 dB, 25 % des Abstands), Sprechpegel − 38 dB), höchstens Sprechpegel − 20 dB, mit 3 dB Hysterese.
  - Bei weniger als 15 dB Kontrast, etwa unter einem Musikbett, wird nichts gekürzt.
  - Klicks bis 20 ms innerhalb einer Pause unterbrechen sie nicht.
  - Mit „Pausen erkennen: Sprache (Silero)“ (Standard, `PlayerSilenceTrimDetection` = 1) prüft zusätzlich eine Spracherkennung jedes Geräusch zwischen zwei stillen Stellen. Was keine Sprache ist, gehört zur Pause. Details unten unter „Spracherkennung (Silero VAD)“.
- **Kürzen:** Eine einzige WSOLA-Zeitskalierung mit Grains von 11,6 ms und Hann-Fenstern bei 50 % Überlappung.
  - In Sprache und in den Schutzzonen schreitet die Analyse genau um einen Hop weiter. Weil sich die Fenster dort zu genau 1 aufsummieren, kommt die Sprache sample-genau unverändert heraus.
  - In der Pause springt die Analyse um `silenceRate`-mal so viel weiter. Jeder Grain wird per normierter Kreuzkorrelation an die natürliche Fortsetzung des vorherigen angelegt. Dadurch bleiben Raumklang, Brummen und Atem durchgehend, es gibt keinen Schnitt.
- **Schutzzonen:** Nach dem Sprechende bleibt `leadingGuard` in Originalgeschwindigkeit (Nachhall, auslautende Zischlaute), vor dem Einsatz `trailingGuard`. Pausen, die kürzer sind als beide Zonen plus ein Grain, bleiben unverändert. Das schützt die Verschlusspausen innerhalb von Konsonanten.
- **Proportional:** Innerhalb der Schutzzonen wird jede Pause um denselben Faktor kürzer. `maximumPauseDuration` begrenzt, was eine lange Pause behält.

`ICSilenceTrimPlayer.swift` spielt die Datei über `AVSampleBufferAudioRenderer` mit `AVSampleBufferRenderSynchronizer` ab. Das ist der Weg, für den Apple bei eigenen Playern AirPlay-2-Enhanced-Buffering dokumentiert.
- Das Tempo setzt der Synchronizer, mit demselben Time-Pitch-Algorithmus wie `AVPlayerItem`.
- Nach aussen meldet der Player immer die Quellzeit der Datei: Positionen, Kapitel, Skip-Marker, iCloud, Watch und Sperrbildschirm.

### Sample-genaue Neustarts

Gemessen am 20.11.2026 mit der Glitch-Probe:
- **Decoder-Vorlauf:** Nach einem Start mitten in einer MP3 dekodiert AVAssetReader die ersten bis zu 60 ms falsch (bis 2445 Samples). Der Player dekodiert deshalb 0,2 s früher und verwirft diesen Teil.
- **Präzise Positionen:** Ohne `AVURLAssetPreferPreciseDurationAndTimingKey` beginnt der Reader je nach Zustand des Assets bis zu ein MP3-Frame (1152 Samples) neben der verlangten Stelle.
  - Das präzise Asset braucht einen Scan der ganzen Datei, 0,5 bis 2,8 s auf dem M2.
  - Die Wiedergabe startet deshalb sofort, und das präzise Asset wärmt sich im Hintergrund auf.
  - Die Sitzung wechselt in der nächsten gekürzten Pause ohne Flush; ein Frame Versatz ist dort Stille.
- **Primed Restart:** Fortsetzende Neustarts (automatischer Flush, Stufenwechsel, Decoder-Wechsel) beginnen einen Hop früher und verwerfen ihn. Danach ist der Überlapp gefüllt, und das Audio läuft ohne Einblendung und ohne Pegelloch weiter. Nur ein Seek blendet ein.
- **Quellposition eines Neustarts:** Sie ist der letzte Hop-Start vor der Flush-Stelle plus Versatz, also der Grain, der dort einblendet. Die interpolierte Anzeigezeit ist dafür falsch:
  - Im letzten ungekürzten Hop vor einer Pause übersprang sie bis zu mehrere Millisekunden Nachhall.
  - Über die Umrechnung in Sekunden lag sie gelegentlich ein Sample daneben.
  - Gegenprobe mit der alten Interpolation: 2 von 8 Neustarts falsch, mit der Hop-Zuordnung 8 von 8 exakt.
- **Teil-Flush beim Stufenwechsel:** `flush(fromSourceTime:)` verweigert der Renderer lokal immer, weil er die rund 1,5 s schon übernommen hat. Die neue Stufe gilt dann nach dem eingereihten Audio. Bei AirPlay mit langem Puffer schneidet der Wechsel am nächsten Pufferstart in einer Pause.
- **Uhr:** Play, Pause und Tempo setzen die Synchronizer-Rate synchron. Asynchron lief die Position nach `pause()` noch bis zu 3 ms weiter.
- **Flush hinter dem eingereihten Ende:** Liegt die Flush-Zeit hinter dem letzten eingereihten Sample, setzt der Neustart dort fort. Ab der Flush-Zeit fehlten sonst bis zu 417 Samples (Glitch-Probe, Lex mit Silero, 1 von 4 Läufen).

### Streaming (gemessen 21.11.2026)

Gestreamte Folgen laufen über den Stream-Cache der App (`ICStreamingCacheLoader`, „Beim Streamen laden“, Standard an). Er lädt die Datei in Stücken auf das Gerät, die angefragte Stelle zuerst. Behält die App gestreamte Folgen nicht, holt die Engine den Stream selbst (`ICSilenceTrimHTTPSource`).
- **AVAssetReader liest keine HTTP-URL** (AVError −11838). Über einen Resource-Loader liest er dagegen problemlos: Eine 2,5-h-Folge war nach 0,16 s offen, ein Sprung auf 30:00 lud nur rund 1 MB.
- **Ohne Stream-Cache:** `ICSilenceTrimHTTPSource` beantwortet die Anfragen mit HTTP-Range-Anfragen in Stücken von 512 KB, die gewartete Stelle zuerst. Es liest bis 16 MB über die neueste Anfrage voraus. Die Bytes liegen in einer temporären Datei (`tmp/SilenceTrimStream-…`), die beim Schliessen des Players gelöscht wird. Ein Server ohne Range-Unterstützung liefert die ganze Datei einmal von vorn.
- **Jedes Byte einmal** (gemessen 22.11.2026, Deep-E2E T, LNP 564 mit 65,1 MB, Start 20:00, Sprung nach 50:00 und zurück):

  | | gesendet | doppelt | über AVFoundations eigenes HTTP | Kapitel |
  |---|---|---|---|---|
  | Engine, Stream-Cache | 65,34 MB (ganze Datei) | 197 KB | 0 | 16 |
  | AVPlayer, Stream-Cache | 65,34 MB (ganze Datei) | 197 KB | 0 | 16 |
  | Engine, ohne Stream-Cache | 32,90 MB | 131 KB | 0 | 16 |
  | AVPlayer, ohne Stream-Cache | 34,14 MB | 393 KB | alles | 16 |

  „Doppelt“ sind Stücke, die beim Sprung schon unterwegs waren und abgebrochen wurden. Ohne Stream-Cache las der PlaybackManager Kapitel und Artwork zuerst über ein eigenes HTTP-Asset und holte so 655 KB vom Dateianfang ein zweites Mal. Jetzt liest er sie aus der Datei der Engine (`makeMetadataAsset`). Diese Anfragen verschieben das Vorausladen nicht.
- **AVFoundation regelt die Menge selbst:** Mit einer ganzen 140-MB-Datei beliefert, nahm es 12 MB an, brach die Anfrage ab und fragte an der benötigten Stelle neu; der Speicher wuchs um 28 MB. Die eigene Quelle liefert deshalb höchstens 1 MB pro Aufruf.
- **Das präzise Asset scannt die ganze Datei:** über den Stream 140 MB vor dem ersten Sample. Ein Stream startet daher ohne präzise Positionen. Ist der Download fertig, wird die lokale Datei das präzise Asset, und die Engine wechselt in der nächsten stillen Pause darauf, ohne Engine-Wechsel.
- **Eigener Dekodier-Thread:** `copyNextSampleBuffer` wartet auf das Netz. Jede Sitzung dekodiert deshalb auf einer eigenen Queue bis zu 4 s voraus (`DecodeFeed`); die Pipeline-Queue wartet nie.
- **Ein wartender Reader darf nicht abgebrochen werden:** `cancelReading` aus einem anderen Thread stürzte im wartenden `copyNextSampleBuffer` ab (SIGSEGV in `FigSemaphoreWaitRelative`). Der Reader wird nur auf seiner Queue angefasst.
- **Liegen gebliebene Anfragen bremsen den Download:** Der Stream-Cache priorisiert jede wartende Anfrage und bricht den laufenden Download für eine andere Stelle ab. Zwei wartende Anfragen an verschiedenen Stellen starteten den Download deshalb bei jedem Datenpaket neu. Vor jedem Decoder-Start zieht `StreamRequestTracker` die Anfragen des alten zurück (`abandonLoadingRequests:`).
- **Die Uhr wartet nicht auf Daten:** Der Synchronizer lief ohne Audio weiter, auch mit `delaysRateChangeUntilHasSufficientMediaData`: 0,84 s nach `setRate(1)` ganz ohne Daten, später eingereihtes Audio lag in der Vergangenheit. Die Engine hält die Uhr deshalb nach jedem Seek an, bis Audio eingereiht ist. Geht einem Stream das Audio aus, hält sie die Uhr 0,1 s vor dem Ende an und lässt sie bei 1 s Vorrat weiterlaufen.
- **AVFoundation bricht eine Anfrage nach etwa 9 s ohne Daten ab** (NSURLError −1001); der Stream-Cache lädt bis 30 s weiter. Die Engine startet den Decoder dann am Ende des eingereihten Audios neu, höchstens dreimal ohne neue Daten. Erst danach spielt der Stream mit AVPlayer weiter. Ist die Datei später vollständig, nimmt die Engine sie wieder.
- **Fallback:** Gibt die Engine einen Stream auf (Verbindung weg, Stream-Cache fehlgeschlagen, Server verweigert), spielt AVPlayer ihn an derselben Stelle ohne Kürzung weiter; das Menü zeigt „Für diesen Stream ausgeschaltet“. Die eigene Quelle fragt nach einem Verbindungsabbruch, einer Zeitüberschreitung oder einem fehlgeschlagenen Verbindungsaufbau zweimal neu an.
- **Vorlauf:** Nach einem Sprung braucht die Engine vor dem ersten Ton das Ende einer offenen Pause plus 1 s. AVAssetReader dekodiert ausserdem erst ab etwa 50 KB. Gleicher gedrosselter Lader, LNP 564:

  | Netz | Start Engine | Start AVPlayer | Sprung Engine | Sprung AVPlayer |
  |---|---|---|---|---|
  | 3-fache Bitrate | 5,58 s | 3,55 s | 4,50 s | 2,46 s |
  | 10-fache Bitrate | 1,86 s | 1,12 s | 1,47 s | 0,86 s |
  | 30-fache Bitrate | 0,86 s | 0,66 s | 0,64 s | 0,40 s |

  Bei ATP 717 dominiert beim Start der 576 KB grosse ID3-Kopf (10-fach: Engine 5,14 s, AVPlayer 5,26 s). Eine Schwelle von 0,3 s statt 1 s sparte nur 0,2 bis 0,6 s und hält die Uhr auf langsamen Netzen öfter an; sie bleibt bei 1 s.

### Umschalten während der Wiedergabe (gemessen 22.11.2026)

Vorher öffnete jedes Umschalten die Folge neu. Deep-E2E W, 10-ms-Aufzeichnung:
- Die Position sprang beim Ausschalten 0,52 s lang auf 0:00, beim Einschalten 0,07 s.
- Der Ton stand 71 bis 119 ms still.
- Zwei Mal kam „Folge gewechselt“, und Kapitel samt Kapitelbildern wurden neu geladen.

Jetzt:

| Fall | Stillstand | Sprung | „Folge gewechselt“ | Kapitelbild |
|---|---|---|---|---|
| W1 Engine aus und ein | keiner | keiner | 0 | bleibt |
| W2 AVPlayer → ein (Übergabe), dann aus | 69 ms an der stillen Stelle | keiner | 0 | bleibt |
| W3 Stream mit Cache, AVPlayer → ein | 63 ms an der stillen Stelle | keiner | 0 | bleibt |
| W4 Erkennung Silero → Lautstärke → Silero | keiner | keiner | 0 | bleibt |

Die Übergabe passiert an derselben Quellzeit (AVPlayer 1504,694 s, Engine 1504,694 s) an einer Stelle, die ±60 ms still ist. Glitch-Probe, Lauf 7: Nach dem Erkennungswechsel exakt die neue Kürzung, nach „aus“ die letzten 2,5 s sample-genau das Original (LNP 564, ATP 717, The Daily).

### Einstellungen von aussen

iCloud-Sync und Backup-Import schreiben nur UserDefaults beziehungsweise `CDFeedProperty`. Der PlaybackManager beobachtet beide Wege und wendet eine Änderung koalesziert auf die laufende Folge an:
- Funktion aus: Die Engine spielt ungekürzt weiter.
- Andere Stufe oder Erkennung: Wechsel in der Engine.
- Funktion ein, während AVPlayer spielt: Übergabe an der nächsten stillen Stelle.

## Messung (ganze Folgen, `--verify`)

| Folge | Länge | Sanft | Mittel | Stark | PC mild | PC medium | PC Mad Max |
|---|---|---|---|---|---|---|---|
| Logbuch:Netzpolitik 564 (DE, Gespräch) | 1:48 h | 5,8 % | 8,9 % | 12,1 % | 3,9 % | 4,5 % | 12,7 % |
| The Daily (produziert) | 0:29 h | 3,1 % | 5,0 % | 7,1 % | 1,2 % | 1,4 % | 5,7 % |
| ATP 717 (Gespräch) | 2:30 h | 4,9 % | 7,7 % | 10,5 % | 2,1 % | 2,8 % | 10,3 % |
| Lex Fridman (Interview, gegatet) | 3:27 h | 5,8 % | 9,1 % | 12,6 % | 6,1 % | 7,1 % | 18,8 % |
| Bits und so #1032 (DE, Runde mit vier Leuten) | 2:56 h | 3,7 % | 6,1 % | 8,7 % | 2,0 % | 2,6 % | 10,4 % |

Die Spalten „PC“ wenden die Regeln von Pocket Casts aus `AudioReadTask.swift` (MPL-2.0) auf dieselben Samples an: RMS pro 1152-Frame-Block, feste Schwelle bei etwa −46 dBFS, 4 bis 20 Blöcke als Mindestlücke, 0 bis 14 Blöcke werden wieder eingefügt. „Mad Max“ streicht ab 0,1 s fast die ganze Pause und schneidet bei gegateten Aufnahmen Wortenden und Atem mit; daher die 18,8 % bei Lex.

Die Prüfung bestand auf allen Folgen und Stufen:
- **F1:** Jeder unverschobene Hop ist sample-genau gleich der Eingabe (maximaler Fehler 6·10⁻⁸).
- **F2:** Kein verschobener Hop liegt ausserhalb einer Pause.
- **F3:** Kein Sprung ist grösser als der grösste Sprung in der Eingabepause selbst.
- **F4:** Die Zeitzuordnung ist monoton und deckt die ganze Datei ab.

Verarbeitung auf dem M2-Mac: 400- bis 1300-fache Echtzeit.

### Grenzen und Vergleich mit Overcast (gemessen 21.11.2026)

- **Die Ersparnis hängt am Abschnitt.** Bei Bits und so #1032 spart Stark im Mittel 5,2 s pro Minute, je nach Minute 2,4 bis 14 s.
  - Im Abschnitt 1:09:21 bis 1:10:53 lagen nur 9 s Stille in Läufen ab 0,1 s. Auch ein vollständiges Entfernen dieser Stille spart dort höchstens 10 %.
  - Die App sparte dort gleich viel wie die Offline-Referenz, gemessen im Diagnoseprotokoll des iPhones.
- **Overcast:** Marco Arment nennt für Smart Speed rund 15 % schneller auf seinen eigenen Sendungen, ohne systematische Messung. Unser Mittel erreicht auf ATP 1,084×, Stark 1,117×.
- **Mit der heutigen Erkennung ist bei etwa 1,13× Schluss** (Bits und so), bei ATP bei 1,15×. Dafür würde jede Pause fast ganz entfernt, mit Schutzzonen von nur 15 ms beziehungsweise 10 ms.
- **Die Pegelerkennung beantwortet „leise“, nicht „keine Sprache“.** Geräusche in einer Sprechpause gelten dort als Sprache. Das ist der Ansatz von Pocket Casts (RMS, feste Schwelle) und Media3 (fester Spitzenpegel von etwa −30 dBFS). An ihren Schwellen nicht drehen; „keine Sprache“ leistet die Spracherkennung unten.

## Spracherkennung (Silero VAD)

Recherche 21.11.2026: Stand der Technik für „Pause = keine Sprache“ ist eine Voice Activity Detection. Silero VAD schlägt in einem unabhängigen Vergleich (arXiv 2601.17270) WebRTC VAD deutlich, und beide schlagen eine Pegelschwelle. Auphonic schneidet Pausen mit VAD.

- **Modell:** Silero VAD v6.2.3, 16 kHz (`silero_vad_16k_op15.onnx`, MIT, `Classes/SilenceTrim/SileroVAD-LICENSE.txt`). `ICSileroVAD.swift` rechnet den ONNX-Graphen mit Accelerate nach: Fourier-Faltung, vier Faltungen, LSTM, Ausgang. Damit braucht es keine Laufzeitbibliothek und läuft unter iOS 17 und auf dem Mac.
  - Gewichte: `silero_export_weights.py` erzeugt `silero_vad_16k_v6.2.3.bin` byte-gleich (SHA-256 `5fb2a4b9…5006`). Die Safetensors-Datei im Silero-Repo enthält andere Gewichte; nur die ONNX-Initializer stimmen.
  - Numerik: Swift gegen ONNX Runtime maximal 1,3·10⁻⁶, keine abweichende Entscheidung (`silero_onnx_reference.py`). Mit dem eigenen Resampler statt `afconvert` weichen 0,17 % der Entscheidungen ab.
  - Kosten auf dem M2: 18 µs pro 32 ms (1800-fache Echtzeit), im Debug-Build 32 µs. Alle Schritte laufen als Accelerate-Aufrufe auf zusammenhängenden Puffern. Die erste skalare Fassung brauchte im Debug-Build 1,1 ms pro Abschnitt und der Resampler 8,6 s für 92 s Audio (jetzt 0,08 s). Ein Seek direkt nach dem Öffnen dauerte deshalb im Debug-Build 1,2 s; jetzt 0,19 s (Pegel 0,16 s, optimiert 23 ms).
- **Silero erkennt Äusserungen, nicht Wortlücken.** Im dichten Abschnitt 1:09–1:11 von Bits und so stuft es 96 % als Sprache ein, die Pegelerkennung 17 % als Pause. Ein Einatmer direkt zwischen zwei Wörtern liegt deshalb fast immer in einer Sprach-Äusserung.
  - Darum legt Silero keine Grenzen fest. Wortanfang und Wortende bleiben bei der sample-genauen Pegelerkennung, und die Schutzzonen wirken unverändert.
  - Grenzen gegeneinander, ganze Folge Bits und so #1032 mit Silero-Segmentierung nach Silero-Standard (0,5/0,35, 100 ms Mindeststille, 250 ms Mindestsprache, 30 ms Rand) gegen die Pausen der Pegelerkennung:
    - Silero: 93,5 % Sprache, 1905 Pausen mit 683 s. Pegel: 18,8 % Pause, 1985 s.
    - Von 4873 Pegel-Pausen ab 0,1 s sieht Silero 58 % gar nicht (444 s), ab 0,3 s noch 7 %, ab 0,6 s keine.
    - Silero lässt die Sprache im Median 98 ms nach dem Pegel-Wortende enden und 24 ms vor dem Pegel-Wortanfang beginnen. In 11 % der Pausen beginnt es aber später, im Median 220 ms, und in 10 % endet es früher, im Median 276 ms.
    - Das Raster ist 32 ms, die Pegelerkennung arbeitet in 10-ms-Frames und schneidet sample-genau mit Schutzzonen.
  - Silero entscheidet nur über ein Geräusch zwischen zwei stillen Stellen (höchstens 3 s): Enthält es keine Sprache (Silero-Standard: Beginn ab 0,5, Ende unter 0,35, 30 ms Rand), gehört es zur Pause.
- **Musik ist keine Sprechpause.** Geräusche ohne Sprache, die bis auf 15 dB an den Sprechpegel herankommen, bleiben unangetastet. Gemessen: In den vier Gesprächsfolgen liegen sie meist 20–35 dB darunter (Lex 420 von 445), bei The Daily 66 von 91 über −15 dB (Musik, Sound-Design).
- **Neustart:** Nach jedem Sitzungsbeginn (Seek, Flush, Decoder-Wechsel) ist das LSTM leer. Nach höchstens 41 Abschnitten (1,3 s) stimmen die Entscheidungen wieder; 2 s lang entscheidet Silero deshalb nichts.
- **Decoder-Wechsel nur in echter Stille:** Eine gekürzte Pause kann jetzt ein Geräusch enthalten. Der Wechsel auf das präzise Asset darf ein MP3-Frame versetzt sein und passiert deshalb nur, wo die Pegelerkennung ±1152 Samples um den Grain still meldet (`nextHopIsSilentPause`). Vorher: Sprung ×14,8 bei The Daily.
- **Prüfung, dass keine Wörter verschwinden:** Apples `SpeechTranscriber` fand in den 252 aufgenommenen Geräuschen von LNP 564 kein Wort, in den 145 von Bits und so ein „Ja“ in einem 40-ms-Schnipsel (Fehltreffer). Englische Sprachmodelle waren auf dem Mac nicht installiert.
- **Apples `SpeechDetector`** (iOS 26+) lieferte auf macOS 27.2.1 null Ergebnisse, bei 44,1 und 16 kHz und allen Empfindlichkeiten. Er setzt laut Apple eine laufende Transkription voraus. Nicht eingebaut.

| Folge | Stark, Lautstärke | Stark, Silero | aufgenommene Geräusche |
|---|---|---|---|
| Bits und so #1032 | 8,7 % | 8,8 % | 114 (5,4 s) |
| ATP 717 | 10,5 % | 10,6 % | 41 (3,4 s) |
| The Daily | 7,1 % | 7,3 % | 25 (2,6 s) |
| Logbuch:Netzpolitik 564 | 12,1 % | 12,7 % | 252 (28,5 s) |
| Lex Fridman | 12,6 % | 13,3 % | 431 (71,1 s) |

Der Gewinn ist klein, weil Geräusche zwischen zwei stillen Stellen selten sind. Einatmer innerhalb einer Äusserung bräuchten einen eigenen Atem-Klassifikator (Auphonic hat einen), keine VAD. Hörproben: `build/SilenceTrim/Hoerproben-Silero/`.

## Werkzeuge

```bash
swiftc -O -parse-as-library -o build/SilenceTrim/silence_trim_analyze \
  Classes/SilenceTrim/ICSilenceCompressor.swift Classes/SilenceTrim/ICSilenceTrimLevel.swift \
  Classes/SilenceTrim/ICSileroVAD.swift Tools/SilenceTrim/silence_trim_analyze.swift
build/SilenceTrim/silence_trim_analyze <folge.mp3> --verify --json report.json
build/SilenceTrim/silence_trim_analyze <folge.mp3> --start 900 --seconds 180 --wav-dir build/SilenceTrim/Hoerproben
build/SilenceTrim/silence_trim_analyze <folge.mp3> --seconds 600 --sweep
```

Mit Spracherkennung: `--detector speech`. Dazu `--islands-wav <datei.wav>` schreibt alle aufgenommenen Geräusche hintereinander (Hörprüfung, mit Index `.txt`), `--runs-out <datei>` alle Pausen, `--island-max-db off` schaltet die Musik-Regel ab.

Engine-Probe auf macOS (stumm, echte Folge):

```bash
swiftc -O -parse-as-library -o build/SilenceTrim/silence_trim_player_probe \
  Classes/SilenceTrim/ICSilenceCompressor.swift Classes/SilenceTrim/ICSilenceTrimLevel.swift \
  Classes/SilenceTrim/ICSilenceTrimPlayer.swift Classes/SilenceTrim/ICSilenceTrimHTTPSource.swift Classes/SilenceTrim/ICSileroVAD.swift Tools/SilenceTrim/silence_trim_player_probe.swift
build/SilenceTrim/silence_trim_player_probe <folge.mp3>
```

Glitch-Probe auf macOS: Sie baut aus allen eingereihten Puffern abzüglich der Flushes das tatsächlich gespielte Audio nach und vergleicht es sample-genau mit der Offline-Referenz. Geprüft werden Lücken, Pause und Start in Pausen, Seeks, Stufenwechsel, automatische Flushes einschliesslich gezielter Flushes im letzten Hop vor einer Pause sowie der Decoder-Wechsel.

```bash
swiftc -O -parse-as-library -o build/SilenceTrim/silence_trim_glitch_probe \
  Classes/SilenceTrim/ICSilenceCompressor.swift Classes/SilenceTrim/ICSilenceTrimLevel.swift \
  Classes/SilenceTrim/ICSilenceTrimPlayer.swift Classes/SilenceTrim/ICSilenceTrimHTTPSource.swift Classes/SilenceTrim/ICSileroVAD.swift Tools/SilenceTrim/silence_trim_glitch_probe.swift
build/SilenceTrim/silence_trim_glitch_probe <folge.mp3> [report.json]
SILENCE_TRIM_SPEECH=1 build/SilenceTrim/silence_trim_glitch_probe <folge.mp3> [report.json]   # mit Spracherkennung
SILENCE_TRIM_STREAM=30000000 build/SilenceTrim/silence_trim_glitch_probe <folge.mp3>            # als Stream
python3 Tools/SilenceTrim/silence_trim_range_server.py --port 8771 --root <ordner der folge> &
SILENCE_TRIM_HTTP=http://127.0.0.1:8771 build/SilenceTrim/silence_trim_glitch_probe <folge.mp3>  # über HTTP, ohne Stream-Cache
```

Mit `SILENCE_TRIM_STREAM=<Bytes/s>` liest der Player die Datei über einen Ersatz für den Stream-Cache (neueste Anfrage zuerst, dann der Rest der Reihe nach). Der Download wird während des Laufs fertig, alle Prüfungen decken also auch Stream-Start und Wechsel auf die Datei ab. Lauf 6 prüft zusätzlich einen Stream mit 70 % der Bitrate (Uhr hält, Audio lückenlos und exakt) und einen Sprung in einen nicht geladenen Teil (Uhr wartet, Audio exakt, alte Anfrage zurückgezogen). Mit `SILENCE_TRIM_HTTP` läuft dasselbe über echtes HTTP mit der eigenen Quelle; der Server stellt die Drosselung über `/control?rate=` um, ein separater Download wird nach 4 s mit der lokalen Datei nachgestellt.

E2E in der App (Simulator ohne iCloud-Konto, echte MP3):

```bash
python3 Tools/silence_trim_simulator_test.py --udid <UDID> --app <InstacastPlus.app> --fixture <folge.mp3> --evidence build/SilenceTrim/e2e [--prepare-ui]
```

Tiefen-E2E mit demselben Setup, Auswahl der Szenarien über `SILENCE_TRIM_SCENARIOS` (Standard `PSRBU`):
- P: Pause, Start und Seek in einer langen Pause.
- S: Stream und Download parallel, mit und ohne Stream-Cache, fremder Download, gelöschter Download, Download während Pause, Stream unter der Bitrate (S7 über den echten Stream-Cache, S8 mit der eigenen Quelle; `/slow…` mit 7 KB/s). Ohne Stream-Cache wird auch geprüft, dass die temporäre Datei beim Schliessen verschwindet.
- R: Einstellungen von aussen auf dieselbe Art, wie Sync und Import sie schreiben.
- B: Backup-Export und -Import.
- U: Anzeige „gespart“ beim Stream, echte Taps in den Einstellungen, Dark Mode.
- T: tatsächlich übertragene Bytes pro Anfrage, mit und ohne Engine und Stream-Cache (nicht im Standard, `SILENCE_TRIM_SCENARIOS=T`).

```bash
python3 Tools/silence_trim_deep_simulator_test.py --udid <UDID> --app <InstacastPlus.app> --fixture <folge.mp3> --evidence build/SilenceTrim/deep
```
