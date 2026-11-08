# AGENTS.md

This repository uses [CLAUDE.md](./CLAUDE.md) as the primary project instruction file.
Read it before changing code. Do not duplicate or reinterpret it loosely.

## Lösungen bis zum geprüften Abschluss

Ein laufender Reparaturauftrag umfasst Diagnose, Reproduktion, Ursachenbehebung
und Prüfung des tatsächlichen Nutzerablaufs. Fragen wie „Gibt es weitere solche
Fehler oder Fehlannahmen?“ erweitern diesen Auftrag; sie machen daraus keinen
reinen Audit. Nur eine ausdrückliche Einschränkung auf Analyse oder ein
Änderungsverbot rechtfertigt, bei Befunden stehen zu bleiben.

Nicht abschließen mit „nachgewiesen, noch nicht behoben“, einer Befundliste oder
einem Angebot zur späteren Behebung, solange auftragsbezogene Korrekturen oder
notwendige Prüfungen mit vorhandener Autorisierung ausführbar sind. Das gilt auch
nach einem Teilauftrag oder delegierten Review. Skills ändern diesen Umfang nicht.
Bei langen Arbeiten den Stand sichern und weiterarbeiten. Nur konkrete, selbst
nicht behebbare Blockaden benennen und die unverzichtbare fehlende Eingabe
anfordern; unabhängige Arbeiten fortsetzen. Nachweise dienen der Lösung und
ersetzen sie nicht. Abschlussmeldungen knapp auf behobenes Verhalten, tatsächliche
Prüfung und gegebenenfalls belegte verbleibende Grenzen beschränken.

## Dranbleiben bis Lösung oder vollständigem Blockadenachweis

Keine Rückfragen stellen, nicht stoppen und die Aufgabe nicht an den Nutzer
zurückgeben, solange noch ein autorisierter Diagnose-, Reparatur- oder Prüfweg
existiert. Nach jedem Fehlschlag den belegten Stand sichern und selbstständig den
nächsten technisch sinnvollen Weg ausführen.

Vor einer Blockademeldung alle verfügbaren Werkzeuge, Logs, Datenquellen,
Schnittstellen, UI-Wege, privilegierten Wege und Alternativen tatsächlich
untersuchen. Eine Blockade ist erst belegt, wenn die konkrete externe Grenze und
der reproduzierbare Fehler dokumentiert, alle eigenständig ausführbaren Wege
ausgeschöpft und exakt die unverzichtbare fehlende Eingabe oder externe
Zustandsänderung benannt sind. Bis dahin bleibt der Auftrag aktiv.

Keine Erklärungen, Befundlisten, Pläne oder Angebote anstelle einer Lösung.
Zwischenstände kurz und handlungsbezogen halten. Kontextkomprimierung,
Toolfehler, lange Laufzeit, Komplexität und ein gescheiterter Ansatz sind keine
Abschlussgründe.

## Selbstständig prüfen statt rückfragen

Keine Rückfragen zu Dingen, die sich aus Code, App, Feed, Logs oder verfügbaren
Werkzeugen selbst feststellen lassen. Zuerst den tatsächlichen Nutzerablauf und
die vorhandenen Ansichten anschauen. Insbesondere keine erfundenen UI-Varianten
zur Auswahl stellen. Fehlende technische Details selbst untersuchen und belegte
Ergebnisse nennen; nicht den Nutzer die Untersuchung übernehmen lassen.

## Privilegierte und systemnahe Arbeiten

Vor systemnahen Reparaturen auch `/Users/prefect/.codex/MEMORY.md` lesen. Alle
vorhersehbaren Root-/Admin-Schritte vor der ersten Authentifizierung erfassen und
über eine einzige wiederverwendbare privilegierte Sitzung ausführen. Kurzlebige
Einzelprozesse dürfen keine wiederholten Passwortdialoge verursachen.

Root-Zugriff, SIP beziehungsweise Dateisystemschutz, TCC/Datenschutz,
Code-Signing-Entitlements und der zuständige Systemdienst sind getrennte
Autoritätsgrenzen. Scheitert eine Methode, ist zunächst diese Methode widerlegt,
nicht der Auftrag blockiert. Den Fehlschlag festhalten, nicht unverändert
wiederholen und den tatsächlich zuständigen Dienst oder Lebenszyklus untersuchen.
Keine sachfremden Berechtigungsdialoge über benachbarte Subsysteme auslösen.

Bei jeder Zustandsreparatur persistierte kanonische Daten, sichtbare UI und den
echten Nutzerablauf getrennt verifizieren. Caches durch gezielten Neustart der
betroffenen App oder des Dienstes erneuern. Erst abschließen, wenn alle drei
Ebenen übereinstimmen; Statusdateien und eigene Hilfsprozesse anschließend auf
den tatsächlichen Abschlussstand bringen.

## Offensichtliche Folgearbeiten selbstständig abschließen

Offensichtlich notwendige, autorisierte Folgearbeiten proaktiv erledigen,
ohne einen weiteren Auftrag abzuwarten. Dazu gehören veraltete Test-Erwartungen,
bestätigte auftragsbezogene Folgefehler und die dazugehörige Validierung. Solche
Arbeiten nicht nur als offene Punkte melden, wenn Ursache und sichere Korrektur bereits
feststehen. Das gilt auch, wenn eine veraltete Erwartung durch parallele Änderungen
entstanden ist: den aktuellen Stand prüfen, die notwendige Anpassung vornehmen
und bestehende Änderungen anderer erhalten.

Testerwartungen aus Nutzeranforderung, tatsächlichem Ablauf und gültigem
Datenvertrag ableiten. Bestehende Tests können falsche Annahmen festschreiben;
diese belegen und korrigieren. Grüne Tests allein beweisen kein korrektes
Nutzerverhalten. Assertions nicht abschwächen oder entfernen, nur um einen grünen
Lauf zu erhalten. Nach der Korrektur den betroffenen
Test und die nötigen angrenzenden Prüfungen ausführen. Bis zum überprüften Ergebnis
weiterarbeiten; keine spekulativen Umbauten oder sachfremden Aufräumarbeiten.

## Bugfix Gate

When the user reports a bug, regression, crash, flaky UI behavior, or says a previous fix did not work:

1. Do not start by patching code.
2. Establish the observed symptom, expected behavior, actual behavior, platform, and reproduction steps by inspecting the actual app, code, feeds, and available diagnostics before changing code.
3. Reproduce the bug through the actual end-to-end user flow. For UI/lifecycle bugs, use the app or simulator and retain logs, screenshots, and repeatable reproduction steps.
4. Write or extend a failing E2E test before the production fix. Confirm it fails for the intended reason. An isolated test requires the failure analysis and justification below before writing any code.
5. Only after the failing proof exists, identify the real root cause from code, logs, and lifecycle/state transitions.
6. Do not use workarounds, fallback behavior, delays, broad reloads, speculative guards, or "try this" fixes.
7. Make the smallest surgical code change that explains the failing test and the observed bug.
8. Run the exact regression test again and any nearby focused checks needed to prove the fix.
9. In the final response, state problem, root cause, fix, and validation commands.

If the bug cannot be reproduced, exhaust the available app, source, feed, and diagnostic evidence. Do not guess a fix; report the specific remaining gap and continue independently with the other requested work.

When a bug or release risk depends on external state — cloud schemas, server
configuration, permissions, App Store Connect/TestFlight state, provisioning, or
other production infrastructure — verify the real remote/production state directly
against the expected state. Do not infer it from local code, development
environments, or successful builds alone.

## Build And Test Policy

These testing rules take precedence over older testing advice in `CLAUDE.md`
and project skills, including recommendations to add source-text regression tests.

- Never write unit tests after you write code.
- Highly prefer E2E tests as the sole testing mechanism. Use them to verify complex features work. At the end of E2E tests, produce a verifiable and repeatable artifact.
- If you must test a system in isolation, first write down all the ways it could fail, then write the code.

Before adding an isolated test, name the concrete failure it detects and why the
E2E flow cannot reliably detect it. Exercise production behavior or a real
artifact contract; do not assert implementation spelling or test a copied model
of the implementation. Write the failing test before the production code.

An E2E artifact must include the exact command, inputs or fixtures, environment,
expected and observed results, and retained evidence such as logs, screenshots,
or exported data, so another person can verify and repeat the run. A build or an
isolated test passing is not an E2E result; report untested flows explicitly.

For build verification, follow `CLAUDE.md`:

- Do not run full builds automatically unless the change is large or build verification is specifically needed.
- For small changes, run focused tests or `git diff --check` as appropriate.
- Execute necessary available checks yourself. If a concrete access or environment limitation prevents verification, state it with the exact remaining commands; do not substitute suggested commands for checks you can run.

## Scope Discipline

Follow `CLAUDE.md` and keep every changed line traceable to the user request. Do not refactor adjacent code, clean up unrelated code, or revert unrelated dirty files unless the user explicitly asks.

Normal active development is expected in this repository. "Dirty" only means Git has
uncommitted changes; do not treat that as a blocker by itself. Ignore routine Xcode
workspace/user-state churn such as `*.xcuserstate` and continue editing code for the
user's task. When existing uncommitted code overlaps the requested change, read it and
work with it instead of reverting it.

## UI-Reaktivität

UI-Reaktivität hat oberste Priorität. Sync-, Abonnier- und Massen-Ladevorgänge (iCloud Sync, Feed-Hydration, Episoden-Nachladen) müssen mit niedriger Priorität asynchron im Hintergrund ausgeführt werden — die UI darf dadurch nie blockieren oder stottern, auch nicht bei 1000 Abonnements. Große Core-Data-Schreibvorgänge gehören in kleine Batches mit Pausen, nie in einen einzelnen Main-Context-Push (siehe CLAUDE.md „iCloud Sync").
