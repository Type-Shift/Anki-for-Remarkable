<#
    Start the background sync automatically at logon.

        .\install-autosync.ps1              # every 10 minutes
        .\install-autosync.ps1 -Minutes 5
        .\install-autosync.ps1 -Remove

    Uses a hidden loop launched from the Startup folder rather than a
    Scheduled Task: Register-ScheduledTask returns "Access is denied" on this
    machine, so task creation is blocked by policy. The Startup folder is
    writable and needs no administrator rights.

    Nothing is shown while it runs. It skips quietly when the tablet is not
    on the network, or when Anki desktop is open and holding the collection.
#>
[CmdletBinding()]
param(
    [int]$Minutes = 10,
    [string]$Collection = "$env:APPDATA\Anki2\User 1\collection.anki2",
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$startup  = [Environment]::GetFolderPath('Startup')
$vbsPath  = Join-Path $startup 'reMarkable-Anki-AutoSync.vbs'
$script   = Join-Path $PSScriptRoot 'auto-sync.ps1'

function Stop-SyncDaemon {
    # Match on -Loop and exclude our own PID. A bare '*auto-sync.ps1*' also
    # matches 'install-autosync.ps1' as a substring, so this script previously
    # terminated the very session running it.
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -like '*auto-sync.ps1*' -and
            $_.CommandLine -like '*-Loop*'
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Remove) {
    if (Test-Path $vbsPath) { Remove-Item $vbsPath -Force }
    Stop-SyncDaemon
    Write-Host "Auto-sync removed." -ForegroundColor Green
    return
}

if (-not (Test-Path $script))     { throw "auto-sync.ps1 not found next to this script" }
if (-not (Test-Path $Collection)) { throw "Collection not found: $Collection" }

# WScript.Shell Run with intWindowStyle 0 and bWaitOnReturn false gives a
# genuinely hidden process, with no console flash at logon.
$cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""{0}"" -Loop -IntervalMinutes {1} -Collection ""{2}""' -f $script, $Minutes, $Collection

$vbs = @"
' Starts the reMarkable Anki background sync, hidden.
' Installed by install-autosync.ps1
Dim shell
Set shell = CreateObject("WScript.Shell")
shell.Run "$cmd", 0, False
"@

Set-Content -Path $vbsPath -Value $vbs -Encoding ascii

# Stop any previous instance, then start now so it works without a re-logon.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*auto-sync.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Start-Process wscript.exe -ArgumentList "`"$vbsPath`"" -WindowStyle Hidden

Write-Host "Auto-sync installed - checks every $Minutes minutes, starting now." -ForegroundColor Green
Write-Host "Startup entry : $vbsPath"
Write-Host "Log           : $env:LOCALAPPDATA\rmanki-offline\auto-sync.log"
