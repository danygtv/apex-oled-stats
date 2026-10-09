# Zeigt CPU/GPU/Wasser-Werte auf dem OLED der SteelSeries Apex Pro TKL Wireless (GameSense-API).
# Benoetigt Adminrechte (fuer CPU-Temperatur/-Leistung via LibreHardwareMonitor).
# Das OLED fasst nur 2 Textzeilen, daher wechseln die aktiven Seiten alle $PageSeconds Sekunden.
# Seiten und Optionen schalten: Rechtsklick auf das Tray-Symbol. Auswahl liegt in config.json.
param([int]$IntervalMs = 1000, [int]$PageSeconds = 5, [switch]$Once, [switch]$SimulateWarning, [string]$GameName = 'CPUGPU_STATS')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$game = $GameName
$logPath = Join-Path $root 'log.txt'
$cfgPath = Join-Path $root 'config.json'

function Write-Log($msg) {
    try {
        if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 100KB) { Remove-Item $logPath -Force }
        Add-Content -Path $logPath -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg)
    } catch {}
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Warning 'Nicht als Administrator gestartet: CPU-Temperatur/Watt sind evtl. nicht lesbar. Besser start.cmd benutzen.' }

# Nur eine Instanz gleichzeitig (nicht im Testmodus)
if (-not $Once) {
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Global\ApexOledStats', [ref]$createdNew)
    if (-not $createdNew) { Write-Log 'Zweite Instanz beendet.'; return }
}

# --- Seiten und Einstellungen --------------------------------------------
$pageDefs = [ordered]@{
    cpugpu  = 'CPU + GPU (Temperatur, Last, Watt)'
    water   = 'Wasserkuehlung (Kraken)'
    gpuload = 'GPU-Last + VRAM'
    arc     = 'ARC Raiders: Steam-Spieler'
    net     = 'Netzwerk: Download / Upload'
    peak    = 'Spitzenwerte seit Start'
    energy  = 'Energie + Kosten (CPU + GPU)'
    session = 'Spielzeit (nur waehrend eines Spiels)'
}
$optionDefs = [ordered]@{
    warn  = 'Warnung bei Ueberhitzung (Display + rotes Blinken)'
    rgb   = 'RGB-Pegel auf F1-F12 (CPU / GPU / Wasser)'
    games = 'Spiele erkennen (Spielzeit, Reset, Sitzungsbericht)'
    break = 'Pausenerinnerung (blaues Blinken)'
}
$ArcAppId = 1808500
$ArcRefreshSeconds = 60

$script:cfg = @{}; foreach ($k in $pageDefs.Keys) { $script:cfg[$k] = $true }
$script:opt = @{}; foreach ($k in $optionDefs.Keys) { $script:opt[$k] = $true }
$script:warnCfg = @{ cpu = 95; gpu = 83; water = 55 }   # Schwellen in Grad C
# Weitere Einstellungen (nur in config.json aenderbar):
#   price         Strompreis in EUR pro kWh
#   breakHours    Pausenerinnerung nach so vielen Stunden Spielzeit (danach stuendlich)
#   extraGames    Prozessnamen ohne .exe fuer Spiele ausserhalb von Steam, z. B. ["Fortnite"]
#   ignoreFolders Ordner unter steamapps\common, die KEIN Spiel sind (laufen dauerhaft)
$script:extra = @{
    price = 0.35
    breakHours = 2
    extraGames = @()
    ignoreFolders = @('Steamworks Shared', 'wallpaper_engine', 'Steam Controller Configs', 'DisplayFusion')
}
if (Test-Path $cfgPath) {
    try {
        $saved = Get-Content $cfgPath -Raw | ConvertFrom-Json
        foreach ($k in $pageDefs.Keys) { if ($null -ne $saved.pages.$k) { $script:cfg[$k] = [bool]$saved.pages.$k } }
        foreach ($k in $optionDefs.Keys) { if ($null -ne $saved.options.$k) { $script:opt[$k] = [bool]$saved.options.$k } }
        foreach ($k in 'cpu', 'gpu', 'water') { if ($null -ne $saved.warn.$k) { $script:warnCfg[$k] = [double]$saved.warn.$k } }
        if ($null -ne $saved.price) { $script:extra.price = [double]$saved.price }
        if ($null -ne $saved.breakHours) { $script:extra.breakHours = [double]$saved.breakHours }
        if ($null -ne $saved.extraGames) { $script:extra.extraGames = @($saved.extraGames) }
        if ($null -ne $saved.ignoreFolders) { $script:extra.ignoreFolders = @($saved.ignoreFolders) }
    } catch { Write-Log "config.json unlesbar: $($_.Exception.Message)" }
}
function Save-Config {
    try {
        (@{ pages = $script:cfg; options = $script:opt; warn = $script:warnCfg
            price = $script:extra.price; breakHours = $script:extra.breakHours
            extraGames = @($script:extra.extraGames); ignoreFolders = @($script:extra.ignoreFolders) } | ConvertTo-Json) |
            Set-Content -Path $cfgPath -Encoding UTF8
    } catch { Write-Log "config.json nicht speicherbar: $($_.Exception.Message)" }
}

# --- Sensoren -------------------------------------------------------------
Get-ChildItem "$root\lib\*.dll" | ForEach-Object { try { [void][Reflection.Assembly]::LoadFrom($_.FullName) } catch {} }
$pc = New-Object LibreHardwareMonitor.Hardware.Computer
$pc.IsCpuEnabled = $true
$pc.IsControllerEnabled = $true   # NZXT Kraken (AIO)
$pc.Open()
$cpu = $pc.Hardware | Where-Object { $_.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu } | Select-Object -First 1
if (-not $cpu) { throw 'Keine CPU in LibreHardwareMonitor gefunden.' }
$cooler = $pc.Hardware | Where-Object { $_.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cooler } | Select-Object -First 1

function Get-WaterStats {
    if (-not $cooler) { return [pscustomobject]@{ Temp = $null; Pump = $null } }
    $cooler.Update()
    $t = $null; $r = $null
    foreach ($s in $cooler.Sensors) {
        if ($null -eq $s.Value) { continue }
        if ($s.SensorType -eq 'Temperature' -and $s.Name -eq 'Liquid') { $t = [double]$s.Value }
        if ($s.SensorType -eq 'Fan' -and $s.Name -eq 'Pump') { $r = [double]$s.Value }
    }
    [pscustomobject]@{ Temp = $t; Pump = $r }
}

function Get-CpuStats {
    $cpu.Update()
    $temps = @(); $watt = $null; $load = $null
    foreach ($s in $cpu.Sensors) {
        if ($null -eq $s.Value) { continue }
        if ($s.SensorType -eq 'Temperature' -and $s.Name -notmatch 'Distance|TjMax') { $temps += [double]$s.Value }
        if ($s.SensorType -eq 'Power' -and $s.Name -eq 'CPU Package') { $watt = [double]$s.Value }
        if ($s.SensorType -eq 'Load' -and $s.Name -eq 'CPU Total') { $load = [double]$s.Value }
    }
    [pscustomobject]@{
        Temp = if ($temps.Count) { ($temps | Measure-Object -Maximum).Maximum } else { $null }
        Watt = $watt
        Load = $load
    }
}

function Get-GpuStats {
    # nvidia-smi: Temperatur, Gesamtleistung, Auslastung, VRAM (MiB)
    $empty = [pscustomobject]@{ Temp = $null; Watt = $null; Load = $null; MemUsed = $null; MemTotal = $null }
    $o = & nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null
    if (-not $o) { return $empty }
    $p = ($o | Select-Object -First 1) -split ',\s*'
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $num = { param($s) $v = 0.0; if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, $ci, [ref]$v)) { $v } else { $null } }
    [pscustomobject]@{
        Temp = & $num $p[0]; Watt = & $num $p[1]; Load = & $num $p[2]
        MemUsed = & $num $p[3]; MemTotal = & $num $p[4]
    }
}

function Fmt($v, $unit) { if ($null -eq $v) { '--' } else { '{0}{1}' -f ([math]::Round($v)).ToString([Globalization.CultureInfo]::InvariantCulture), $unit } }

# Alle Sensoren einmal pro Sekunde lesen; Seiten, Spitzenwerte, Warnungen und RGB nutzen denselben Schnappschuss
$script:snap = $null
$script:peak = @{}
function Update-Peak($key, $v) {
    if ($null -ne $v -and ($null -eq $script:peak[$key] -or $v -gt $script:peak[$key])) { $script:peak[$key] = $v }
}
$script:energyWh = 0.0          # CPU- + GPU-Leistung seit Skriptstart, aufsummiert
$script:session = $null         # laufende Spielsitzung (siehe Update-Game)
$script:lastSampleAt = 0L
function Sample-All {
    $script:snap = @{ cpu = (Get-CpuStats); gpu = (Get-GpuStats); water = (Get-WaterStats) }
    Update-Peak 'cpuT' $script:snap.cpu.Temp; Update-Peak 'cpuW' $script:snap.cpu.Watt
    Update-Peak 'gpuT' $script:snap.gpu.Temp; Update-Peak 'gpuW' $script:snap.gpu.Watt
    # Energie: Watt * Sekunden / 3600 = Wh. Zu lange Pausen (z. B. GG nicht erreichbar) werden nicht mitgerechnet.
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    if ($script:lastSampleAt -gt 0) {
        $dt = ($now - $script:lastSampleAt) / [double][Diagnostics.Stopwatch]::Frequency
        if ($dt -gt 0 -and $dt -le 5) {
            $w = [double]$script:snap.cpu.Watt + [double]$script:snap.gpu.Watt
            $script:energyWh += $w * $dt / 3600
            if ($script:session) { $script:session.wh += $w * $dt / 3600 }
        }
    }
    $script:lastSampleAt = $now
}

# Netzwerk: Durchsatz in Mbit/s aus den Adapter-Zaehlern (nur echte Ethernet-/WLAN-Adapter)
$script:netPrev = @{}; $script:netPrevAt = 0L; $script:netDown = $null; $script:netUp = $null
function Update-Net {
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    $cur = @{}
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.OperationalStatus -ne 'Up') { continue }
        if ($n.NetworkInterfaceType -notin 'Ethernet', 'Wireless80211', 'GigabitEthernet') { continue }
        if ($n.Description -match 'Virtual|vEthernet|VMware|VirtualBox|Hyper-V|Bluetooth|TAP|WireGuard|Tunnel|Loopback|Wi-Fi Direct') { continue }
        $st = $n.GetIPStatistics()
        $cur[$n.Id] = @($st.BytesReceived, $st.BytesSent)
    }
    if ($script:netPrevAt -gt 0) {
        $dt = ($now - $script:netPrevAt) / [double][Diagnostics.Stopwatch]::Frequency
        if ($dt -gt 0) {
            $rx = 0.0; $tx = 0.0
            foreach ($id in $cur.Keys) {
                if (-not $script:netPrev.ContainsKey($id)) { continue }
                $d1 = $cur[$id][0] - $script:netPrev[$id][0]; $d2 = $cur[$id][1] - $script:netPrev[$id][1]
                if ($d1 -gt 0) { $rx += $d1 }; if ($d2 -gt 0) { $tx += $d2 }
            }
            $script:netDown = $rx * 8 / $dt / 1e6
            $script:netUp = $tx * 8 / $dt / 1e6
        }
    }
    $script:netPrev = $cur; $script:netPrevAt = $now
}
function Fmt-Mbit($v) {
    if ($null -eq $v) { return '--' }
    $ci = [Globalization.CultureInfo]::InvariantCulture
    if ($v -ge 100) { ([math]::Round($v)).ToString('0', $ci) } else { $v.ToString('0.0', $ci) }
}

$script:arcCount = $null
$script:arcFetchedAt = [datetime]::MinValue

function Get-ArcPlayers {
    # Oeffentliche Steam-Schnittstelle (kein Schluessel noetig); nur alle $ArcRefreshSeconds abfragen
    if (((Get-Date) - $script:arcFetchedAt).TotalSeconds -ge $ArcRefreshSeconds) {
        $script:arcFetchedAt = Get-Date   # auch bei Fehlern erst nach der Wartezeit erneut versuchen
        try {
            $r = Invoke-RestMethod "https://api.steampowered.com/ISteamUserStats/GetNumberOfCurrentPlayers/v1/?appid=$ArcAppId" -TimeoutSec 4
            if ($r.response.result -eq 1) { $script:arcCount = [int]$r.response.player_count }
        } catch { Write-Log "Steam-Abfrage fehlgeschlagen: $($_.Exception.Message)" }
    }
    $script:arcCount
}

# --- Spiele erkennen, Sitzungen, Sitzungsbericht, Pausenerinnerung -----------------
$script:notice = $null            # kurze Meldung mit Vorrang vor den Seiten (Sitzungsbericht, Pausenerinnerung)
$script:lastGameCheck = [datetime]::MinValue
$script:gameLastSeen = [datetime]::MinValue
$sessionDir = Join-Path $root 'sessions'
$inv = [Globalization.CultureInfo]::InvariantCulture

function Short([string]$s, [int]$n) { if ($s.Length -gt $n) { $s.Substring(0, $n) } else { $s } }
function Fmt-Dur([timespan]$t) {
    if ($t.TotalHours -ge 1) { '{0}h{1:00}' -f [int][math]::Floor($t.TotalHours), $t.Minutes }
    else { '{0} min' -f [int][math]::Floor($t.TotalMinutes) }
}
function Get-EnergyLines($wh, [string]$label) {
    @(('{0} {1}kWh' -f $label, ($wh / 1000).ToString('0.00', $inv)),
      ('ca. {0} EUR' -f ($wh / 1000 * $script:extra.price).ToString('0.00', $inv)))
}
function New-Notice($frames, [int]$seconds) {
    $list = New-Object System.Collections.ArrayList
    foreach ($f in $frames) { [void]$list.Add($f) }
    $script:notice = @{ started = Get-Date; until = (Get-Date).AddSeconds($seconds); frames = $list }
}

function Find-Game {
    # 1) Prozesse unter ...\steamapps\common\<Spiel>\  (jede Steam-Bibliothek), 2) Prozessnamen aus extraGames
    $found = $null
    try {
        $procs = Get-CimInstance Win32_Process -Filter "ExecutablePath LIKE '%\\steamapps\\common\\%'" -Property Name, ExecutablePath
        foreach ($p in $procs) {
            if ($p.Name -match 'Crash|Helper|EasyAnti|BattlEye|Redist|Prereq|Setup|Installer|Bootstrap|Reporter|Anticheat') { continue }
            if ($p.ExecutablePath -match '\\steamapps\\common\\([^\\]+)\\') {
                if ($script:extra.ignoreFolders -contains $Matches[1]) { continue }
                $found = $Matches[1]; break
            }
        }
    } catch { Write-Log "Spielerkennung fehlgeschlagen: $($_.Exception.Message)" }
    if (-not $found) {
        foreach ($g in @($script:extra.extraGames)) {
            if ($g -and (Get-Process -Name $g -ErrorAction SilentlyContinue)) { $found = [string]$g; break }
        }
    }
    $found
}

function Start-Session([string]$name) {
    $script:peak = @{}   # Spitzenwerte gelten ab jetzt fuer dieses Spiel
    $script:session = @{ name = $name; start = Get-Date; wh = 0.0; csv = $null; lastCsv = [datetime]::MinValue
                         nextBreak = (Get-Date).AddHours($script:extra.breakHours) }
    try {
        New-Item -ItemType Directory -Force $sessionDir | Out-Null
        $safe = $name -replace '[^\w\.-]+', '_'
        $script:session.csv = Join-Path $sessionDir ('{0:yyyy-MM-dd_HHmm}_{1}.csv' -f (Get-Date), $safe)
        'zeit;cpu_temp;cpu_last;cpu_watt;gpu_temp;gpu_last;gpu_watt;vram_mb;wasser_temp;down_mbit;up_mbit' | Set-Content $script:session.csv -Encoding UTF8
    } catch { Write-Log "Sitzungsdatei nicht anlegbar: $($_.Exception.Message)"; $script:session.csv = $null }
    Write-Log "Spiel gestartet: $name"
}

function Write-SessionRow {
    $s = $script:session
    if (-not $s -or -not $s.csv -or ((Get-Date) - $s.lastCsv).TotalSeconds -lt 10) { return }
    $s.lastCsv = Get-Date
    $c = $script:snap.cpu; $g = $script:snap.gpu; $w = $script:snap.water
    $f = { param($v, $d) if ($null -eq $v) { '' } else { ([double]$v).ToString($d, $inv) } }
    $row = @((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), (& $f $c.Temp '0.0'), (& $f $c.Load '0.0'), (& $f $c.Watt '0.0'),
             (& $f $g.Temp '0.0'), (& $f $g.Load '0.0'), (& $f $g.Watt '0.0'), (& $f $g.MemUsed '0'), (& $f $w.Temp '0.0'),
             (& $f $script:netDown '0.0'), (& $f $script:netUp '0.0')) -join ';'
    try { Add-Content -Path $s.csv -Value $row -Encoding UTF8 } catch { Write-Log "Sitzungsdatei nicht beschreibbar: $($_.Exception.Message)" }
}

function End-Session {
    $s = $script:session; $script:session = $null
    $dur = (Get-Date) - $s.start
    # Bericht: 3 Bilder je $PageSeconds Sekunden (Dauer, Spitzenwerte, Energie)
    New-Notice @(
        @((Short $s.name 15), ('Dauer ' + (Fmt-Dur $dur))),
        (Get-Lines 'peak'),
        (Get-EnergyLines $s.wh 'Spiel')
    ) (3 * $PageSeconds)
    try {
        New-Item -ItemType Directory -Force $sessionDir | Out-Null
        $sum = Join-Path $sessionDir 'summary.csv'
        if (-not (Test-Path $sum)) { 'start;ende;spiel;dauer_min;max_cpu_temp;max_cpu_watt;max_gpu_temp;max_gpu_watt;energie_kwh;kosten_eur' | Set-Content $sum -Encoding UTF8 }
        $p = $script:peak
        $n = { param($v) if ($null -eq $v) { '' } else { ([double]$v).ToString('0.0', $inv) } }
        (@($s.start.ToString('yyyy-MM-dd HH:mm'), (Get-Date).ToString('yyyy-MM-dd HH:mm'), $s.name, $dur.TotalMinutes.ToString('0', $inv),
           (& $n $p.cpuT), (& $n $p.cpuW), (& $n $p.gpuT), (& $n $p.gpuW),
           ($s.wh / 1000).ToString('0.000', $inv), ($s.wh / 1000 * $script:extra.price).ToString('0.00', $inv)) -join ';') | Add-Content $sum -Encoding UTF8
    } catch { Write-Log "summary.csv nicht beschreibbar: $($_.Exception.Message)" }
    Write-Log ('Spiel beendet: {0} nach {1:0} min, {2:0.000} kWh' -f $s.name, $dur.TotalMinutes, ($s.wh / 1000))
}

function Update-Game {
    if (-not $script:opt.games) { if ($script:session) { End-Session }; return }
    if (((Get-Date) - $script:lastGameCheck).TotalSeconds -lt 5) { return }
    $script:lastGameCheck = Get-Date
    $name = Find-Game
    if ($name) {
        $script:gameLastSeen = Get-Date
        if (-not $script:session) { Start-Session $name }
    }
    elseif ($script:session -and ((Get-Date) - $script:gameLastSeen).TotalSeconds -gt 20) { End-Session }
}

# Pausenerinnerung nach breakHours Stunden Spielzeit, danach stuendlich. Gibt $true zurueck, wenn sie jetzt ausloest.
function Test-Break {
    if (-not ($script:opt.break -and $script:session)) { return $false }
    if ((Get-Date) -lt $script:session.nextBreak) { return $false }
    $h = [math]::Round(((Get-Date) - $script:session.start).TotalHours)
    $script:session.nextBreak = $script:session.nextBreak.AddHours(1)
    New-Notice @(, @(('Pause? {0}h' -f $h), 'Kurz aufstehen')) 10
    Write-Log "Pausenerinnerung nach $h h ($($script:session.name))"
    $true
}

# Mehr als 15 Zeichen passen nicht ins Display (z. B. "GPU 37 100% 116W"): dann das W weglassen
function Limit-Lines($lines) { @($lines | ForEach-Object { if ($_.Length -gt 15) { $_.TrimEnd('W') } else { $_ } }) }

function Get-Lines([string]$page) {
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $c = $script:snap.cpu; $g = $script:snap.gpu; $w = $script:snap.water
    switch ($page) {
        'cpugpu' {
            # Ein Leerzeichen zwischen allen Teilen; Temperatur ohne Einheit, damit die GPU-Zeile ins Display passt
            Limit-Lines @(('CPU {0} {1} {2}' -f (Fmt $c.Temp ''), (Fmt $c.Load '%'), (Fmt $c.Watt 'W')),
                          ('GPU {0} {1} {2}' -f (Fmt $g.Temp ''), (Fmt $g.Load '%'), (Fmt $g.Watt 'W')))
        }
        'water' {
            @(('H2O {0}' -f (Fmt $w.Temp 'C')),
              ('Pumpe {0}' -f (Fmt $w.Pump 'rpm')))
        }
        'gpuload' {
            $vram = if ($null -ne $g.MemUsed -and $null -ne $g.MemTotal) {
                'VRAM {0}/{1}G' -f ($g.MemUsed / 1024).ToString('0.0', $ci), ($g.MemTotal / 1024).ToString('0', $ci)
            } else { 'VRAM --' }
            @(('GPU Last {0}' -f (Fmt $g.Load '%')), $vram)
        }
        'net' {
            @(('Down {0} Mb/s' -f (Fmt-Mbit $script:netDown)), ('Up   {0} Mb/s' -f (Fmt-Mbit $script:netUp)))
        }
        'arc' {
            $n = Get-ArcPlayers
            $txt = if ($null -ne $n) { $n.ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('de-DE')) } else { '--' }
            @('ARC Raiders', ('Spieler {0}' -f $txt))
        }
        'energy' {
            if ($script:session) { Get-EnergyLines $script:session.wh 'Spiel' } else { Get-EnergyLines $script:energyWh 'Total' }
        }
        'session' {
            if ($script:session) { @((Short $script:session.name 15), ('Zeit ' + (Fmt-Dur ((Get-Date) - $script:session.start)))) }
            else { @('Kein Spiel', 'erkannt') }
        }
        'peak' {
            $p = $script:peak
            Limit-Lines @(('Max CPU {0} {1}' -f (Fmt $p.cpuT ''), (Fmt $p.cpuW 'W')),
                          ('Max GPU {0} {1}' -f (Fmt $p.gpuT ''), (Fmt $p.gpuW 'W')))
        }
    }
}

# "session" erscheint nur, solange ein Spiel laeuft; ohne aktive Seite faellt die Anzeige auf CPU + GPU zurueck
function Get-ActivePages {
    $p = @($pageDefs.Keys | Where-Object { $script:cfg[$_] -and ($_ -ne 'session' -or $script:session) })
    if ($p.Count -eq 0) { $p = @('cpugpu') }
    $p
}

# --- Ueberhitzungswarnung ----------------------------------------------------
$script:warnState = @{ cpu = $false; gpu = $false; water = $false }
$script:warnVals = @{}
$script:simUntil = [datetime]::MinValue   # "Warnung testen": GPU gilt bis dahin als 99 Grad
function Update-Warnings {
    $vals = @{ cpu = $script:snap.cpu.Temp; gpu = $script:snap.gpu.Temp; water = $script:snap.water.Temp }
    if ($SimulateWarning -or (Get-Date) -lt $script:simUntil) { $vals.gpu = 99 }
    foreach ($k in 'cpu', 'gpu', 'water') {
        $v = $vals[$k]
        if (-not $script:opt.warn -or $null -eq $v) { $script:warnState[$k] = $false; continue }
        if ($script:warnState[$k]) { if ($v -lt $script:warnCfg[$k] - 3) { $script:warnState[$k] = $false } }   # 3 Grad Hysterese
        elseif ($v -ge $script:warnCfg[$k]) { $script:warnState[$k] = $true }
    }
    $script:warnVals = $vals
}
function Get-ActiveWarnings { @('gpu', 'cpu', 'water' | Where-Object { $script:warnState[$_] }) }
function Get-WarnLines([string]$key) {
    $name = @{ cpu = 'CPU'; gpu = 'GPU'; water = 'H2O' }[$key]
    @(('!! {0} HEISS !!' -f $name), ('Temp {0}C' -f [math]::Round($script:warnVals[$key])))
}

# --- GameSense ------------------------------------------------------------
$script:base = $null

function Update-Base {
    # GG vergibt bei jedem Start einen neuen Port -> coreProps.json immer neu lesen
    $propsPath = Join-Path $env:ProgramData 'SteelSeries\SteelSeries Engine 3\coreProps.json'
    if (-not (Test-Path $propsPath)) { $propsPath = Join-Path $env:ProgramData 'SteelSeries\GG\coreProps.json' }
    $script:base = 'http://' + (Get-Content $propsPath -Raw | ConvertFrom-Json).address
}

function Send-GS($path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 12 -Compress
    Invoke-RestMethod -Uri "$script:base/$path" -Method Post -ContentType 'application/json; charset=utf-8' -TimeoutSec 5 -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
}

# RGB-Pegel: F1-F4 = CPU, F5-F8 = GPU, F9-F12 = Wasser (HID-Codes 58..69), Farbverlauf Gruen -> Rot
$rgbGroups = [ordered]@{ RGB_CPU = 58..61; RGB_GPU = 62..65; RGB_WATER = 66..69 }
$script:rgbBound = $false
function Get-RgbRanges {
    # 10 Stufen: Gruen -> Gelb (50 %) -> Rot. Mehr als zwei Farben gehen in GameSense nur ueber Bereiche mit statischer Farbe
    $green = 0, 220, 80; $yellow = 255, 215, 0; $red = 255, 40, 40
    $ranges = @()
    for ($i = 0; $i -lt 10; $i++) {
        $t = ($i * 10 + 5) / 100.0   # Mitte der Stufe
        if ($t -lt 0.5) { $a = $green; $b = $yellow; $f = $t * 2 } else { $a = $yellow; $b = $red; $f = ($t - 0.5) * 2 }
        $c = 0..2 | ForEach-Object { [int][math]::Round($a[$_] + ($b[$_] - $a[$_]) * $f) }
        $ranges += @{ low = $i * 10; high = $(if ($i -eq 9) { 100 } else { $i * 10 + 9 }); color = @{ red = $c[0]; green = $c[1]; blue = $c[2] } }
    }
    , $ranges
}
function Bind-Rgb {
    $ranges = Get-RgbRanges
    foreach ($e in $rgbGroups.Keys) {
        Send-GS 'bind_game_event' @{ game = $game; event = $e; min_value = 0; max_value = 100; icon_id = 0
            handlers = @(@{ 'device-type' = 'rgb-per-key-zones'; 'custom-zone-keys' = @($rgbGroups[$e]); mode = 'percent'; color = $ranges }) }
    }
    $script:rgbBound = $true
}
function Unbind-Rgb {
    foreach ($e in $rgbGroups.Keys) { try { Send-GS 'remove_game_event' @{ game = $game; event = $e } } catch {} }
    $script:rgbBound = $false
}
function To-Pct($v, $lo, $hi) {
    if ($null -eq $v) { return 0 }
    [int][math]::Max(0, [math]::Min(100, ($v - $lo) / ($hi - $lo) * 100))
}

function Register-App {
    Update-Base
    Send-GS 'game_metadata' @{ game = $game; game_display_name = 'CPU/GPU Stats'; developer = 'local' }
    Send-GS 'bind_game_event' @{
        game = $game; event = 'STATS'; min_value = 0; max_value = 100; icon_id = 0; value_optional = $true
        handlers = @(@{
            'device-type' = 'screened'
            zone = 'one'
            mode = 'screen'
            datas = @(@{
                'length-millis' = 5000
                'icon-id' = 0
                lines = @(
                    @{ 'has-text' = $true; 'context-frame-key' = 'l1' },
                    @{ 'has-text' = $true; 'context-frame-key' = 'l2' }
                )
            })
        })
    }
    # Warn-Blinken: Zahlenreihe 1-0 blinkt rot
    Send-GS 'bind_game_event' @{ game = $game; event = 'RGB_FLASH'; min_value = 0; max_value = 100; icon_id = 0
        handlers = @(@{ 'device-type' = 'rgb-per-key-zones'; zone = 'number-keys'; mode = 'color'; color = @{ red = 255; green = 0; blue = 0 }; rate = @{ frequency = 4; repeat_limit = 8 } }) }
    # Pausenerinnerung: Zahlenreihe blinkt langsam blau
    Send-GS 'bind_game_event' @{ game = $game; event = 'RGB_BREAK'; min_value = 0; max_value = 100; icon_id = 0
        handlers = @(@{ 'device-type' = 'rgb-per-key-zones'; zone = 'number-keys'; mode = 'color'; color = @{ red = 60; green = 120; blue = 255 }; rate = @{ frequency = 1; repeat_limit = 6 } }) }
    $script:rgbBound = $false   # Pegel-Events werden in Send-Rgb je nach Option neu gebunden
}

# Pegel- und Blink-Events pro Sekunde senden bzw. entfernen
$script:lastFlash = [datetime]::MinValue
function Send-Rgb {
    if ($script:opt.rgb) {
        if (-not $script:rgbBound) { Bind-Rgb }
        Send-GS 'game_event' @{ game = $game; event = 'RGB_CPU';   data = @{ value = (To-Pct $script:snap.cpu.Temp 30 $script:warnCfg.cpu) } }
        Send-GS 'game_event' @{ game = $game; event = 'RGB_GPU';   data = @{ value = (To-Pct $script:snap.gpu.Temp 30 $script:warnCfg.gpu) } }
        Send-GS 'game_event' @{ game = $game; event = 'RGB_WATER'; data = @{ value = (To-Pct $script:snap.water.Temp 25 $script:warnCfg.water) } }
    }
    elseif ($script:rgbBound) { Unbind-Rgb }
    if (@(Get-ActiveWarnings).Count -gt 0 -and ((Get-Date) - $script:lastFlash).TotalSeconds -ge 5) {
        $script:lastFlash = Get-Date
        Send-GS 'game_event' @{ game = $game; event = 'RGB_FLASH'; data = @{ value = 1 } }
    }
}

# --- Testmodus: alle Seiten einmal ausgeben, ohne GG und Tray ------------------
if ($Once) {
    Update-Net; Start-Sleep -Seconds 2; Update-Net   # Netzwerk braucht zwei Messpunkte
    Sample-All; Update-Warnings
    foreach ($k in $pageDefs.Keys) { "[$k]"; Get-Lines $k }
    "[warnungen]"; $aw = @(Get-ActiveWarnings); if ($aw.Count) { foreach ($k in $aw) { Get-WarnLines $k } } else { 'keine' }
    "[rgb %] CPU={0} GPU={1} H2O={2}" -f (To-Pct $script:snap.cpu.Temp 30 $script:warnCfg.cpu), (To-Pct $script:snap.gpu.Temp 30 $script:warnCfg.gpu), (To-Pct $script:snap.water.Temp 25 $script:warnCfg.water)
    $pc.Close(); return
}

# --- Tray-Symbol und Hauptschleife -------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:registered = $false
$script:retryAt = [datetime]::MinValue
$script:tick = 0
$script:clock = [Diagnostics.Stopwatch]::StartNew()

$bmp = New-Object System.Drawing.Bitmap 16, 16
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.Clear([System.Drawing.Color]::FromArgb(24, 24, 28))
$gfx.FillRectangle([System.Drawing.Brushes]::LimeGreen, 2, 9, 3, 5)
$gfx.FillRectangle([System.Drawing.Brushes]::Orange,    7, 5, 3, 9)
$gfx.FillRectangle([System.Drawing.Brushes]::DeepSkyBlue, 12, 2, 3, 12)
$gfx.Dispose()
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
$notify.Text = 'OLED-Stats (Apex Pro TKL)'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $menu

function Add-Header($text) {
    $h = New-Object System.Windows.Forms.ToolStripMenuItem $text
    $h.Enabled = $false
    [void]$menu.Items.Add($h)
}
Add-Header 'Seiten auf dem Display'
foreach ($k in $pageDefs.Keys) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $pageDefs[$k]
    $item.Tag = $k
    $item.Checked = $script:cfg[$k]
    $item.Add_Click({
        param($sender, $e)
        $key = [string]$sender.Tag
        if ($script:cfg[$key] -and @($pageDefs.Keys | Where-Object { $script:cfg[$_] }).Count -le 1) { return }   # mindestens eine Seite bleibt an
        $script:cfg[$key] = -not $script:cfg[$key]
        $sender.Checked = $script:cfg[$key]
        Save-Config
    })
    [void]$menu.Items.Add($item)
}
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
Add-Header 'Optionen'
foreach ($k in $optionDefs.Keys) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $optionDefs[$k]
    $item.Tag = $k
    $item.Checked = $script:opt[$k]
    $item.Add_Click({
        param($sender, $e)
        $key = [string]$sender.Tag
        $script:opt[$key] = -not $script:opt[$key]
        $sender.Checked = $script:opt[$key]
        Save-Config
    })
    [void]$menu.Items.Add($item)
}
$resetPeak = New-Object System.Windows.Forms.ToolStripMenuItem 'Spitzenwerte zuruecksetzen'
$resetPeak.Add_Click({ $script:peak = @{} })
[void]$menu.Items.Add($resetPeak)
$testWarn = New-Object System.Windows.Forms.ToolStripMenuItem 'Warnung testen (10 s)'
$testWarn.Add_Click({ $script:simUntil = (Get-Date).AddSeconds(10) })
[void]$menu.Items.Add($testWarn)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$quit = New-Object System.Windows.Forms.ToolStripMenuItem 'Beenden'
$quit.Add_Click({ $script:timer.Stop(); $notify.Visible = $false; [System.Windows.Forms.Application]::ExitThread() })
[void]$menu.Items.Add($quit)
$notify.Visible = $true

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = $IntervalMs
$script:timer.Add_Tick({
    try {
        if ((Get-Date) -lt $script:retryAt) { return }
        Update-Net     # jede Sekunde messen, damit der Durchsatz auch nach einem Seitenwechsel stimmt
        Sample-All     # Sensoren einmal lesen (auch fuer Spitzenwerte, Warnungen und RGB)
        Update-Warnings
        Update-Game
        $breakNow = Test-Break
        Write-SessionRow
        $warns = @(Get-ActiveWarnings)
        $step = [int]([math]::Floor($script:clock.Elapsed.TotalSeconds / $PageSeconds))
        $noticeOn = $script:notice -and (Get-Date) -lt $script:notice.until
        if ($warns.Count -gt 0) {
            $lines = Get-WarnLines $warns[$step % $warns.Count]   # Warnung hat Vorrang vor allem
        } elseif ($noticeOn) {
            # Meldung (Sitzungsbericht, Pausenerinnerung): Bilder im Wechsel, ab der ersten Sekunde der Meldung
            $n = $script:notice
            $lines = $n.frames[[int]([math]::Floor(((Get-Date) - $n.started).TotalSeconds / $PageSeconds)) % $n.frames.Count]
        } else {
            $pages = @(Get-ActivePages)   # @() verhindert, dass eine einzelne Seite zum String wird
            $lines = Get-Lines $pages[$step % $pages.Count]
        }
        $script:tick = ($script:tick % 99) + 1   # wechselnder Wert, damit GG jedes Event als neu wertet
        if (-not $script:registered) { Register-App; $script:registered = $true }
        Send-GS 'game_event' @{ game = $game; event = 'STATS'; data = @{ value = $script:tick; frame = @{ l1 = $lines[0]; l2 = $lines[1] } } }
        Send-Rgb
        if ($breakNow) { Send-GS 'game_event' @{ game = $game; event = 'RGB_BREAK'; data = @{ value = 1 } } }
    }
    catch {
        # GG noch nicht bereit, neu gestartet oder anderer Port: spaeter neu anmelden
        Write-Log $_.Exception.Message
        $script:registered = $false
        $script:retryAt = (Get-Date).AddSeconds(15)   # GG nicht mit Anfragen ueberlasten
    }
})
$script:timer.Start()

try { [System.Windows.Forms.Application]::Run() }
finally {
    $notify.Visible = $false; $notify.Dispose()
    $pc.Close()
    # Kein remove_game: GG vergisst sonst den Haken "aktiviert" fuer die App
}
