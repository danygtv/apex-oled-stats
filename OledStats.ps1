# Zeigt CPU/GPU/Wasser-Werte auf dem OLED der SteelSeries Apex Pro TKL Wireless (GameSense-API).
# Benoetigt Adminrechte (fuer CPU-Temperatur/-Leistung via LibreHardwareMonitor).
# Das OLED fasst nur 2 Textzeilen, daher wechseln die aktiven Seiten alle $PageSeconds Sekunden.
# Seiten ein-/ausschalten: Rechtsklick auf das Tray-Symbol. Auswahl liegt in config.json.
param([int]$IntervalMs = 1000, [int]$PageSeconds = 5, [switch]$Once, [string]$GameName = 'CPUGPU_STATS')

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
    cpugpu  = 'CPU + GPU (Temperatur, Watt)'
    water   = 'Wasserkuehlung (Kraken)'
    gpuload = 'GPU-Last + VRAM'
}
$script:cfg = @{}
foreach ($k in $pageDefs.Keys) { $script:cfg[$k] = $true }
if (Test-Path $cfgPath) {
    try {
        $saved = Get-Content $cfgPath -Raw | ConvertFrom-Json
        foreach ($k in $pageDefs.Keys) { if ($null -ne $saved.pages.$k) { $script:cfg[$k] = [bool]$saved.pages.$k } }
    } catch { Write-Log "config.json unlesbar: $($_.Exception.Message)" }
}
function Save-Config {
    try { (@{ pages = $script:cfg } | ConvertTo-Json) | Set-Content -Path $cfgPath -Encoding UTF8 } catch { Write-Log "config.json nicht speicherbar: $($_.Exception.Message)" }
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

function Get-Lines([string]$page) {
    $ci = [Globalization.CultureInfo]::InvariantCulture
    switch ($page) {
        'cpugpu' {
            $c = Get-CpuStats; $g = Get-GpuStats
            # Ein Leerzeichen zwischen allen Teilen; Temperatur ohne Einheit, damit die GPU-Zeile ins Display passt
            @(('CPU {0} {1} {2}' -f (Fmt $c.Temp ''), (Fmt $c.Load '%'), (Fmt $c.Watt 'W')),
              ('GPU {0} {1} {2}' -f (Fmt $g.Temp ''), (Fmt $g.Load '%'), (Fmt $g.Watt 'W')))
        }
        'water' {
            $w = Get-WaterStats
            @(('H2O {0}' -f (Fmt $w.Temp 'C')),
              ('Pumpe {0}' -f (Fmt $w.Pump 'rpm')))
        }
        'gpuload' {
            $g = Get-GpuStats
            $vram = if ($null -ne $g.MemUsed -and $null -ne $g.MemTotal) {
                'VRAM {0}/{1}G' -f ($g.MemUsed / 1024).ToString('0.0', $ci), ($g.MemTotal / 1024).ToString('0', $ci)
            } else { 'VRAM --' }
            @(('GPU Last {0}' -f (Fmt $g.Load '%')), $vram)
        }
    }
}

function Get-ActivePages { @($pageDefs.Keys | Where-Object { $script:cfg[$_] }) }

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
}

# --- Testmodus: alle Seiten einmal ausgeben, ohne GG und Tray ------------------
if ($Once) {
    foreach ($k in $pageDefs.Keys) { "[$k]"; Get-Lines $k }
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

$header = New-Object System.Windows.Forms.ToolStripMenuItem 'Seiten auf dem Display'
$header.Enabled = $false
[void]$menu.Items.Add($header)
foreach ($k in $pageDefs.Keys) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $pageDefs[$k]
    $item.Tag = $k
    $item.Checked = $script:cfg[$k]
    $item.Add_Click({
        param($sender, $e)
        $key = [string]$sender.Tag
        if ($script:cfg[$key] -and @(Get-ActivePages).Count -le 1) { return }   # mindestens eine Seite bleibt an
        $script:cfg[$key] = -not $script:cfg[$key]
        $sender.Checked = $script:cfg[$key]
        Save-Config
    })
    [void]$menu.Items.Add($item)
}
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
        $pages = @(Get-ActivePages)   # @() verhindert, dass eine einzelne Seite zum String wird
        $page = $pages[[int]([math]::Floor($script:clock.Elapsed.TotalSeconds / $PageSeconds) % $pages.Count)]
        $lines = Get-Lines $page
        $script:tick = ($script:tick % 99) + 1   # wechselnder Wert, damit GG jedes Event als neu wertet
        if (-not $script:registered) { Register-App; $script:registered = $true }
        Send-GS 'game_event' @{ game = $game; event = 'STATS'; data = @{ value = $script:tick; frame = @{ l1 = $lines[0]; l2 = $lines[1] } } }
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
