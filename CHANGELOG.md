# Was ist neu in InstacastPlus 2.9

Alle Neuerungen, Verbesserungen und Fehlerbehebungen im Vergleich zur Vorgängerversion.

---

## Smarter Listening

### Transkripte im Player

Wenn ein Podcast Transkripte bereitstellt, wird der gesprochene Text live im Player angezeigt -- synchron zur Wiedergabe. Nicht jeder Podcast unterstützt Transkripte; der Transkript-Button erscheint nur, wenn der Podcast diese Daten liefert.

- **Live-Mitlesen:** Der aktuelle Satz wird hervorgehoben und scrollt automatisch mit.
- **Tippen zum Springen:** Tippe auf eine beliebige Textstelle, um direkt dorthin zu springen.
- **Rückwärts-Springen:** Auch beim Zurückspulen scrollt das Transkript sofort an die richtige Stelle.
- **Auto-Follow:** Nach manuellem Scrollen setzt das automatische Mitscrollen nach kurzer Pause wieder ein.
- **Zustand merken:** Wenn du das Transkript sichtbar hast, bleibt es auch beim Episodenwechsel sichtbar.

---

### Intelligenter Schlaf-Timer

Der Sleep Timer wurde komplett überarbeitet und erkennt jetzt, ob du noch wach bist.

- **Immer-aktiv-Modus:** Der Sleep Timer kann bei jeder Wiedergabe automatisch starten.
- **Wach-Erkennung:** Der Timer setzt sich automatisch zurück, wenn er Aktivität erkennt:
  - **Bildschirmberührung** -- Jede Interaktion mit dem Display.
  - **Lautstärketasten** -- Drücken der Lautstärketasten.
  - **Gerätebewegung** -- Bewegungen über den Beschleunigungssensor. Tipp: Gerät auf die Matratze legen.
- **Einstellbarer Bewegungsschwellwert:** Die Empfindlichkeit der Bewegungserkennung über +/- Buttons anpassen.
- **Live-Feedback:** Die Schwellwert-Zeile in den Einstellungen blitzt auf, wenn Bewegung erkannt wird.
- **Timer-Optionen:** 3, 5, 10, 20, 30 oder 60 Minuten.
- **Schnell deaktivieren:** Langer Druck auf den Timer-Button.
- **Verbleibende Zeit:** Der Timer-Button zeigt die verbleibende Zeit im Format MM:SS.
- **CarPlay-Ausnahme:** Der Sleep Timer kann bei aktiver CarPlay-Verbindung automatisch pausieren.

> *Einstellungen > Sleep Timer*

---

### Automatisches Kapitel-Überspringen

- **Kapitel nach Stichwort überspringen:** Schlüsselwörter definieren (z.B. "Intro", "Sponsor"), passende Kapitel werden automatisch übersprungen.
- **Start-/End-Offsets:** Pro Stichwort einstellbar für Feinabstimmung.
- **Intro/Outro überspringen:** Feste Anzahl Sekunden am Anfang oder Ende jeder Episode.
- **Pro Podcast konfigurierbar:** Jeder Podcast kann eigene Skip-Regeln haben.

> *Podcast-Einstellungen > Auto Skip*

---

## Überarbeiteter Player

### Now-Playing-Bereich

- **Grösserer Play-Button** und grössere Touch-Flächen.
- **Kapitelname** unterhalb der Seekbar.
- **Vergrösserte Seekbar** und Zeit-Labels, besser ablesbar.
- **Scrubbing:** Tippen oder ziehen an beliebiger Stelle der Seekbar.
- **Podcast-Titel antippen:** Springt direkt zur Episodenliste des Podcasts.

### Kapitelmarkierungen in der Seekbar

Vertikale Markierungen an den Kapitelgrenzen. Das aktuelle Kapitel wird hervorgehoben.

### Wischbare Kapitelbilder

Kapitelbilder durch Wischen durchblättern, ohne die Wiedergabeposition zu ändern.

---

## Auf allen Geräten

### Widgets

Home- und Sperrbildschirm-Widgets:

- **Now Playing Widget:** Aktuelle Episode mit Fortschritt und Play/Pause-Steuerung.
- **Smart List Widget:** Konfigurierbare Episodenliste (Play Next, Ungehört etc.).
- **Statistik-Widget:** Hörstatistiken auf einen Blick.
- **Sperrbildschirm-Widgets:** Kreisförmig (Play/Pause mit Fortschrittsring), rechteckig (Episoden-Info) und inline (Titel).
- **Widget-Farbe:** Separat einstellbar oder von der Interface-Farbe übernommen.

> *Einstellungen > Darstellung > Widget-Farbe*

### Backup & Restore

Vollständiger Export aller Abonnements, Einstellungen, Playlists, Wiedergabestatus und Zugangsdaten für passwortgeschützte Feeds. Auch als OPML oder nur Lesezeichen exportierbar.

Import mit Live-Fortschritt (Status pro Podcast, Gesamtbalken, Restzeit), einzelne Podcasts überspringbar. Jede Datenkategorie einzeln wählbar: Abonnements, Episodenstatus, Einstellungen, Lesezeichen, Warteschlange, Playlists, Sortierung, Downloads.

OPML- und XML-Dateien können direkt aus der Mail-App oder der Dateien-App geöffnet werden.

> *Einstellungen > Import / Export*

### CarPlay

Volle CarPlay-Unterstützung mit Podcast-Liste, Episodenauswahl und Wiedergabesteuerung.

### iPad & macOS

Eigene Layouts für iPad und Mac. Optimiert für iOS 26 Liquid Glass.

---

## Podcast-Verwaltung

### Podcast-Charts

Apple Podcast Charts im Verzeichnis, filterbar nach Genre. URL-Eingabe direkt in der Suchleiste.

### Episoden filtern

Schnellfilter in der Episodenliste: Alle, Ungehört, Angefangen, Favoriten, Heruntergeladen.

### Episoden-Aufbewahrung

Pro Podcast einstellbar:
- **Nach Tagen löschen:** Ungespielte Episoden nach 1, 2, 3, 5, 7, 10, 20 oder 30 Tagen entfernen.
- **Nur neueste behalten:** Nur die neuesten 1--12 Episoden behalten, ältere werden automatisch entfernt.

> *Podcast-Einstellungen > Inhalte automatisch löschen*

### Aktualisierung pausieren

Einzelne Podcasts vorübergehend von der Aktualisierung ausschliessen. Wird auch im Backup gesichert.

> *Podcast-Einstellungen > Synchronisieren pausieren*

### Gelöschte Episoden wiederherstellen

Versehentlich gelöschte Episoden können in den Podcast-Einstellungen zurückgeholt werden.

### Download-Verwaltung

Alle Downloads sortiert nach Grösse, Datum oder Podcast anzeigen. Einzeln oder pro Podcast löschbar.

> *Einstellungen > Daten > Heruntergeladene Episoden*

### Podcast-Sortierung

Podcasts sortierbar nach neuesten Episoden oder manuell per Drag & Drop.

### Anzahl Podcasts im Seitenmenü

Die Anzahl der abonnierten Podcasts wird im Seitenmenü angezeigt.

---

## Verbesserungen

### Konfigurierbare Wisch-Aktionen

Wischen nach rechts und links auf Episoden individuell belegbar: als gehört markieren, Favorit, Download, zu Play Next, löschen oder Info anzeigen.

> *Einstellungen > Darstellung > Swipe Rechts / Swipe Links*

### Tippen auf Episode konfigurierbar

Wählen, ob Tippen auf eine Episode diese direkt abspielt oder die Shownotes öffnet.

> *Einstellungen > Wiedergabe > Tippen auf Episode*

### Kontextmenüs

Langes Drücken auf Episoden zeigt ein Kontextmenü mit Vorschau. Verfügbar in Episodenlisten, Podcast-Episoden, Play Next und Lesezeichen. Inkl. als gehört/ungehört markieren.

### Einstellbare Schriftgrösse

Vier Stufen: Normal, Grösser, Noch grösser, Am grössten. Gilt für die gesamte App.

> *Einstellungen > Darstellung > Schriftgrösse*

### Schnellere Aktualisierung

Mehrere Podcasts werden gleichzeitig aktualisiert. Nicht erreichbare Podcasts blockieren die anderen nicht mehr. Klare Timeout-Meldungen bei Verbindungsproblemen.

### Relative Zeitanzeige

"Zuletzt aktualisiert" zeigt relative Zeiten: "gerade eben", "vor 5 Min.", "vor 3 Std.". Während der Aktualisierung: Fortschritt wie "3/10 Podcasts aktualisiert".

### Scroll-Position merken

Die Position wird beim Verlassen langer Episodenlisten gespeichert.

### Schnellerer App-Start

Spürbar schnellerer Start und flüssigere Bedienung. Aufwendige Berechnungen laufen im Hintergrund.

### Verbesserter Lautstärkeregler

Präzisere Bedienung, weniger versehentliche Berührungen.

### Verbessertes Teilen

Beim Teilen von Podcasts und Episoden zeigt die Share-Ansicht eine Vorschau mit Titel und Bild.

---

## Personalisierung

### Eigene Farben

Interface-Akzentfarbe per Hex-Code oder Farbwähler. Player-Farbe passt sich dem Podcast-Artwork an oder kann manuell gesetzt werden.

> *Einstellungen > Darstellung > Interface-Farbe / Player-Farbe*

### App-Icons

Sieben Icons zur Auswahl, inkl. Dark-Mode-Variante. Eigene Vorschläge per E-Mail möglich.

> *Einstellungen > Darstellung > App Icon*

### Wiedergabegeschwindigkeiten

Verfügbar: 0.5x, 0.75x, 1.0x, 1.1x, 1.2x, 1.25x, 1.3x, 1.5x, 2x, 3x. Festlegen, welche Stufen im Player erscheinen. Langer Druck auf den Geschwindigkeits-Button setzt auf 1x zurück. Einstellungen pro Podcast überschreibbar.

> *Einstellungen > Wiedergabe > Aktivierte Geschwindigkeitsstufen*

### Dark Mode

Automatisch (System), Hell oder Dunkel. Pure-Black-Modus für OLED-Displays. Der alte standortbasierte Nachtmodus wurde entfernt.

### Externer Browser

Shownote-Links optional in Safari oder dem Standard-Browser öffnen.

> *Einstellungen > Darstellung > Links in externem Browser öffnen*

---

## Wiedergabe

### Play Next

- **Drag & Drop** zum Umsortieren.
- **Alle herunterladen / Alle entfernen.**
- **Aus Play Next entfernen** in Kontextmenüs und Wisch-Aktionen.

### Auto-Download beim Streaming

Gestreamte Episoden können gleichzeitig automatisch heruntergeladen werden.

> *Einstellungen > Daten > Auto-Download beim Streamen*

### Neue Abspiellisten im Seitenmenü

Favoriten und Angefangen als eigene Listen. Episodenlisten können zum Hauptmenü hinzugefügt werden.

---

## Smart Home

### MQTT-Integration

Wiedergabestatus, Kapitel, Sleep Timer, Lautstärke und Gerätestatus an deinen MQTT-Broker senden. Fernsteuerung über MQTT: Play/Pause, Skip, Lautstärke, Geschwindigkeit, Sleep Timer. Nur-WLAN-Modus verfügbar.

> *Einstellungen > Smart Home*

---

## Design

### iOS 26 Liquid Glass

Popup-Menüs, Kontextmenüs und Toolbar-Buttons nutzen auf iOS 26 Liquid-Glass-Styling.

### Neues Einstellungsmenü

Übersichtliche Unterbereiche: Darstellung, Wiedergabe, Sleep Timer, Daten, Import/Export, Smart Home.

### WebView als modaler Dialog

Shownotes und interner Browser als modaler Dialog statt Push-Navigation.

### Popovers ohne Pfeile

Moderneres Erscheinungsbild ohne Pfeil.

### Schatten entfernt

Unnötige Schatten unter Podcast- und Episodenliste entfernt.

### Opake Navigation Bar

Player-Header-Buttons immer sichtbar, unabhängig vom Artwork.

---

## Sonstiges

### Onboarding

Willkommensbildschirm beim ersten Start mit Vorstellung der wichtigsten Funktionen.

### Changelog-Ansicht

Alle Neuerungen übersichtlich im Einstellungsmenü einsehbar.

### App zurücksetzen

Alle Daten, Downloads und Einstellungen löschen.

> *Einstellungen > Import / Export > App zurücksetzen*

### Statistiken

Abonnements, Episoden, gehörte Zeit, Speicherplatz, Sleep-Timer-Nutzung und Spendenhistorie.

> *Einstellungen > Daten*

### Spenden

In-App-Spenden, Spendenhistorie, App Store Bewertung.

> *Einstellungen > InstacastPlus unterstützen*

### Download-Optimierungen

- Speicherlimit standardmässig auf "Kein Limit"
- Mobilfunk-Downloads standardmässig aktiviert
- Auto-Löschen nach Wiedergabe und nach "Als gespielt markieren" standardmässig aktiviert

---

## Bugfixes

### Smart Home
- Stabilere Verbindung, zuverlässiger Wechsel zwischen WLAN und Mobilfunk
- Schnellere Wiederverbindung, Status-Updates nur bei Änderungen

### Wiedergabe
- Wiedergabe nach Entsperren funktioniert zuverlässig
- Kapitelbilder korrekt angezeigt
- Kapitel-Überspringen ohne Endlosschleifen
- Player-Rotation im Vollbildmodus korrigiert
- Stilles Auto-Play bei Pause behoben

### Downloads
- Doppelte Downloads bei gleichzeitigem Streaming behoben
- Import grosser Dateien blockiert nicht mehr
- Export-Fehler behoben

### Oberfläche
- Podcast-Einstellungen-Indikator zeigt wieder korrekt an, welche Podcasts individuelle Einstellungen haben
- Grauer Hintergrund in Shownotes wiederhergestellt
- Episodenlisten-Editor: Menübutton-Fix
- Darstellungsfehler im Dark Mode behoben
- CarPlay: Markierungs-Flackern behoben

### Abonnements
- Abonnieren und Löschen von Podcasts funktioniert zuverlässig
- OPML-Import erkennt Duplikate und funktioniert bei grossen Dateien

### Stabilität
- Memory-Leaks behoben (Timer-Retain-Cycles, Observer ohne Cleanup)
- Core-Data-Threading korrigiert
- Singleton-Initialisierung abgesichert

---

## Lokalisierung

- Alle Texte auf Deutsch und Englisch verfügbar.
- "Instacast Cloud"-Referenzen durch "InstacastPlus" ersetzt.
- Tippfehler korrigiert.
