# Sprechpausen kürzen (Silence Trim)

## Funktionsweise

`Classes/SilenceTrim/ICSilenceCompressor.swift` verkürzt Pausen, ohne Sprache anzufassen. Das entspricht dem, was Overcast für Smart Speed beschreibt: Stille wird stärker beschleunigt als der Rest (Marco Arment, TechCrunch 2014).

- **Erkennung:**
  - 10-ms-Frames eines mit 100 Hz hochpassgefilterten Mono-Signals.
  - Die Schwelle passt sich lokal an: Perzentile P10 (Grundrauschen) und P90 (Sprechpegel) über 15 s zurück und 5 s voraus.
  - Schwelle = max(Rauschboden + max(6 dB, 25 % des Abstands), Sprechpegel − 38 dB), höchstens Sprechpegel − 20 dB, mit 3 dB Hysterese.
  - Bei weniger als 15 dB Kontrast, etwa unter einem Musikbett, wird nichts gekürzt.
  - Klicks bis 20 ms innerhalb einer Pause unterbrechen sie nicht.
- **Kürzen:** Eine einzige WSOLA-Zeitskalierung mit Grains von 11,6 ms und Hann-Fenstern bei 50 % Überlappung.
  - In Sprache und in den Schutzzonen schreitet die Analyse genau um einen Hop weiter. Weil sich die Fenster dort zu genau 1 aufsummieren, kommt die Sprache sample-genau unverändert heraus.
  - In der Pause springt die Analyse um `silenceRate`-mal so viel weiter. Jeder Grain wird per normierter Kreuzkorrelation an die natürliche Fortsetzung des vorherigen angelegt. Dadurch bleiben Raumklang, Brummen und Atem durchgehend, es gibt keinen Schnitt.
- **Schutzzonen:** Nach dem Sprechende bleibt `leadingGuard` in Originalgeschwindigkeit (Nachhall, auslautende Zischlaute), vor dem Einsatz `trailingGuard`. Pausen, die kürzer sind als beide Zonen plus ein Grain, bleiben unverändert. Das schützt die Verschlusspausen innerhalb von Konsonanten.
- **Proportional:** Innerhalb der Schutzzonen wird jede Pause um denselben Faktor kürzer. `maximumPauseDuration` begrenzt, was eine lange Pause behält.

`ICSilenceTrimPlayer.swift` spielt die Datei über `AVSampleBufferAudioRenderer` mit `AVSampleBufferRenderSynchronizer` ab. Das ist der Weg, für den Apple bei eigenen Playern AirPlay-2-Enhanced-Buffering dokumentiert.
- Das Tempo setzt der Synchronizer, mit demselben Time-Pitch-Algorithmus wie `AVPlayerItem`.
- Nach aussen meldet der Player immer die Quellzeit der Datei: Positionen, Kapitel, Skip-Marker, iCloud, Watch und Sperrbildschirm.

## Messung (ganze Folgen, `--verify`)

| Folge | Länge | Sanft | Mittel | Stark | PC mild | PC medium | PC Mad Max |
|---|---|---|---|---|---|---|---|
| Logbuch:Netzpolitik 564 (DE, Gespräch) | 1:48 h | 5,8 % | 8,9 % | 12,1 % | 3,9 % | 4,5 % | 12,7 % |
| The Daily (produziert) | 0:29 h | 3,1 % | 5,0 % | 7,1 % | 1,2 % | 1,4 % | 5,7 % |
| ATP 717 (Gespräch) | 2:30 h | 4,9 % | 7,7 % | 10,5 % | 2,1 % | 2,8 % | 10,3 % |
| Lex Fridman (Interview, gegatet) | 3:27 h | 5,8 % | 9,1 % | 12,6 % | 6,1 % | 7,1 % | 18,8 % |

Die Spalten „PC“ wenden die Regeln von Pocket Casts aus `AudioReadTask.swift` (MPL-2.0) auf dieselben Samples an: RMS pro 1152-Frame-Block, feste Schwelle bei etwa −46 dBFS, 4 bis 20 Blöcke als Mindestlücke, 0 bis 14 Blöcke werden wieder eingefügt. „Mad Max“ streicht ab 0,1 s fast die ganze Pause und schneidet bei gegateten Aufnahmen Wortenden und Atem mit; daher die 18,8 % bei Lex.

Die Prüfung bestand auf allen Folgen und Stufen:
- **F1:** Jeder unverschobene Hop ist sample-genau gleich der Eingabe (maximaler Fehler 6·10⁻⁸).
- **F2:** Kein verschobener Hop liegt ausserhalb einer Pause.
- **F3:** Kein Sprung ist grösser als der grösste Sprung in der Eingabepause selbst.
- **F4:** Die Zeitzuordnung ist monoton und deckt die ganze Datei ab.

Verarbeitung auf dem M2-Mac: 400- bis 1300-fache Echtzeit.

## Werkzeuge

```bash
swiftc -O -parse-as-library -o build/SilenceTrim/silence_trim_analyze \
  Classes/SilenceTrim/ICSilenceCompressor.swift Classes/SilenceTrim/ICSilenceTrimLevel.swift \
  Tools/SilenceTrim/silence_trim_analyze.swift
build/SilenceTrim/silence_trim_analyze <folge.mp3> --verify --json report.json
build/SilenceTrim/silence_trim_analyze <folge.mp3> --start 900 --seconds 180 --wav-dir build/SilenceTrim/Hoerproben
build/SilenceTrim/silence_trim_analyze <folge.mp3> --seconds 600 --sweep
```

Engine-Probe auf macOS (stumm, echte Folge):

```bash
swiftc -O -parse-as-library -o build/SilenceTrim/silence_trim_player_probe \
  Classes/SilenceTrim/ICSilenceCompressor.swift Classes/SilenceTrim/ICSilenceTrimLevel.swift \
  Classes/SilenceTrim/ICSilenceTrimPlayer.swift Tools/SilenceTrim/silence_trim_player_probe.swift
build/SilenceTrim/silence_trim_player_probe <folge.mp3>
```

E2E in der App (Simulator ohne iCloud-Konto, echte MP3):

```bash
python3 Tools/silence_trim_simulator_test.py --udid <UDID> --app <InstacastPlus.app> --fixture <folge.mp3> --evidence build/SilenceTrim/e2e [--prepare-ui]
```
