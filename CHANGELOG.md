# Was ist neu in InstacastPlus 2.9

Alle Neuerungen, Verbesserungen und Fehlerbehebungen im Vergleich zur Vorgängerversion.

---

## Neue Features

### Transkripte im Player

Podcasts mit Transkripten zeigen den gesprochenen Text live im Player an -- synchron zur Wiedergabe.

- **Live-Mitlesen:** Der aktuelle Satz wird hervorgehoben und scrollt automatisch mit.
- **Tippen zum Springen:** Tippe auf eine beliebige Textstelle, um direkt dorthin zu springen.
- **Rückwärts-Springen:** Auch beim Zurückspulen scrollt das Transkript sofort an die richtige Stelle.
- **Auto-Follow:** Nach manuellem Scrollen setzt das automatische Mitscrollen nach kurzer Pause wieder ein.
- **Zustand merken:** Wenn du das Transkript sichtbar hast, bleibt es auch beim Episodenwechsel sichtbar.

> **Tipp:** Der Transkript-Button erscheint automatisch im Player, wenn der Podcast ein Transkript bereitstellt.

---

### Intelligenter Schlaf-Timer

Der Sleep Timer wurde komplett überarbeitet und bietet jetzt eine intelligente Erkennung, ob du noch wach bist.

- **Immer-aktiv-Modus:** Der Sleep Timer kann so eingestellt werden, dass er bei jeder Wiedergabe automatisch startet. So wird verhindert, dass Podcasts versehentlich die ganze Nacht durchlaufen.
- **Intelligente Wach-Erkennung:** Der Timer setzt sich automatisch zurück, wenn er erkennt, dass du noch wach bist. Dafür stehen drei Sensoren zur Verfügung:
  - **Bildschirmberührung** -- Jede Interaktion mit dem Display setzt den Timer zurück.
  - **Lautstärkeänderung** -- Drücken der Lautstärketasten signalisiert, dass du noch zuhörst.
  - **Gerätebewegung** -- Bewegungen des Geräts (z.B. Umdrehen im Bett) werden erkannt. Tipp: Lege das Gerät auf die Matratze, um Bewegungen vor dem Einschlafen besser zu erkennen.
- **Live-Feedback:** Die Schwellwert-Zeile in den Einstellungen blitzt auf, wenn Bewegung erkannt wird -- so siehst du sofort, ob die Empfindlichkeit passt.
- **Timer-Optionen:** 3, 5, 10, 20, 30 oder 60 Minuten.
- **Schnell deaktivieren:** Langer Druck auf den Timer-Button deaktiviert den Timer sofort.
- **Verbleibende Zeit im Player:** Der Timer-Button zeigt die verbleibende Zeit im Format MM:SS direkt im Player an.

> **Tipp:** Die Einstellungen für den intelligenten Schlaf-Timer findest du unter *Einstellungen > Sleep Timer*. Aktiviere dort "Sleep Timer immer aktiv", damit der Timer bei jeder Wiedergabe automatisch startet.

---

### Automatisches Kapitel-Überspringen

Intros, Werbung oder wiederkehrende Segmente können jetzt automatisch übersprungen werden.

- **Kapitel nach Stichwort überspringen:** Definiere Schlüsselwörter (z.B. "Intro", "Werbung", "Sponsor"), und alle Kapitel, die diese Wörter im Titel enthalten, werden automatisch übersprungen.
- **Feintuning mit Offsets:** Start- und End-Offsets pro Stichwort erlauben es, z.B. die ersten 2 Sekunden noch abzuspielen oder 2 Sekunden früher zu überspringen.
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
- **Flimmerfrei:** Die Markierung der aktuell spielenden Episode wird ohne störendes Flackern aktualisiert.

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
- Zuverlässige WLAN-Erkennung: Verbindung wird korrekt aufgebaut und getrennt beim Wechsel zwischen WLAN und Mobilfunk

> **Tipp:** Die Smart Home-Einstellungen findest du unter *Einstellungen > Smart Home*. Die Topics sind unter `InstacastPlus/{Gerätename}/...` erreichbar.

---

### Umfassendes Backup & Restore

Alle Daten der App können jetzt vollständig gesichert und wiederhergestellt werden.

**Export:**
- **Alle InstacastPlus-Daten:** Erstellt eine vollständige XML-Sicherung inklusive Abonnements, Wiedergabestatus, Lesezeichen, Playlists, Episodenlisten, Einstellungen, Podcast-Reihenfolge und Login-Daten für passwortgeschützte Feeds.
- **Nur Abonnements (OPML):** Exportiert die Podcast-Abonnements im Standard-OPML-Format, das von anderen Podcast-Apps gelesen werden kann.
- **Lesezeichen:** Exportiert alle Lesezeichen als separate Datei.

**Import mit Live-Fortschrittsanzeige:**
- **4-Phasen-Import:** Der neue Import-Dialog zeigt den Fortschritt in Echtzeit -- mit Status pro Podcast (Spinner, Häkchen, Fehler), Gesamt-Fortschrittsbalken, Laufzeit und geschätzter Restzeit.
- **Einzelne Podcasts überspringen:** Wenn ein Podcast beim Import hängt, kann er einzeln übersprungen werden, ohne den ganzen Import abzubrechen.
- **Selektiver Import:** Beim Import wird eine Vorschau aller enthaltenen Daten angezeigt. Du kannst einzeln auswählen, was importiert werden soll:
  - Neue Podcasts abonnieren
  - Episodenstatus aktualisieren (gehört/ungehört)
  - Podcast-Einstellungen übernehmen (inkl. Login-Daten)
  - Lesezeichen importieren
  - Als Nächstes-Warteschlange wiederherstellen
  - Aktuelle Wiedergabe fortsetzen
  - Playlists und Episodenlisten importieren
  - App-Einstellungen übernehmen
  - Podcast-Sortierung wiederherstellen
  - Heruntergeladene Episoden erneut laden
- **OPML-Import:** Abonnements aus einer OPML-Datei importieren -- auch mit sehr grossen Dateien zuverlässig.
- **Aus Mail oder Dateien-App:** OPML- und XML-Dateien können direkt aus der Mail-App oder der Dateien-App in InstacastPlus geöffnet werden.

> **Tipp:** Den Import/Export findest du unter *Einstellungen > Import / Export*. Erstelle regelmässig ein Backup mit "Alle InstacastPlus-Daten", um bei einem Gerätewechsel nichts zu verlieren.

---

### Podcast-Aktualisierung pausieren

Du kannst einzelne Podcasts von der Aktualisierung ausschliessen. Praktisch für Podcasts, die du behalten aber gerade nicht aktiv hören möchtest. Die Einstellung wird auch im Backup gesichert.

> **Tipp:** Die Option findest du in den Einstellungen des jeweiligen Podcasts unter "Synchronisieren pausieren".

---

### Podcast-Verzeichnis mit Charts & Genre-Filter

Das Podcast-Verzeichnis zeigt jetzt die aktuellen Apple Podcast Charts mit Genre-Filter.

- **Top-Charts:** Die beliebtesten Podcasts aus den Apple Charts, automatisch aktualisiert.
- **Genre-Filter:** Filtere die Charts nach Kategorien wie True Crime, Nachrichten, Comedy, Bildung und vielen mehr.
- **Schneller Zugriff:** Charts werden im Cache gespeichert und beim nächsten Öffnen sofort angezeigt.
- **URL-Eingabe:** Podcast-URLs können direkt in die Suchleiste eingefügt werden -- praktisch zum schnellen Abonnieren.

---

### Spenden & Unterstützung

Eine neue Spendenseite ermöglicht es, die Weiterentwicklung von InstacastPlus direkt zu unterstützen.

- **In-App-Spenden:** Vier Spendenbeträge zur Auswahl über Apple In-App Purchase.
- **Spendenhistorie:** Übersicht aller bisherigen Spenden.
- **App Store Bewertung:** Direkter Link zur App Store Bewertung.
- **Podcast-Empfehlung:** Höre rein in einen Podcast über die Entwicklung von InstacastPlus.

> **Tipp:** Die Spendenseite findest du unter *Einstellungen > InstacastPlus unterstützen*.

---

### App zurücksetzen

Die App kann jetzt vollständig auf den Werkszustand zurückgesetzt werden. Dabei werden alle Daten, heruntergeladene Dateien und Einstellungen gelöscht.

> **Tipp:** Die Reset-Funktion findest du unter *Einstellungen > Import / Export > App zurücksetzen*.

---

### Onboarding-Bildschirm

Beim ersten Start der App wird jetzt ein Willkommensbildschirm mit drei Seiten angezeigt, der die wichtigsten Funktionen vorstellt:
- Podcast-Sammlungen entdecken
- Wiedergabesteuerung nutzen (Warteschlange, Geschwindigkeit, Sleep Timer)
- Offline hören und nahtlos weiterhören

---

### Changelog-Ansicht

Eine neue Changelog-Ansicht zeigt alle Neuerungen der aktuellen Version übersichtlich an -- beim ersten Start nach dem Update und jederzeit in den Einstellungen.

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

### Überarbeiteter Now-Playing-Bereich

- **Grösserer Play-Button:** Der Play/Pause-Button ist jetzt deutlich grösser und leichter zu treffen.
- **Kapitelname:** Unterhalb der Seekbar wird der Name des aktuellen Kapitels angezeigt.
- **Seekbar vergrössert:** Die Seekbar und die Zeit-Labels sind grösser und besser ablesbar.
- **Scrubbing:** Die Seekbar unterstützt jetzt direktes Scrubbing -- einfach an eine beliebige Stelle tippen oder ziehen, um dorthin zu springen.

### Kapitelmarkierungen in der Seekbar

Die Seekbar zeigt jetzt vertikale Markierungen an den Kapitelgrenzen an. Das aktuell spielende Kapitel wird zusätzlich hervorgehoben.

### iOS 26 Optimierungen

Die App wurde für iOS 26 optimiert und nutzt das neue Liquid Glass Design. iPad-Layout verbessert und an iOS 26 angepasst.

### WebView als modaler Dialog

Shownotes und der interne Browser werden jetzt als modaler Dialog angezeigt statt als Push-Navigation. Dies verbessert die Navigation und ermöglicht ein einfacheres Schliessen.

### Externer Browser

Links aus den Shownotes können jetzt optional in Safari oder dem Standard-Browser geöffnet werden statt im internen Browser.

> **Tipp:** Aktiviere die Option unter *Einstellungen > Darstellung > Links in externem Browser öffnen*.

### Popovers ohne Pfeile

Alle Popovers werden jetzt ohne Pfeil dargestellt für ein moderneres Erscheinungsbild.

### Grössere Schriften und Buttons

- Schriften in Listen und im Player sind grösser und besser lesbar.
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

### Scroll-Position merken

Bei Podcasts mit vielen Episoden wird die Scroll-Position gespeichert. Beim Zurückkehren zur Liste bist du genau dort, wo du aufgehört hast.

### Gelöschte Episoden wiederherstellen

Versehentlich gelöschte Episoden können jetzt wiederhergestellt werden.

> **Tipp:** Die Option "Gelöschte Episoden wiederherstellen" findest du in den Einstellungen des jeweiligen Podcasts.

### Podcast-Sortierung

Podcasts in der Hauptliste können jetzt sortiert werden nach:
- **Neueste Episoden** -- Podcasts mit den neuesten Episoden zuerst
- **Manuell** -- Eigene Reihenfolge per Drag & Drop

### Episoden-Aufbewahrungsregel

Pro Podcast lässt sich jetzt festlegen, wann Episoden automatisch aufgeräumt werden:

- **Nach X Tagen löschen:** Ungespielte Episoden nach 1, 2, 3, 5, 7, 10, 20 oder 30 Tagen entfernen.
- **Nur neueste behalten:** Nur die neuesten 1--12 Episoden behalten, ältere werden automatisch entfernt.

> **Tipp:** Die Optionen findest du in den Einstellungen des jeweiligen Podcasts unter "Inhalte automatisch löschen".

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

Die Wiedergabe-Einstellungen zeigen jetzt einen Hinweis, dass sie pro Podcast überschrieben werden können.

### "Als Nächstes" wird zu "Play Next"

Die Warteschlange wurde umbenannt und verbessert:
- **Drag & Drop:** Episoden in der Warteschlange können per Drag & Drop umsortiert werden.
- **Alle herunterladen:** Button zum Herunterladen aller Episoden in der Warteschlange.
- **Alle entfernen:** Button zum Leeren der gesamten Warteschlange.
- **Hinweis bei leerer Liste:** "Um Episoden hinzuzufügen, halte eine Episode gedrückt und wähle 'Zu Play Next hinzufügen'."

> **Tipp:** Halte in einer beliebigen Episodenliste eine Episode gedrückt und wähle "Zu Play Next hinzufügen".

### Automatisches Herunterladen beim Streaming

Wenn eine Episode gestreamt wird, kann sie gleichzeitig automatisch heruntergeladen werden, sodass sie danach offline verfügbar ist.

> **Tipp:** Die Option "Auto-Download beim Streamen" findest du unter *Einstellungen > Daten*.

---

## Downloads verwalten

### Neue Download-Verwaltung

Die Download-Übersicht wurde komplett überarbeitet und bietet jetzt drei Sortiermodi:

- **Nach Grösse:** Die grössten Dateien zuerst -- ideal um Speicherplatz freizugeben.
- **Nach Datum:** Die neuesten Downloads zuerst.
- **Nach Podcast:** Downloads gruppiert nach Podcast, mit Gesamtgrösse pro Podcast und Möglichkeit, alle Downloads eines Podcasts auf einmal zu löschen.

> **Tipp:** Zum Löschen einzelner Downloads nach links swipen. Die Download-Verwaltung findest du unter *Einstellungen > Daten > Heruntergeladene Episoden*.

---

## Optimierungen

### Blitzschnelle Podcast-Aktualisierung

- Bis zu 10 Podcasts werden jetzt gleichzeitig aktualisiert -- doppelt so schnell wie zuvor!
- Nicht erreichbare Podcasts blockieren nicht mehr die Aktualisierung. Die restlichen Podcasts werden einfach weiter aktualisiert, statt auf einen einzelnen hängenden Podcast zu warten.
- **Pull to Refresh:** Wird jetzt asynchron ausgeführt, die Oberfläche bleibt auch während der Aktualisierung flüssig bedienbar.

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

Für den manuellen Datenaustausch steht eine Backup/Restore-Funktion zur Verfügung.

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
- CarPlay: Markierungs-Flackern der aktuell spielenden Episode behoben

### Abonnements
- Abonnieren und Löschen von Podcasts funktioniert jetzt zuverlässig
- OPML-Import erkennt Duplikate und überspringt bereits abonnierte Podcasts
- OPML-Import funktioniert jetzt auch bei sehr grossen Dateien zuverlässig

### Stabilität
- Zahlreiche Memory-Leaks behoben (Timer-Retain-Cycles, Observer ohne Cleanup)
- Core-Data-Threading korrigiert: kein Absturz mehr bei gleichzeitigem Parsen und Importieren
- Singleton-Initialisierung abgesichert gegen Deadlocks

---

## Statistiken

In den Dateneinstellungen werden jetzt Nutzungsstatistiken angezeigt:
- Anzahl Abonnements
- Gesamtzahl Episoden
- Ungehörte Episoden
- Heruntergeladene Episoden
- Belegter Speicherplatz
- Abgespielte Episoden (Gesamtzahl)
- Gehörte Zeit (in Stunden und Minuten)
- Mit Sleep Timer eingeschlafen (Anzahl)
- Gespendet an InstacastPlus (Gesamtbetrag)

> **Tipp:** Die Statistiken findest du unter *Einstellungen > Daten* am Ende der Seite.

---

## Lokalisierung

- Alle neuen Texte sind sowohl auf **Deutsch** als auch auf **Englisch** verfügbar.
- Verbesserte Übersetzungen für bestehende Texte.
- "Cellular Data (EDGE, 3G, LTE)" vereinfacht zu "Mobilfunkdaten".
- "Instacast Cloud"-Referenzen entfernt und durch "InstacastPlus" ersetzt.
- Tippfehler korrigiert (z.B. "unterstürtzt" -> "unterstützt", "Spingen" -> "Springen").

---

## Plattform-Unterstützung

### CarPlay
Podcasts und Listen in CarPlay anhören.

### iPad-Unterstützung
Verbessertes iPad-Layout, optimiert für iOS 26.

### macOS-Unterstützung (Basis)
Erste Mac-Version über Mac Catalyst mit eigener Fensterverwaltung.

---

## Feedback

Wir freuen uns über jedes Feedback! Wenn du Fragen, Wünsche oder Fehlerberichte hast, nutze bitte die **Feedback-Funktion in den Einstellungen**. Du findest dort den Punkt "Feedback/Frage zur App senden" -- damit erreichst du uns direkt per E-Mail.

> **Tipp:** *Einstellungen > Feedback/Frage zur App senden*
