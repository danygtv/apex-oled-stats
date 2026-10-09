# Diagnose: schreibt alle von LibreHardwareMonitor gelesenen CPU-Sensoren nach sensors.txt
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $root 'sensors.txt'
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    "Admin: $isAdmin" | Out-File $out -Encoding utf8
    Get-ChildItem "$root\lib\*.dll" | ForEach-Object { try { [void][Reflection.Assembly]::LoadFrom($_.FullName) } catch { "LoadFail $($_.Name): $($_.Exception.Message)" | Out-File $out -Append -Encoding utf8 } }
    $pc = New-Object LibreHardwareMonitor.Hardware.Computer
    $pc.IsCpuEnabled = $true
    $pc.IsMotherboardEnabled = $true
    foreach ($f in 'IsControllerEnabled','IsPsuEnabled','IsStorageEnabled','IsGpuEnabled','IsMemoryEnabled') { try { $pc.$f = $true } catch {} }
    $pc.Open()
    Start-Sleep -Milliseconds 1500
    foreach ($h in $pc.Hardware) {
        $h.Update()
        "== $($h.HardwareType): $($h.Name)" | Out-File $out -Append -Encoding utf8
        foreach ($s in $h.Sensors) { "  [$($s.SensorType)] $($s.Name) = $($s.Value)" | Out-File $out -Append -Encoding utf8 }
        foreach ($sh in $h.SubHardware) {
            $sh.Update()
            "  -- Sub: $($sh.Name)" | Out-File $out -Append -Encoding utf8
            foreach ($s in $sh.Sensors) { "    [$($s.SensorType)] $($s.Name) = $($s.Value)" | Out-File $out -Append -Encoding utf8 }
        }
    }
    $pc.Close()
} catch { "ERROR: $($_ | Out-String)" | Out-File $out -Append -Encoding utf8 }
