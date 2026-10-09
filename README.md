# Apex OLED Stats

Zeigt Live-Werte auf dem OLED der **SteelSeries Apex Pro TKL Wireless** (über die GameSense-API von SteelSeries GG), dazu RGB-Pegel und eine Überhitzungswarnung auf den Tasten. Geschrieben in PowerShell, ohne eigene Installation.

> Inoffizielles Hobbyprojekt, nicht mit SteelSeries, NZXT, NVIDIA oder Valve verbunden. Getestet nur auf einem System: Intel i7-14700, RTX 3080, NZXT Kraken, Windows 11.

## Seiten (alle 5 s im Wechsel, im Tray-Menü einzeln schaltbar)
Das OLED nimmt über GameSense nur zwei Textzeilen mit etwa 15 Zeichen an.

1. **CPU + GPU:** Temperatur, Last, Leistung (`CPU 59 16% 70W` / `GPU 37 19% 116W`)
2. **Wasserkühlung:** Flüssigkeitstemperatur und Pumpendrehzahl (NZXT Kraken)
3. **GPU-Last + VRAM:** `GPU Last 20%` / `VRAM 2.1/10G`
4. **ARC Raiders:** aktuelle Steam-Spielerzahl (öffentliche Steam-API, App-ID 1808500, Abfrage alle 60 s)
5. **Netzwerk:** Download und Upload in Mbit/s (Summe aller aktiven Ethernet-/WLAN-Adapter, ohne virtuelle)
6. **Spitzenwerte:** höchste CPU-/GPU-Temperatur und Leistung seit Start (im Tray-Menü zurücksetzbar)
7. **Energie + Kosten:** `Total 0.42kWh` / `ca. 0.15 EUR` – CPU- plus GPU-Leistung aufsummiert (nicht der ganze PC). Während eines Spiels zeigt die Seite nur dessen Verbrauch (`Spiel …`).
8. **Spielzeit:** Name und Dauer des erkannten Spiels (erscheint nur, solange eins läuft)

## Optionen (Tray-Menü)
- **Überhitzungswarnung:** Das Display zeigt `!! GPU HEISS !!` mit Vorrang vor allen Seiten, die Zahlenreihe 1–0 blinkt rot.
  Schwellen in `config.json` unter `warn` (Standard: CPU 95 °C, GPU 83 °C, Wasser 55 °C; 3 °C Hysterese).
- **RGB-Pegel:** F1–F4 = CPU, F5–F8 = GPU, F9–F12 = Wasser. Je höher die Temperatur, desto mehr Tasten leuchten (Farbe grün → gelb → rot in 10 Stufen, Skala bis zur Warnschwelle).
- „Warnung testen (10 s)“ simuliert 99 °C an der GPU.
- **Spiele erkennen:** Läuft ein Prozess unter `…\steamapps\common\<Spiel>\` (jede Steam-Bibliothek), startet eine Sitzung:
  Spitzenwerte werden zurückgesetzt, Spielzeit und Energie werden gezählt, alle 10 s kommt eine Zeile in `sessions\<datum>_<spiel>.csv`.
  Endet das Spiel (20 s Karenz), zeigt das Display 3 Bilder lang einen **Bericht** (Dauer, Spitzenwerte, Energie), dazu eine Zeile in `sessions\summary.csv`.
- **Pausenerinnerung:** Nach 2 h Spielzeit (dann stündlich) zeigt das Display `Pause? 2h`, die Zahlenreihe blinkt langsam blau.

### Weitere Einstellungen (nur in `config.json`)
| Schlüssel | Bedeutung | Standard |
|---|---|---|
| `price` | Strompreis in EUR pro kWh | `0.35` |
| `breakHours` | Pausenerinnerung nach … Stunden | `2` |
| `extraGames` | Prozessnamen ohne `.exe` für Spiele außerhalb von Steam, z. B. `["Fortnite"]` | `[]` |
| `ignoreFolders` | Ordner unter `steamapps\common`, die kein Spiel sind (Dauerläufer) | Steamworks Shared, wallpaper_engine, Steam Controller Configs, DisplayFusion |
| `warn` | Warnschwellen in °C (`cpu`, `gpu`, `water`) | 95 / 83 / 55 |

## Voraussetzungen
- SteelSeries GG, die App **„CPU/GPU Stats“** muss in GG eingeschaltet sein
- NVIDIA-Treiber (`nvidia-smi`) für die GPU-Werte
- **PawnIO**-Treiber für die CPU-Sensoren: `winget install namazso.PawnIO`
- Adminrechte (CPU-Temperatur und -Leistung)
- LibreHardwareMonitor-DLLs in `lib\` – einmalig herunterladen:
  ```powershell
  powershell -ExecutionPolicy Bypass -File setup-lib.ps1
  ```
- Wasserseite nur mit einem unterstützten AIO (LibreHardwareMonitor, z. B. NZXT Kraken); ohne zeigt die Seite `--`.

## Start
- Testen: `start.cmd` (fragt nach Adminrechten).
- Autostart beim Anmelden, versteckt und mit Adminrechten: `install-autostart.ps1` als Administrator ausführen. Das legt die Aufgabe `ApexOledStats` an. Entfernen:
  ```powershell
  Unregister-ScheduledTask -TaskName ApexOledStats -Confirm:$false
  ```

## Dateien
| Datei | Zweck |
|---|---|
| `OledStats.ps1` | Hauptskript (Sensoren, GameSense, Tray-Menü) |
| `setup-lib.ps1` | Lädt LibreHardwareMonitor und kopiert die DLLs nach `lib\` |
| `start.cmd` | Manueller Start mit Adminrechten |
| `install-autostart.ps1` | Legt die Aufgabe `ApexOledStats` an |
| `dump-sensors.ps1` | Diagnose: listet alle erkannten Sensoren nach `sensors.txt` |
| `app-*.png` | Bilder für die GG-App-Kachel |
| `config.json` | wird beim Umschalten im Tray-Menü automatisch angelegt (nicht im Repository) |

## Hinweise
- Ein per GameSense gesendetes Bitmap (128×40) wurde auf dem Gerät nicht angezeigt, nur Text.
- Kachelbild für GG: `GAMESENSE-TILE-IMAGE-CPUGPU_STATS.png` (570×349) nach `C:\ProgramData\SteelSeries\GG\shared\externalAppIcons` kopieren. Ob GG es für eine selbst angemeldete App anzeigt, ist nicht gesichert.
- Fehler stehen in `log.txt`.

## Drittanbieter
- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) (MPL-2.0) für CPU- und AIO-Sensoren
- [PawnIO](https://github.com/namazso/PawnIO) als Treiber für den Hardwarezugriff
