# QianLi IR für Mac

Mac-Version der Windows-Software **QianLi IR** (Wärmebild-Software für die QianLi-Wärmebildkameras,
z. B. am Reparatur-Mikroskop). Native macOS-App in Swift/SwiftUI, läuft auf Apple-Silicon- und Intel-Macs ab macOS 13.

**Download:** unter [Releases › mac-latest](../../releases/tag/mac-latest) die Datei `QianLi-IR-Mac.dmg` laden.
Installationshinweise: [docs/Installation.txt](docs/Installation.txt).

## Funktionen

| Windows-Programm | Mac-Version |
|---|---|
| Farbpaletten 1–6 | 6 Paletten (Eisen, Regenbogen, Weiß heiß, Schwarz heiß, Lava, Arktis) |
| Universal / Bildverbesserung / Hoher Kontrast | ✓ |
| Superauflösung | ✓ (Lanczos-Hochrechnung + Schärfen) |
| 2D/3D | ✓ eigenes 3D-Fenster (drehen, zoomen) |
| Foto / Video / Bilderordner | ✓ PNG + Temperatur-CSV, H.264-Video (.mov) |
| Punkt- und Rahmen-Temperatur | ✓ bis 9 Messpunkte, 6 Messrahmen (Max/Min/Ø) |
| Hoch-/Tieftemperatur-Verfolgung | ✓ |
| Hochtemperatur-Alarm | ✓ mit Warnton |
| Drehen, Spiegeln | ✓ |
| One-Click-Schnellsuche / PCB-Schnellsuche | ✓ Kurzschluss-Schnellsuche (nur heiße Stelle farbig) |
| Doppelbild-Vergleich | ✓ Platinenvergleich gut/defekt mit Differenzbild |
| Dual-Light-Modi (Mischung, sichtbarer Hintergrund, nur sichtbar, nur IR) | ✓ mit beliebiger zweiter USB-Kamera, manuelle Ausrichtung |
| Kurve | ✓ Messlinie mit Temperaturprofil |
| Kalibrierung zurücksetzen | ✓ Temperatur-Korrektur (Offset) und Emissionsgrad |
| Treiber 1–4 | entfällt – macOS braucht keinen Treiber |
| Hoch/Niedrig-Temperaturbereich umschalten | ✓ per USB-Befehl an die Kamera |
| Shutter / Kalibrieren | ✓ per USB-Befehl an die Kamera |

## Unterstützte Kameras

Kameras mit InfiRay **Tiny1-C** (USB `0BDA:5840`) oder **Mini** (`0BDA:5830`) Modul – das sind die Module,
für die das Windows-Programm Treiber mitbringt. Sie melden sich am Mac als normale USB-Kamera und liefern
pro Bild ein Graubild plus eine Temperatur-Tabelle (1/64 Kelvin pro Pixel); die App liest die Tabelle direkt aus.

Befehle an die Kamera (Temperaturbereich, Shutter) gehen über dieselben USB-Herstelleranfragen wie in der
Windows-DLL `libircmd` (siehe `Sources/ThermalCore/InfiRayProtocol.swift`). Ältere Xtherm/MIIR-Kameras mit eigenem
Rohdatenformat werden nicht unterstützt.

## Bauen

```bash
swift test                 # Kern-Logik testen
./scripts/build-app.sh     # dist/QianLi IR.app + dist/QianLi-IR-Mac.dmg
```

GitHub Actions baut bei jedem Push automatisch und legt die DMG unter dem Release `mac-latest` ab.

## Aufbau

- `Sources/ThermalCore` – reine Swift-Logik: Bildformat erkennen, Temperaturen auslesen, Statistik, Drehen/Spiegeln, Paletten, Einfärben, Differenzbild, CSV, Demo-Szene.
- `Sources/USBControl` – USB-Steuerbefehle an die Kamera (IOKit).
- `Sources/QianliIR` – die App: Kamera (AVFoundation), Bildaufbau mit Markierungen (CoreGraphics), Video (AVAssetWriter), Oberfläche (SwiftUI), 3D (SceneKit), Verlauf (Swift Charts).
