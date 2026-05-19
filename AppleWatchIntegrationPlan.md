# Apple Watch Integration Plan

Stand: 2026-05-18

## Ziel

InstacastPlus bekommt eine Apple-Watch-Integration, bei der das iPhone verwaltet, welche Episoden auf die Watch sollen, und die Watch die Audiodateien selbst mit denselben Media-URLs wie das iPhone herunterlaedt. Die Watch-Liste ist offline nutzbar, der Wiedergabestatus wird zwischen iPhone und Watch synchronisiert.

Kundensicht:

> Waehle auf dem iPhone aus, was auf die Apple Watch soll. Die Watch laedt die Episoden selbst ueber WLAN oder Mobilfunk und haelt den Hoerfortschritt synchron.

## Getroffene Produktentscheidungen

- Die Verwaltung passiert am iPhone.
- Die Watch laedt Audiodateien selbst, nicht per Datei-Upload vom iPhone.
- Die Watch verwendet exakt dieselben Media-URLs wie das iPhone.
- Es gibt keinen zusaetzlichen HTTPS-Zwang fuer Watch-Downloads.
- Mobilfunk ist immer erlaubt.
- Videos werden fuer die erste Version ausgeschlossen.
- Pro Podcast gibt es die Regel "Neueste X Episoden auf Apple Watch".
- Zusatzoption pro Podcast: "Nur ungespielte Episoden", standardmaessig aktiviert.
- Episoden koennen manuell ueber Kontextmenue und optional ueber Swipe-Action zur Watch hinzugefuegt werden.
- Manuell hinzugefuegte Episoden verwenden ihr Hinzufuegedatum fuer Sortierung und Retention.
- Automatisch ausgewaehlte Episoden verwenden die Publizierzeit.
- Gehoerte Episoden gehen ans Ende der Watch-Liste und werden zuerst geloescht, wenn Platz gebraucht wird.
- "Auf Apple Watch" bedeutet erst, dass die Watch den fertigen lokalen Download bestaetigt hat.
- Byte-Groesse und Dauer vom iPhone sind nur Hinweise, weil Dynamic Ad Insertion bei gleicher URL unterschiedliche Dateien liefern kann.
- Die Watch misst reale Dateigroesse, reale Dauer und realen Speicherverbrauch selbst.

## WatchOS-Ziel

Empfohlenes Minimum: watchOS 9.0.

Gruende:

- WatchConnectivity ist fuer die iPhone-Watch-Kommunikation vorhanden.
- Background URLSession ist fuer Watch-Downloads vorhanden.
- SwiftUI Background Tasks sind ab watchOS 9 der von Apple bevorzugte Weg fuer Background-Task-Handling.
- Xcode 26.5 kann laut Apple noch watchOS 8 bauen, aber fuer watchOS 8 muesste mehr alter WatchKit-Delegate-Pfad mitgetragen werden, ohne dass dieses Feature davon fachlich profitiert.

## Hochrangige Architektur

Das System besteht aus drei getrennten Verantwortungen:

1. iPhone: Auswahl und Kunden-UI
2. Watch: echte Downloads, lokale Dateien, lokaler Speicher
3. Sync-Protokoll: Manifest, Status, Positionen

### iPhone

Neue Komponente:

```text
AppleWatchSyncManager
```

Aufgaben:

- WatchConnectivity-Session aktivieren.
- Watch-Zustand erkennen: gekoppelt, Watch-App installiert, erreichbar.
- Soll-Liste fuer die Watch berechnen.
- Manifest an die Watch senden.
- Statusmeldungen der Watch verarbeiten.
- Wiedergabestatus zwischen iPhone und Watch zusammenfuehren.
- Apple-Watch-Seite und Episodenlisten-Icons mit Status versorgen.

Bestehende Integrationspunkte:

- Episodenmodell: `CDEpisode`
- Feed-Einstellungen: `CDFeed` FeedProperties
- Download-/Playbackstatus: `PlaybackManager`, `DatabaseManager`
- Episoden-Kontextmenues: `EpisodesTableViewController`, `EpisodeViewController`
- Seitenmenue/Systemlisten: `MainViewController_4`, bestehende `CDEpisodeList`-Patterns

### Watch

Neue Watch-App:

```text
Instacast Watch App
```

Kernkomponenten:

```text
WatchManifestStore
WatchDownloadManager
WatchPlaybackStateStore
WatchConnectivityController
WatchStorageManager
```

Aufgaben:

- Manifest vom iPhone empfangen und lokal persistieren.
- Downloads per background URLSession starten.
- Download-Fortschritt, Erfolg und Fehler an iPhone melden.
- Dateien dauerhaft in Watch-App-Sandbox speichern.
- Speicher pruefen und bei Bedarf alte Episoden loeschen.
- Wiedergabe starten und Positionen periodisch sowie bei Pause/Seek/Ende melden.

## Datenmodell

Die Watch-Zugehoerigkeit sollte nicht als einfacher Boolean an `CDEpisode` modelliert werden. Es braucht eigenen Status, weil Auswahl, Manifest-Zustellung, Download und bestaetigte Datei unterschiedliche Zustaende sind.

Neue iPhone-Entity oder aequivalente Tabelle:

```text
AppleWatchEpisodeState
```

Felder:

```text
episodeHash: String
feedIdentifier: String
selectionSource: manual | latestRule
watchStatus: selected | manifestSent | queuedOnWatch | downloading | downloaded | failed | removing
watchAddedDate: Date
watchDownloadedDate: Date?
watchLastSeenDate: Date?
watchLastError: String?
watchActualDuration: Int32?
watchActualFileSize: Int64?
lastPhonePosition: Int32
lastPhonePositionDate: Date?
lastWatchPosition: Int32?
lastWatchPositionDate: Date?
watchConsumed: Bool?
watchConsumedDate: Date?
```

Feed-Properties:

```text
AppleWatchSendLatestCount: Int
AppleWatchOnlyUnplayed: Bool default YES
```

Watch-lokales Modell:

```text
episodeHash
feedIdentifier
title
podcastTitle
pubDate
durationHint
mediaURL
selectionSource
watchAddedDate
status
localFileURL
actualFileSize
actualDuration
lastPlaybackPosition
lastPlaybackDate
consumed
lastError
```

## Manifest

Das iPhone sendet keine grosse Datenbank, sondern ein kompaktes Manifest der Episoden, die auf die Watch sollen.

Minimaler Manifest-Eintrag:

```json
{
  "episodeHash": "string",
  "feedIdentifier": "string",
  "title": "string",
  "podcastTitle": "string",
  "pubDate": "ISO-8601",
  "durationHint": 1234,
  "position": 120,
  "consumed": false,
  "mediaURL": "string",
  "selectionSource": "manual",
  "watchAddedDate": "ISO-8601"
}
```

Regeln:

- `mediaURL` ist dieselbe URL, die das iPhone fuer die Episode verwendet.
- Keine zusaetzliche Auth-Abstraktion in Version 1.
- Keine Byte-Groesse als Pflichtfeld.
- `durationHint` ist nur ein Startwert fuer UI und Positions-Clamping.
- Watch meldet nach Download `actualDuration` und `actualFileSize` zurueck.

## Sync-Protokoll

### iPhone zu Watch

Kanäle:

- `transferUserInfo`: verlaessliche, geordnete Zustellung von Manifest-Aenderungen und Commands.
- `sendMessage`: nur fuer Live-Aktionen, wenn die Watch-App erreichbar ist.
- `updateApplicationContext`: nur fuer aktuellen Gesamtzustand, nicht fuer Historie.

Message-Typen:

```text
manifest.replace
manifest.upsertEpisodes
manifest.removeEpisodes
download.prioritize
download.cancel
playback.phoneState
```

### Watch zu iPhone

Message-Typen:

```text
watch.ackManifest
watch.downloadQueued
watch.downloadProgress
watch.downloaded
watch.downloadFailed
watch.deleted
watch.storageStatus
playback.watchPosition
playback.watchFinished
```

### Positionskonflikte

Regeln:

- Jede Positionsaenderung traegt einen Zeitstempel.
- Der neueste gueltige Zeitstempel gewinnt.
- `consumed == true` gewinnt gegen aeltere Zwischenpositionen.
- Position wird auf die lokal bekannte Dauer begrenzt.
- Bei Dynamic Ad Insertion wird keine bytegenaue Gleichheit zwischen iPhone-Datei und Watch-Datei erzwungen.

## Download-Verhalten auf der Watch

Die Watch erstellt fuer Downloads eine background URLSession:

```text
URLSessionConfiguration.background(withIdentifier:)
allowsCellularAccess = true
sessionSendsLaunchEvents = true
waitsForConnectivity = true
```

Verhalten:

- Beim Empfang neuer Manifest-Episoden startet die Watch Downloads.
- Wenn die Watch-App im Vordergrund ist, sollen Downloads sofort starten.
- Wenn die App in den Hintergrund geht, laufen Downloads ueber background URLSession weiter, soweit watchOS sie ausfuehrt.
- Progress zeigt Prozent nur, wenn `countOfBytesExpectedToReceive` sinnvoll ist.
- Sonst zeigt die UI geladene MB und Status "Laedt".

## Sofort-Download / Priorisieren

Einzelne Downloads koennen priorisiert werden, aber nicht hart garantiert.

Moegliche UI-Aktion:

```text
Priorisiert auf Watch laden
```

Technische Umsetzung:

- Wenn `WCSession.isReachable == true`, sendet das iPhone per `sendMessage` sofort `download.prioritize`.
- Wenn die Watch nicht erreichbar ist, sendet das iPhone denselben Befehl per `transferUserInfo`.
- Auf der Watch setzt `WatchDownloadManager` den Download in der Queue nach vorne.
- Wenn der Nutzer die Watch-App oeffnet und die Episode dort anstoesst, ist das der staerkste praktische Trigger.

Wichtige Grenze:

- `sendMessage` vom iPhone weckt die Watch-App nicht auf.
- `transferUserInfo` wird gequeued und spaeter zugestellt.
- watchOS kann Background-Downloads aus Akku-, Netz- und Systemgruenden verzögern.

## Speicherverwaltung

Die Watch ist Source of Truth fuer echten Speicher.

Die Watch meldet regelmaessig:

```text
freeBytes
instacastWatchDownloadBytes
episodeCount
lastCleanupDate
```

Loeschreihenfolge, wenn neue Episoden Platz brauchen:

1. Gehoerte Episoden
2. Aelteste automatisch ausgewaehlte Episoden
3. Aeltere manuell hinzugefuegte Episoden
4. Niemals die gerade spielende Episode

Nach jedem automatischen Loeschen sendet die Watch `watch.deleted` an das iPhone.

## iPhone UI

### Seitenmenue

Neue Seite:

```text
Apple Watch
```

Sichtbarkeit:

- Anzeigen, wenn eine Apple Watch gekoppelt ist.
- Wenn die Watch-App nicht installiert ist, zeigt die Seite einen Aktivierungs-/Installationshinweis.

Header-Beispiel:

```text
Apple Watch
12 auf der Watch
3 werden geladen
Letzte Synchronisierung 14:32

[Jetzt synchronisieren]
```

Listenstatus pro Episode:

```text
Auf Apple Watch
Laedt auf Apple Watch
Wartet auf Apple Watch
Fehler beim Laden
Wird entfernt
```

### Normale Episodenlisten

Links unter dem Transkript-Icon ein Watch-Icon anzeigen, wenn die Episode bestaetigt auf der Watch geladen ist.

Regel:

- Volles Watch-Icon nur bei `watchStatus == downloaded`.
- Keine lauten Zwischenstatus in normalen Episodenlisten.
- Download-/Fehlerdetails nur auf der Apple-Watch-Seite.

### Kontextmenue / Swipe

Neue Aktionen:

```text
An Apple Watch senden
Von Apple Watch entfernen
Priorisiert auf Watch laden
```

`Priorisiert auf Watch laden` erscheint nur, wenn die Episode fuer die Watch ausgewaehlt, aber noch nicht geladen ist.

### Podcast-Einstellungen

Neue Sektion:

```text
Apple Watch
```

Rows:

```text
Neueste Episoden senden: Aus / 1 / 2 / 3 / 5 / 10
Nur ungespielte Episoden
```

Default:

```text
Neueste Episoden senden: Aus
Nur ungespielte Episoden: Ein
```

## Watch UI

Watch-Hauptliste:

- Episoden sortiert nach neuestem Sortierdatum.
- Automatisch ausgewaehlte Episoden: `pubDate`.
- Manuell hinzugefuegte Episoden: `watchAddedDate`.
- Gehoerte Episoden am Ende.

Episode-Zeile:

```text
Titel
Podcast
Restzeit oder Dauer
Downloadstatus
```

Aktionen:

```text
Abspielen
Download erneut versuchen
Von Watch entfernen
```

## Dynamic Ad Insertion

Problem:

- Gleiche Media-URL kann zu unterschiedlichen Zeitpunkten unterschiedliche Dateien liefern.
- iPhone und Watch koennen dadurch verschiedene reale Dauer und Dateigroesse sehen.

Entscheidung:

- Positionssync bleibt sekundenbasiert, passend zum bestehenden Instacast-Modell.
- Watch clampet Positionen auf ihre reale lokale Dauer.
- iPhone uebernimmt Watch-Positionen nach Zeitstempel.
- Keine Versionierung einzelner Ad-Insertion-Dateien in Version 1.

## Fehlerfaelle und Risiken

### Manifest nicht rechtzeitig auf Watch

Wenn der Nutzer losgeht, bevor die Watch das Manifest empfangen hat, kann sie die Episode nicht selbst laden.

Produktloesung:

- UI trennt "Ausgewaehlt" von "Auf Watch angekommen".
- Apple-Watch-Seite zeigt "Wartet auf Apple Watch".

### Background-Downloads sind nicht sofort garantiert

watchOS entscheidet ueber Timing von background URLSession.

Produktloesung:

- Keine Texte wie "sofort geladen".
- Stattdessen "Laedt auf Apple Watch" und "Priorisiert laden".

### Offline-Konflikte

iPhone und Watch koennen dieselbe Episode getrennt weiterhoeren.

Technische Loesung:

- Zeitstempel-basierte Zusammenfuehrung.
- Fertig gehoert gewinnt gegen aeltere Positionen.

### Speicher knapp

iPhone kennt echten Watch-Speicher nicht.

Technische Loesung:

- Watch verwaltet Speicher selbst.
- Watch meldet Loeschungen ans iPhone.

### Simulator

WatchConnectivity muss auf echten gepaarten Geraeten getestet werden. Der Simulator reicht fuer diese Integration nicht als Abschlusspruefung.

## Implementierungsphasen

### Phase 1: Watch Target und Verbindung

- Watch-App-Target mit Minimum watchOS 9.0 anlegen.
- WatchConnectivity auf iPhone und Watch aktivieren.
- Watch-Zustand auf iPhone erkennen:
  - paired
  - watch app installed
  - reachable
- Diagnoseansicht oder Debug-Log fuer Session-Zustand.

Verifikation:

- Echte Watch koppeln.
- iPhone erkennt Watch-App.
- Watch und iPhone koennen Ping/Pong austauschen.

### Phase 2: iPhone Watch-State-Modell

- `AppleWatchEpisodeState` einfuehren.
- Feed-Properties fuer "Neueste X" und "Nur ungespielte".
- Soll-Liste berechnen.
- Manuelles Hinzufuegen und Entfernen modellieren.

Verifikation:

- Unit-/Regressionstest fuer Regelberechnung:
  - nur ungespielte
  - Videos ausgeschlossen
  - manuelle Episoden bleiben erhalten
  - gehoerte Episoden sortieren ans Ende

### Phase 3: Apple-Watch-Seite auf iPhone

- Seitenmenue-Eintrag.
- Liste der Watch-Episoden und Status.
- Button "Jetzt synchronisieren".
- Leere Zustaende:
  - keine Watch gekoppelt
  - Watch-App nicht installiert
  - keine Episoden ausgewaehlt

Verifikation:

- UI zeigt Status aus lokalem Modell korrekt.

### Phase 4: Manifest-Sync

- Manifest bauen.
- `transferUserInfo` fuer Aenderungen.
- `sendMessage` fuer Live-Priorisierung, wenn erreichbar.
- Watch persistiert Manifest.
- Watch bestaetigt Empfang.

Verifikation:

- Manifest kommt auf echter Watch an.
- iPhone wechselt Status zu `queuedOnWatch`.

### Phase 5: Watch-Downloads

- `WatchDownloadManager` mit background URLSession.
- Downloads mit denselben Media-URLs wie iPhone.
- Mobilfunk erlaubt.
- Fortschritt und Fehler speichern.
- Fertige Dateien dauerhaft verschieben.

Verifikation:

- Download im Vordergrund.
- Download nach Verlassen der Watch-App.
- Download ohne iPhone in Reichweite ueber Watch-Netzwerk.

### Phase 6: Status-Sync Watch zu iPhone

- Downloadstatus an iPhone senden.
- Watch-Speicherstatus senden.
- iPhone aktualisiert `AppleWatchEpisodeState`.
- Normale Episodenlisten zeigen Watch-Icon bei `downloaded`.

Verifikation:

- Icon erscheint erst nach bestaetigtem Watch-Download.
- Fehler bleiben sichtbar auf Apple-Watch-Seite.

### Phase 7: Playback auf Watch

- Lokaler Watch-Player fuer heruntergeladene Audiodateien.
- Start an synchronisierter Position.
- Position periodisch melden.
- Position bei Pause, Seek und Ende melden.

Verifikation:

- Auf iPhone starten, auf Watch weiterhoeren.
- Auf Watch starten, auf iPhone weiterhoeren.
- Konfliktfall mit neuesten Zeitstempeln pruefen.

### Phase 8: Speicherbereinigung

- Watch prueft Speicher vor neuen Downloads.
- Loeschreihenfolge implementieren.
- Geloeschte Episoden an iPhone melden.

Verifikation:

- Kuenstlich knapper Speicher.
- Gehoerte Episoden werden zuerst entfernt.
- Gerade spielende Episode wird nicht entfernt.

### Phase 9: Kontextmenue, Swipe und Einstellungen

- Episoden-Kontextmenues erweitern.
- Optional Swipe-Action konfigurierbar machen.
- Podcast-Einstellungen erweitern.
- Lokalisierungen DE/EN ergaenzen.

Verifikation:

- Aktionen in Episodenliste und Show-Notes stimmen ueberein.
- Icon-Konventionen bleiben konsistent.

### Phase 10: Echte Watch-Testmatrix

Testfaelle:

- iPhone und Watch nebeneinander.
- Watch nur WLAN.
- Cellular-Watch ohne iPhone.
- App im Vordergrund.
- App im Hintergrund.
- iPhone-App beendet.
- Watch-App beendet.
- Dynamic-Ad-Insertion-Feed.
- Fehlerhafte Media-URL.
- Viele Podcasts mit vielen Watch-Regeln.
- Watch-Speicher knapp.

## Kundenkommunikation

Begriffe in UI und Hilfe:

```text
Fuer Apple Watch ausgewaehlt
Wird auf der Apple Watch geladen
Auf Apple Watch
Wartet auf Apple Watch
Fehler beim Laden
```

Nicht verwenden:

```text
Hochgeladen
Sofort geladen
Synchronisiert
```

Grund:

- Die Watch laedt selbst, daher ist "hochgeladen" technisch falsch.
- Background-Downloads sind nicht garantiert sofort.
- "Synchronisiert" ist zu ungenau: Auswahl, Manifest, Datei und Wiedergabestatus sind getrennte Zustaende.

## Apple-Dokumentation

- WatchConnectivity WCSession: https://developer.apple.com/documentation/WatchConnectivity/WCSession
- WCSession `isReachable`: https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable
- WCSession `sendMessage`: https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)
- WCSession `transferUserInfo`: https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:)
- watchOS background requests: https://developer.apple.com/documentation/watchos-apps/making-background-requests
- WKURLSessionRefreshBackgroundTask: https://developer.apple.com/documentation/watchkit/wkurlsessionrefreshbackgroundtask
- URLSessionConfiguration `allowsCellularAccess`: https://developer.apple.com/documentation/foundation/urlsessionconfiguration/allowscellularaccess
- Xcode SDK and deployment targets: https://developer.apple.com/xcode/system-requirements/
