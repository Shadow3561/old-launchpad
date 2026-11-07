# Old Launchpad

Eine kleine native macOS-App im Stil des früheren Launchpad. Sie zeigt installierte Programme in einem Icon-Raster, bietet eine Suche und startet Apps per Klick.

## Bauen und starten

Im Terminal im Projektordner:

```sh
./build.sh
open "build/Developer/Old Launchpad Developer.app"
```

Der Standard-Build erzeugt Entwickler- und Probeversion getrennt:

```sh
build/Developer/Old Launchpad Developer.app
build/Release/Old Launchpad.app
```

Der Entwickler-Build überspringt Lizenz- und Testprüfung. Die Probeversion enthält den 30-Tage-Test und wird mit `./build.sh --release` gebaut. Die Kaufversion enthält keinen Testzugang; sie verlangt vom ersten Start an die Aktivierung eines gekauften Lizenzschlüssels und wird separat gebaut:

```sh
./build.sh --paid
build/Paid/Old Launchpad.app
```

Entwickler- und Kaufversion haben unterschiedliche Bundle-IDs beziehungsweise Build-Ausgaben; die Probe- und Kaufversion verwenden dieselbe Produkt-Bundle-ID und dieselben Lizenzdaten. Änderungen an den gemeinsamen Swift-Quellen gelten für alle Builds. Nur notarisiert signierte Builds verteilen.

Falls die ausgewählte Xcode-Installation ihre Lizenz noch nicht bestätigt hat, kann der installierte Command Line Tools-Compiler verwendet werden:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools ./build.sh
```

Die App liest Programme aus `/Applications`, `/System/Applications` und `~/Applications`.

- Apps nur durch direkten Klick auf das Symbol starten; danach blendet sich Launchpad aus. Klicks auf freien Platz zwischen oder um Symbole schließen Launchpad, statt ein benachbartes Programm zu starten.
- Escape oder ein Klick auf einen freien Bereich blendet Launchpad ebenfalls aus. Über das App-Symbol im Dock lässt es sich wieder öffnen.
- Es kann nur eine Instanz gleichzeitig laufen. Ein weiterer Start aktiviert das bereits laufende Launchpad.
- Das Menü „Old Launchpad“ enthält „Beenden“ und „Vollbild umschalten“ (Ctrl-Cmd-F). Der Vollbildmodus ist fensterbasiert und verwendet keinen macOS-Full-Screen-Space, damit das Schließen nicht auf einem schwarzen Bildschirm endet.
- Seiten durch horizontales Wischen von rechts nach links bzw. links nach rechts wechseln oder unten einen Seitenpunkt auswählen.
- Über das Zahnrad oben rechts lassen sich Symbolgröße, Hintergrundmotiv, Hintergrund-Transparenz, Zahl der Rasterreihen und die Seitenwechsel-Animation (Schieben, Überblenden, Zoomen oder Aus) einstellen. Die Werte werden gespeichert.
- App-Symbole verwenden die originalen macOS-Icons ohne zusätzliche Filter und werden bei einer Änderung der Systemdarstellung erneut von macOS geladen.
- Beim Seitenwechsel fliegen die App-Kacheln mit der ausgewählten Animation seitlich aus dem Raster und die nächste Seite ein.
- Zum Gruppieren ein App-Symbol direkt auf das Symbol einer anderen App ziehen; die Kachelfläche allein erstellt keinen Ordner. Ein Drop am ursprünglichen Platz legt die App wieder ab, ohne sie zu gruppieren. Beim Ziehen rutschen die Apps auseinander und zeigen die Einfügeposition. Weitere Apps lassen sich auf einen Ordner ziehen.
- Ordner durch Anklicken des Namens umbenennen; per Rechtsklick lassen sie sich auch umbenennen oder auflösen. „Aus Ordner entfernen“ erscheint am Mauszeiger.
- Ordner zeigen eine gläserne Kachel mit Vorschauen der enthaltenen Apps.
- Ordner bleiben nach einem Neustart erhalten.
- Apps und Ordner lassen sich per Ziehen im Raster und über Seiten hinweg neu anordnen. Das Raster bleibt während des Ziehens das zentrale Drop-Ziel, auch wenn die Seite wechselt. Beim Ziehen zeigt ein gestrichelter Platzhalter die Einfügeposition; größere Zwischenräume erleichtern das Ablegen. Halte ein Symbol beim Ziehen etwa 0,7 Sekunden am linken oder rechten Rasterrand, wechselt die Seite automatisch weiter, solange es dort gehalten wird. Nach jedem Wechsel beginnt die Wartezeit für die nächste Seite neu. Die Reihenfolge bleibt gespeichert.
- Die Ausblend-Animation übernimmt den Dock-Effekt („Trichter“/Genie oder „Strudel“/Suck) und richtet sich nach der Position des App-Symbols im Dock. Im Vollbild läuft dieselbe Animation direkt zum Dock; der Vollbildzustand bleibt für das nächste Öffnen erhalten.
- Das App- und Dock-Symbol zeigt ein modernes Launchpad-Raster im Glasdesign. Beim Build wird das App-Bundle zusätzlich bei Launch Services registriert, damit das Dock-Symbol auch bei geschlossener App aktuell bleibt.

Die Zahl der Apps pro Seite richtet sich nach der gewählten Reihenanzahl.

## Lemon-Squeezy-Lizenzaktivierung

`Sources/LemonSqueezyLicense.swift` enthält eine native `URLSession`-Aktivierung ohne externe Pakete. Der Status wird als generisches Passwort mit `Security` im macOS-Schlüsselbund abgelegt:

```swift
let status = try await LemonSqueezyLicense.activate(
    licenseKey: licenseKey,
    email: email
)
```

Der Status kann mit `LemonSqueezyLicense.saveStatus(_:)` gespeichert und mit `try LemonSqueezyLicense.savedStatus()` ausgelesen werden. Beim Start fragt der Application Delegate den Schlüsselbund ab und zeigt bei fehlender Lizenz das native Aktivierungsfenster aus `Sources/LicenseActivationWindow.swift`.

Das Aktivierungsfenster bietet außerdem einen kostenlosen 30-Tage-Test. Beim ersten App-Start wird der Installations-/Erststartzeitpunkt einmalig im macOS-Schlüsselbund abgelegt; weitere Starts verwenden denselben Zeitpunkt, auch nach Löschen und Neuinstallation der App unter demselben macOS-Benutzerkonto. Der Testzugang wird erst durch den Button freigeschaltet, die 30 Tage werden jedoch ab dem ersten App-Start berechnet. Nach Ablauf kann der Test nicht erneut gestartet werden; im Aktivierungsfenster führt „Jetzt kaufen · 8,99 €“ direkt zum Lemon-Squeezy-Checkout.

Für den öffentlichen Probe-Download wird das notarierte Archiv `build/Release/Old-Launchpad-notarization.zip` als Asset eines GitHub Releases im Repository `Shadow3561/old-launchpad` veröffentlicht. Die Website verweist auf `releases/latest/download/Old-Launchpad-notarization.zip`.

Bei Lemon Squeezy muss die separat gebaute und notarisiert signierte Kaufversion aus `build/Paid/Old-Launchpad-purchase.zip` hinterlegt werden. Sie startet ohne Probezeitraum und verlangt direkt die Lizenzaktivierung. Das GitHub-Release-Archiv ist die Probeversion und darf nicht als Kauf-Download verwendet werden.

Lemon Squeezy erwartet am Aktivierungs-Endpunkt `license_key` und `instance_name`; die E-Mail-Adresse wird von der API als `meta.customer_email` zurückgegeben. Die Funktion vergleicht diese mit der eingegebenen Adresse und nimmt eine Aktivierung bei Abweichung wieder zurück. Offline- und Serverfehler werden angezeigt. Der Schlüsselbund-Eintrag übersteht normalerweise das Entfernen und Neuinstallieren der App, solange er nicht separat aus dem Schlüsselbund gelöscht wird und Bundle-ID sowie Benutzerkonto gleich bleiben. Lokale Daten sind jedoch keine unangreifbare Lizenzsperre; für Verkaufssoftware sollte die Lizenz regelmäßig serverseitig validiert werden.
