# Laedt LibreHardwareMonitor (v0.9.6, .NET-Framework-Build) von GitHub und kopiert die benoetigten DLLs nach lib\.
# Quelle: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor (Lizenz: MPL-2.0)
# Aufruf:  powershell -ExecutionPolicy Bypass -File setup-lib.ps1
param([string]$Target = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'lib'))

$ErrorActionPreference = 'Stop'
$version = 'v0.9.6'
$url = "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/$version/LibreHardwareMonitor.zip"
$work = Join-Path ([IO.Path]::GetTempPath()) ('lhm_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $work | Out-Null
$zip = Join-Path $work 'lhm.zip'

Write-Host "Lade $url ..."
Invoke-WebRequest $url -OutFile $zip
Expand-Archive $zip (Join-Path $work 'x') -Force

$dlls = 'LibreHardwareMonitorLib.dll', 'HidSharp.dll', 'BlackSharp.Core.dll', 'DiskInfoToolkit.dll', 'RAMSPDToolkit-NDD.dll',
    'Microsoft.Bcl.AsyncInterfaces.dll', 'Microsoft.Bcl.HashCode.dll', 'System.Buffers.dll', 'System.Memory.dll',
    'System.Numerics.Vectors.dll', 'System.Runtime.CompilerServices.Unsafe.dll', 'System.Threading.Tasks.Extensions.dll',
    'System.Collections.Immutable.dll', 'System.Reflection.Metadata.dll', 'System.Text.Json.dll', 'System.Text.Encodings.Web.dll',
    'System.IO.Pipelines.dll', 'System.CodeDom.dll', 'System.Security.AccessControl.dll', 'System.Security.Principal.Windows.dll'

New-Item -ItemType Directory -Force $Target | Out-Null
foreach ($d in $dlls) { Copy-Item (Join-Path $work "x\$d") $Target -Force }
Get-ChildItem $Target -Filter *.dll | Unblock-File
Remove-Item $work -Recurse -Force
Write-Host "Fertig: $((Get-ChildItem $Target -Filter *.dll).Count) DLLs in $Target"
Write-Host 'Fuer die CPU-Sensoren zusaetzlich noetig: winget install namazso.PawnIO'
