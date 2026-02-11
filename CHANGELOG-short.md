# Was ist neu in InstacastPlus 2.9

## Neue Features

- **Intelligenter Schlaf-Timer** -- Startet optional automatisch bei jeder Wiedergabe und erkennt über Bewegung, Bildschirmberührung und Lautstärketasten, ob du noch wach bist. Verbleibende Zeit wird direkt im Player angezeigt.
- **Automatisches Kapitel-Überspringen** -- Definiere Stichwörter wie "Werbung" oder "Intro", und passende Kapitel werden automatisch übersprungen. Zusätzlich Intro-/Outro-Skip in Sekunden pro Podcast einstellbar.
- **CarPlay** -- Podcasts und Episoden direkt im Auto durchsuchen und abspielen.
- **MQTT Smart Home** -- Veröffentlicht Wiedergabestatus, Kapitel, Sleep Timer, Akkustand und mehr an einen MQTT-Broker. Fernsteuerung (Play/Pause, Skip, Lautstärke, Timer) über MQTT möglich.
- **Backup & Restore** -- Vollständiger Export aller Daten (Abonnements, Wiedergabestatus, Playlists, Einstellungen) als XML. Import mit Vorschau und Einzelauswahl. OPML-Export/-Import für Kompatibilität mit anderen Apps.
- **iCloud Sync** -- Synchronisierung von Abonnements, Podcast-Einstellungen, Wiedergabestatus, aktueller Wiedergabe und App-Einstellungen über CloudKit. Echtzeit-Push an andere Geräte.
- **Podcast-Sync pausieren** -- Einzelne Podcasts können von der Aktualisierung ausgenommen werden.
- **Spenden** -- InstacastPlus direkt in der App unterstützen (4 Beträge via In-App-Kauf).

## Player & Wiedergabe

- **Kapitelmarkierungen in der Seekbar** mit Hervorhebung des aktuellen Kapitels
- **Wischbare Kapitelbilder** -- Durch Kapitelbilder blättern ohne die Position zu ändern
- **Kapitelname** wird unter der Seekbar angezeigt
- **Feinere Geschwindigkeitsstufen:** 0.5x, 1.0x, 1.1x, 1.2x, 1.3x, 1.5x, 2x, 3x
- **Play Next** -- Verbesserte Warteschlange mit Drag & Drop, Alle herunterladen/entfernen
- **Auto-Download beim Streamen** -- Episode wird beim Streamen automatisch heruntergeladen

## Podcasts & Episoden

- **Neue Listen:** Favoriten und Angefangen -- als Schnellzugriff im Seitenmenü
- **Episodenfilter:** Alle, Ungehört, Angefangen, Favoriten, Heruntergeladen
- **Gelöschte Episoden wiederherstellen** in den Podcast-Einstellungen
- **Podcast-Sortierung** nach neuesten Episoden oder manuell per Drag & Drop
- **Relative Zeitanzeigen** ("vor 5 Min.") und Live-Fortschritt beim Aktualisieren

## Design

- **Neues Einstellungsmenü** -- Übersichtlich in 7 Kategorien aufgeteilt: Darstellung, Wiedergabe, Sleep Timer, Daten, Import/Export, iCloud Sync, Smart Home
- **Dark Mode** -- Automatisch (System), Hell oder Dunkel. Ersetzt den alten standortbasierten Nachtmodus.
- **Eigene Farben** -- Interface- und Player-Farbe individuell per Hex-Code einstellbar
- **7 App-Icons** zur Auswahl inkl. Dark-Mode-Variante
- **Opake Navigation Bar** und grössere Player-Buttons

## Optimierungen

- Bis zu **10 Podcasts gleichzeitig** aktualisieren (vorher 5), mit individuellem 8s-Timeout pro Podcast
- **Fehlermeldungen nach Aktualisierung** -- Alert zeigt fehlgeschlagene Podcasts mit Grund (Timeout, Nicht gefunden, etc.)
- **Verbesserter Lautstärkeregler** -- Touches nur noch im Thumb-Bereich, keine versehentlichen Berührungen mehr
- **MQTT WiFi-Erkennung** verbessert -- Zuverlässigere Erkennung über BSD-Netzwerkinterfaces
- **Hintergrund-Laden** bei Podcasts mit vielen Episoden
- Schnellerer App-Start
- **Instacast Cloud entfernt** -- App arbeitet lokal, Backup/Restore und iCloud Sync für Datenaustausch
- **App zurücksetzen** auf Werkszustand möglich

## Plattformen

- iPad- und macOS-Unterstützung (Basis)

---

*InstacastPlus v2.9*
