# InstacastPlus Changelog

Alle Neuerungen, Verbesserungen und Fehlerbehebungen im Vergleich zur Vorgängerversion.

---

## Neue Features

### Intelligenter Schlaf-Timer

Der Sleep Timer wurde komplett überarbeitet und bietet jetzt eine intelligente Erkennung, ob du noch wach bist.

- **Immer-aktiv-Modus:** Der Sleep Timer kann so eingestellt werden, dass er bei jeder Wiedergabe automatisch startet. So wird verhindert, dass Podcasts versehentlich die ganze Nacht durchlaufen.
- **Intelligente Wach-Erkennung:** Der Timer setzt sich automatisch zurück, wenn er erkennt, dass du noch wach bist. Dafür stehen drei Sensoren zur Verfügung:
  - **Bildschirmberührung** -- Jede Interaktion mit dem Display setzt den Timer zurück.
  - **Lautstärkeänderung** -- Drücken der Lautstärketasten signalisiert, dass du noch zuhörst.
  - **Gerätebewegung** -- Bewegungen des Geräts (z.B. Umdrehen im Bett) werden erkannt.
- **Timer-Optionen:** 3, 5, 10, 20, 30 oder 60 Minuten.
- **Schnell deaktivieren:** Langer Druck auf den Timer-Button deaktiviert den Timer sofort.
- **Verbleibende Zeit im Player:** Der Timer-Button zeigt die verbleibende Zeit im Format MM:SS direkt im Player an.

> **Tipp:** Die Einstellungen für den intelligenten Schlaf-Timer findest du unter *Einstellungen > Sleep Timer*. Aktiviere dort "Sleep Timer immer aktiv", damit der Timer bei jeder Wiedergabe automatisch startet.

---

### Automatisches Kapitel-Überspringen

Intros, Werbung oder wiederkehrende Segmente können jetzt automatisch übersprungen werden.

- **Kapitel nach Stichwort überspringen:** Definiere Schlüsselwörter (z.B. "Intro", "Werbung", "Sponsor"), und alle Kapitel, die diese Wörter im Titel enthalten, werden automatisch übersprungen.
- **Intro überspringen:** Überspringe automatisch eine einstellbare Anzahl Sekunden am Anfang jeder Episode.
- **Outro überspringen:** Überspringe automatisch eine einstellbare Anzahl Sekunden am Ende jeder Episode.
- **Pro Podcast konfigurierbar:** Jeder Podcast kann eigene Skip-Regeln haben.

> **Tipp:** Die Auto-Skip-Einstellungen findest du in den Einstellungen jedes einzelnen Podcasts. Öffne einen Podcast, tippe auf das Zahnrad-Symbol und scrolle zum Bereich "Auto Skip".

---

### CarPlay-Unterstützung

InstacastPlus unterstützt jetzt Apple CarPlay für die Nutzung im Auto.

- **Podcast-Liste:** Alle abonnierten Podcasts werden mit Artwork und Episodenanzahl angezeigt.
- **Episoden-Übersicht:** Die neuesten Episoden jedes Podcasts sind direkt auswählbar.
- **Wiedergabesteuerung:** Tippe auf eine Episode, um sie direkt abzuspielen -- die Wiedergabe setzt an der zuletzt gehörten Stelle fort.
- **Echtzeit-Aktualisierung:** Neue Abonnements und Episoden erscheinen sofort in CarPlay.

---

### MQTT Smart Home Integration

InstacastPlus kann jetzt über das MQTT-Protokoll mit deinem Smart Home kommunizieren. Damit lassen sich Automatisierungen basierend auf dem Wiedergabestatus erstellen.

**Veröffentlichte Status-Informationen:**
- Wiedergabestatus (Play/Pause), Podcast- und Episodenname, aktuelles Kapitel
- Wiedergabeposition, Fortschritt in Prozent, Wiedergabegeschwindigkeit
- Sleep-Timer-Status und verbleibende Zeit
- Systemlautstärke und Audio-Ausgang (Lautsprecher, Kopfhörer, AirPlay)
- Gerätestatus: gesperrt/entsperrt, Akkustand, Ladezustand
- Einschlaf-Erkennung: Wird veröffentlicht, wenn der Sleep Timer abläuft
- Bewegungserkennung: Signalisiert, ob das Gerät bewegt wird

**Fernsteuerung über MQTT:**
- Play/Pause, Vor-/Zurückspulen, Nächstes/Vorheriges Kapitel
- Nächste Episode, Lautstärke setzen, Wiedergabeposition ändern
- Wiedergabegeschwindigkeit ändern, Sleep Timer setzen/deaktivieren

**Verbindungseinstellungen:**
- MQTT-Broker (Server, Port, Benutzername, Passwort)
- Gerätename für die Topic-Struktur (z.B. `InstacastPlus/MeinIPhone/play`)
- Nur-WLAN-Modus, um mobile Daten zu schonen
- Automatische Wiederverbindung bei Verbindungsabbrüchen

> **Tipp:** Die Smart Home-Einstellungen findest du unter *Einstellungen > Smart Home*. Die Topics sind unter `InstacastPlus/{Gerätename}/...` erreichbar. Der Gerätename kann in den Einstellungen frei gewählt werden.

---

### Umfassendes Backup & Restore

Alle Daten der App können jetzt vollständig gesichert und wiederhergestellt werden.

**Export:**
- **Alle InstacastPlus-Daten:** Erstellt eine vollständige XML-Sicherung inklusive Abonnements, Wiedergabestatus, Lesezeichen, Playlists, Episodenlisten, Einstellungen und Podcast-Reihenfolge.
- **Nur Abonnements (OPML):** Exportiert die Podcast-Abonnements im Standard-OPML-Format, das von anderen Podcast-Apps gelesen werden kann.
- **Lesezeichen:** Exportiert alle Lesezeichen als separate Datei.

**Import:**
- **InstacastPlus-Backup:** Beim Import wird eine Vorschau aller enthaltenen Daten angezeigt. Du kannst einzeln auswählen, was importiert werden soll:
  - Neue Podcasts abonnieren
  - Episodenstatus aktualisieren (gehört/ungehört)
  - Podcast-Einstellungen übernehmen
  - Lesezeichen importieren
  - Als Nächstes-Warteschlange wiederherstellen
  - Aktuelle Wiedergabe fortsetzen
  - Playlists und Episodenlisten importieren
  - App-Einstellungen übernehmen
  - Podcast-Sortierung wiederherstellen
- **OPML-Import:** Abonnements aus einer OPML-Datei importieren.
- **Aus Mail oder Dateien-App:** OPML- und XML-Dateien können direkt aus der Mail-App oder der Dateien-App in InstacastPlus geöffnet werden.

> **Tipp:** Den Import/Export findest du unter *Einstellungen > Import / Export*. Erstelle regelmässig ein Backup mit "Alle InstacastPlus-Daten", um bei einem Gerätewechsel nichts zu verlieren.

---

### iCloud-Synchronisierung

Nahtlos zwischen deinen Geräten wechseln! Deine Podcasts, Einstellungen und dein Wiedergabefortschritt werden automatisch synchronisiert.

- **Abonnements:** Neuen Podcast auf dem iPhone abonniert? Erscheint sofort auf dem iPad.
- **Wiedergabefortschritt:** Auf dem iPhone angefangen, auf dem iPad weitergehört -- genau da, wo du aufgehört hast.
- **Listen & Playlists:** Deine manuellen Playlists, smarten Playlists und Episodenlisten werden auf allen Geräten synchron gehalten -- inklusive Filtereinstellungen und Episoden-Reihenfolge.
- **Play Next:** Deine Warteschlange wird automatisch übertragen, damit du auf jedem Gerät nahtlos weiterhören kannst.
- **Einstellungen:** Podcast-Einstellungen, App-Einstellungen und mehr werden übernommen.
- **In Echtzeit:** Änderungen werden sofort an deine anderen Geräte übertragen.

> **Tipp:** Die iCloud-Einstellungen findest du unter *Einstellungen > iCloud Sync*. Dort kannst du einzeln auswählen, welche Daten synchronisiert werden sollen -- darunter auch die neuen Optionen "Listen" und "Play Next".

---

### Podcast-Aktualisierung pausieren

Du kannst einzelne Podcasts von der Aktualisierung ausschliessen. Praktisch für Podcasts, die du behalten aber gerade nicht aktiv hören möchtest. Die Einstellung wird auch im Backup gesichert und über iCloud synchronisiert.

> **Tipp:** Die Option findest du in den Einstellungen des jeweiligen Podcasts unter "Synchronisieren pausieren".

---

### App zurücksetzen

Die App kann jetzt vollständig auf den Werkszustand zurückgesetzt werden. Dabei werden alle Daten, heruntergeladene Dateien und Einstellungen gelöscht.

> **Tipp:** Die Reset-Funktion findest du unter *Einstellungen > Import / Export > App zurücksetzen*.

---

### Spendenseite

InstacastPlus kann jetzt direkt in der App durch Spenden unterstützt werden. Vier Beträge stehen zur Auswahl: $1, $5, $15 und $20.

> **Tipp:** Die Spendenseite findest du im Seitenmenü unter "Donate for further development".

---

### Onboarding-Bildschirm

Beim ersten Start der App wird jetzt ein Willkommensbildschirm mit drei Seiten angezeigt, der die wichtigsten Funktionen vorstellt:
- Podcast-Sammlungen entdecken
- Wiedergabesteuerung nutzen (Warteschlange, Geschwindigkeit, Sleep Timer)
- Offline hören und nahtlos weiterhören

---

### Changelog-Ansicht

Eine neue Changelog-Ansicht zeigt alle Neuerungen der aktuellen Version übersichtlich an.

---

## Design & Darstellung

### Neues Einstellungsmenü

Das Einstellungsmenü wurde komplett neu strukturiert. Statt einer langen Liste gibt es jetzt übersichtliche Unterbereiche:

| Bereich | Inhalt |
|---------|--------|
| **Darstellung** | Erscheinungsbild (Hell/Dunkel/Automatisch), Farben, App-Icons, Interface-Sounds, externer Browser |
| **Wiedergabe** | Zurück-/Vorspulen, Geschwindigkeit, Systemsteuerung, Auto-Lock |
| **Sleep Timer** | Timer immer aktiv, intelligente Wach-Erkennung |
| **Daten** | Mobile Daten, Speicherlimit, Auto-Download, Auto-Löschen, Statistiken |
| **Import / Export** | Alle Daten exportieren/importieren, OPML, Lesezeichen, App zurücksetzen |
| **iCloud Sync** | Synchronisierung von Abonnements, Einstellungen und Wiedergabestatus |
| **Smart Home** | MQTT-Verbindung und Fernsteuerung |

### Dark Mode

- **Drei Modi:** Automatisch (folgt dem System), Hell und Dunkel -- frei wählbar in den Darstellungseinstellungen.
- Der alte standortbasierte Nachtmodus (Sonnenauf-/untergang) wurde entfernt und durch den systembasierten Dark Mode ersetzt.

### Eigene Farben

- **Interface-Farbe:** Die Akzentfarbe der App kann individuell per Hex-Code oder Farbwähler festgelegt werden.
- **Player-Farbe:** Wahlweise automatisch passend zum Podcast-Artwork oder als eigene Farbe wählbar.

> **Tipp:** Die Farbeinstellungen findest du unter *Einstellungen > Darstellung > Interface-Farbe* und *Player-Farbe*.

### Mehrere App-Icons

Sieben verschiedene App-Icons stehen zur Auswahl, darunter auch eine Dark-Mode-Variante. Eigene Icon-Vorschläge können per E-Mail eingereicht werden.

> **Tipp:** App-Icons ändern unter *Einstellungen > Darstellung > App Icon*.

### Wischbare Kapitelbilder

Im Player können Kapitelbilder jetzt durch Wischen durchgeblättert werden. So lässt sich die Artwork eines vergangenen oder kommenden Kapitels ansehen, ohne die Wiedergabeposition zu ändern.

### Kapitelmarkierungen in der Seekbar

Die Seekbar (Fortschrittsbalken) im Player zeigt jetzt vertikale Markierungen an den Kapitelgrenzen an. Das aktuell spielende Kapitel wird zusätzlich hervorgehoben.

### Kapitelname im Player

Unterhalb der Seekbar wird jetzt der Name des aktuellen Kapitels angezeigt.

### WebView als modaler Dialog

Shownotes und der interne Browser werden jetzt als modaler Dialog angezeigt statt als Push-Navigation. Dies verbessert die Navigation und ermöglicht ein einfacheres Schliessen.

### Externer Browser

Links aus den Shownotes können jetzt optional in Safari oder dem Standard-Browser geöffnet werden statt im internen Browser.

> **Tipp:** Aktiviere die Option unter *Einstellungen > Darstellung > Links in externem Browser öffnen*.

### Popovers ohne Pfeile

Alle Popovers werden jetzt ohne Pfeil dargestellt für ein moderneres Erscheinungsbild.

### Verbesserte Buttons und Tap-Flächen

- Die Buttons im Player (Geschwindigkeit und Timer) sind 20% grösser als zuvor.
- Grössere Touch-Flächen für eine leichtere Bedienung.

### Schatten entfernt

Unnötige Schatten unter der Podcast- und Episodenliste wurden entfernt.

### Opake Navigation Bar

Die Player-Navigation-Bar ist nicht mehr transparent. Die Buttons im Header sind immer klar sichtbar, unabhängig vom darunterliegenden Artwork.

---

## Podcasts & Episoden

### Neue Abspiellisten im Seitenmenü

- **Favoriten:** Zeigt alle als Favorit markierten Episoden.
- **Angefangen:** Zeigt alle begonnenen, aber noch nicht fertig gehörten Episoden.

> **Tipp:** Episodenlisten können in den Listeneinstellungen zum Hauptmenü hinzugefügt werden. Öffne dazu eine Liste, tippe auf "Bearbeiten" und aktiviere "Im Hauptmenü anzeigen".

### Episodenlisten-Editor erweitert

- **Im Hauptmenü anzeigen:** Jede Episodenliste kann jetzt direkt im Seitenmenü angezeigt werden.
- **Podcast-Priorität:** Bei aktivierter Option "Nach Podcast gruppieren" werden Episoden nach der manuellen Podcast-Reihenfolge sortiert.
- **Mehr Icons:** Zusätzliche Symbole für die Kennzeichnung von Episodenlisten.

### Episoden filtern

Die Episodenliste eines Podcasts bietet jetzt Schnellfilter:
- **Alle** -- Alle Episoden
- **Ungehört** -- Noch nie abgespielt
- **Angefangen** -- Begonnen, aber nicht fertig gehört
- **Favoriten** -- Als Favorit markiert
- **Heruntergeladen** -- Offline verfügbar

### Gelöschte Episoden wiederherstellen

Versehentlich gelöschte Episoden können jetzt wiederhergestellt werden.

> **Tipp:** Die Option "Gelöschte Episoden wiederherstellen" findest du in den Einstellungen des jeweiligen Podcasts.

### Podcast-Sortierung

Podcasts in der Hauptliste können jetzt sortiert werden nach:
- **Neueste Episoden** -- Podcasts mit den neuesten Episoden zuerst
- **Manuell** -- Eigene Reihenfolge per Drag & Drop

### Relative Zeitanzeige für Aktualisierung

Die Anzeige "Zuletzt aktualisiert" zeigt jetzt relative Zeiten an:
- "gerade eben", "vor 5 Min.", "vor 3 Std.", "vor 2 Tagen"
- Während der Aktualisierung: Fortschritt wie "3/10 Podcasts aktualisiert" oder "Warte auf 'Podcastname'..."

### Anzahl Podcasts im Seitenmenü

Im Seitenmenü wird jetzt die Anzahl der abonnierten Podcasts angezeigt.

---

## Wiedergabe

### Mehr Wiedergabegeschwindigkeiten

Neue feinere Abstufungen für die Wiedergabegeschwindigkeit:
- 0.5x, **1.0x**, **1.1x**, **1.2x**, **1.3x**, 1.5x, 2x, 3x

Der Geschwindigkeits-Button im Player zeigt die aktuelle Geschwindigkeit an und wechselt bei jedem Tippen zur nächsten Stufe. Ein langer Druck setzt die Geschwindigkeit auf 1x zurück.

### "Als Nächstes" wird zu "Play Next"

Die Warteschlange wurde umbenannt und verbessert:
- **Drag & Drop:** Episoden in der Warteschlange können per Drag & Drop umsortiert werden.
- **Alle herunterladen:** Button zum Herunterladen aller Episoden in der Warteschlange.
- **Alle entfernen:** Button zum Leeren der gesamten Warteschlange.
- **Hinweis bei leerer Liste:** "Um Episoden hinzuzufügen, halte eine Episode gedrückt und wähle 'Zu Play Next hinzufügen'."

> **Tipp:** Halte in einer beliebigen Episodenliste eine Episode gedrückt und wähle "Zu Play Next hinzufügen".

### Wiedergabe nach Entsperren

Ein Bug wurde behoben, bei dem die Wiedergabe nach dem Entsperren des Geräts nicht korrekt fortgesetzt wurde.

### Automatisches Herunterladen beim Streaming

Wenn eine Episode gestreamt wird, kann sie gleichzeitig automatisch heruntergeladen werden, sodass sie danach offline verfügbar ist.

> **Tipp:** Die Option "Auto-Download beim Streamen" findest du unter *Einstellungen > Daten*.

---

## Optimierungen

### Blitzschnelle Podcast-Aktualisierung

- Bis zu 10 Podcasts werden jetzt gleichzeitig aktualisiert -- doppelt so schnell wie zuvor!
- Nicht erreichbare Podcasts blockieren nicht mehr die Aktualisierung. Die restlichen Podcasts werden einfach weiter aktualisiert, statt auf einen einzelnen hängenden Podcast zu warten.

### Transparente Fehlermeldungen

Du siehst jetzt sofort, wenn einzelne Podcasts nicht aktualisiert werden konnten. Eine übersichtliche Meldung zeigt den Podcast-Namen und den Grund an (z.B. "Nicht erreichbar", "Nicht gefunden") -- kein Rätselraten mehr.

### Verbesserter Lautstärkeregler

Der Lautstärkeregler im Player reagiert jetzt viel präziser. Versehentliche Berührungen beim Wischen gehören der Vergangenheit an, gleichzeitig ist der Regler leicht zu greifen.

### Hintergrund-Laden von Episoden

Bei Podcasts mit vielen Episoden werden die neuesten Episoden sofort angezeigt, während ältere Episoden im Hintergrund geladen werden. Der Fortschritt wird angezeigt, und bei einem App-Neustart wird das Laden automatisch fortgesetzt.

### Schnellerer App-Start

Die App startet jetzt spürbar schneller.

### Flüssigeres Erlebnis

Podcast-Listen, der Player und die Einstellungen reagieren jetzt spürbar schneller. Aufwendige Berechnungen wie Speicherplatz-Anzeigen oder Feed-Aktualisierungen laufen im Hintergrund, damit die Oberfläche nicht ins Stocken gerät -- auch bei grossen Podcast-Sammlungen.

### Download-Optimierungen

- Verbessertes Caching-Verhalten
- Speicherlimit standardmässig auf "Kein Limit" gesetzt (vorher 1 GB)
- Mobilfunk-Downloads standardmässig aktiviert
- Auto-Löschen nach Wiedergabe und nach "Als gespielt markieren" standardmässig aktiviert

### Datenaustausch neu gedacht

Die alte Instacast Cloud wurde durch die neue, schnellere iCloud-Synchronisierung ersetzt. Für den manuellen Datenaustausch steht zusätzlich die Backup/Restore-Funktion zur Verfügung.

---

## Bugfixes

### Smart Home
- Smart Home-Verbindung noch stabiler und zuverlässiger
- Wechsel zwischen WLAN und Mobilfunk funktioniert jetzt reibungslos
- Schnellere automatische Wiederverbindung
- Effizientere Status-Updates: Daten werden nur noch gesendet, wenn sich tatsächlich etwas geändert hat

### Wiedergabe
- Wiedergabe nach dem Entsperren des Geräts funktioniert jetzt zuverlässig
- Kapitelbilder werden korrekt angezeigt und aktualisiert
- Kapitel-Überspringen funktioniert jetzt optimiert und verhindert Endlosschleifen
- Player-Rotation im Vollbildmodus korrigiert
- Stilles Auto-Play bei Pause behoben
- Wiedergabeposition wird jetzt korrekt übernommen wenn eine Episode aus der Liste gestartet wird

### Downloads
- Doppelte Downloads bei gleichzeitigem Streaming und Auto-Download behoben
- Import grosser Dateien blockiert die App nicht mehr
- Export-Fehler behoben

### Oberfläche
- Schatten unter Podcast- und Episodenliste entfernt
- Grauer Hintergrund in Shownotes wiederhergestellt
- Navigation-Bar-Buttons sind nicht mehr transparent
- Episodenlisten-Editor: Menübutton-Fix
- Darstellungsfehler im Dark Mode behoben

### Abonnements
- Abonnieren und Löschen von Podcasts funktioniert jetzt zuverlässig
- Smart Home-Verbindungsprobleme behoben
- OPML-Import erkennt Duplikate und überspringt bereits abonnierte Podcasts

---

## Lokalisierung

- Alle neuen Texte sind sowohl auf **Deutsch** als auch auf **Englisch** verfügbar.
- Verbesserte Übersetzungen für bestehende Texte.
- "Cellular Data (EDGE, 3G, LTE)" vereinfacht zu "Mobilfunkdaten".
- "Instacast Cloud"-Referenzen entfernt und durch "InstacastPlus" ersetzt.

---

## Statistiken

In den Dateneinstellungen werden jetzt Nutzungsstatistiken angezeigt:
- Anzahl Abonnements
- Gesamtzahl Episoden
- Ungehörte Episoden
- Heruntergeladene Episoden
- Belegter Speicherplatz

> **Tipp:** Die Statistiken findest du unter *Einstellungen > Daten* am Ende der Seite.

---

## Plattform-Unterstützung

### iPad-Unterstützung (Basis)
Grundlegende iPad-Unterstützung mit angepasstem Layout.

### macOS-Unterstützung (Basis)
Erste Mac-Version über Mac Catalyst mit eigener Fensterverwaltung.

---

*InstacastPlus v2.9*
