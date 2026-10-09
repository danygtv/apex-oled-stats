# Apex OLED Stats

Zeigt Live-Werte auf dem OLED der SteelSeries Apex Pro TKL Wireless (über die GameSense-API von SteelSeries GG).

## Seiten (alle 5 s im Wechsel, im Tray-Menü einzeln schaltbar)
1. **CPU + GPU:** Temperatur, Last, Leistung (`CPU 59 16% 70W` / `GPU 37 19% 116W`)
2. **Wasserkühlung:** Flüssigkeitstemperatur und Pumpendrehzahl (NZXT Kraken)
3. **GPU-Last + VRAM:** `GPU Last 20%` / `VRAM 2.1/10G`

## Voraussetzungen
- SteelSeries GG, App **„CPU/GPU Stats“** muss in GG eingeschaltet sein
- NVIDIA-Treiber (`nvidia-smi`) für GPU-Werte
- **PawnIO**-Treiber für CPU-Sensoren: `winget install namazso.PawnIO`
- `lib\` enthält LibreHardwareMonitor v0.9.6 (DLLs)
- Adminrechte (CPU-Temperatur und -Leistung)

## Dateien
| Datei | Zweck |
|---|---|
| `OledStats.ps1` | Hauptskript (Sensoren, GameSense, Tray-Menü) |
| `start.cmd` | Manueller Start mit Adminrechten |
| `install-autostart.ps1` | Legt die Aufgabe `ApexOledStats` an (Start beim Anmelden, versteckt, Admin) |
| `dump-sensors.ps1` | Diagnose: listet alle erkannten Sensoren |
| `config.json` | Welche Seiten aktiv sind (wird vom Tray-Menü geschrieben) |
| `app-*.png` | Bilder für die GG-App-Kachel |

## Hinweise
- Das OLED nimmt über GameSense nur Text an (2 Zeilen), Bitmaps wurden nicht angezeigt.
- Kachelbild: `GAMESENSE-TILE-IMAGE-CPUGPU_STATS.png` in `C:\ProgramData\SteelSeries\GG\shared\externalAppIcons`.
- Fehler stehen in `log.txt`.
