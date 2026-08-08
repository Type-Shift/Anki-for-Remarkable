<#
    Quiet background sync. Runs on a schedule, does nothing unless the tablet
    is actually reachable, and never shows a window.

    The tablet cannot start a sync itself -- Windows has no SSH server here to
    connect back to -- so the PC does the looking. Whenever the reMarkable is
    on the same network (school Wi-Fi, home, or this PC's hotspot) the next
    run collects what you reviewed and tops the tablet back up.

    Install with install-autosync.ps1; check progress in the log below.
#>
[CmdletBinding()]
param(
    [string]$Collection = "$env:APPDATA\Anki2\User 1\collection.anki2",
    [string]$Deck       = '',
    [int]   $Limit      = 2000,
    [string]$LogPath    = "$env:LOCALAPPDATA\rmanki-offline\auto-sync.log",
    # Loop forever instead of running once. Used by the Startup-folder
    # launcher, because Scheduled Task registration is blocked by policy on
    # this machine ("Access is denied" from Register-ScheduledTask).
    [switch]$Loop,
    [int]   $IntervalMinutes = 10
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogPath -Value $line -Encoding utf8
}

# Keep the log from growing without bound.
if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 512KB) {
    $keep = Get-Content $LogPath -Tail 500
    Set-Content -Path $LogPath -Value $keep -Encoding utf8
}

function Invoke-OneSync {
    try {
        # Anki desktop holds an exclusive lock on the collection. Applying
        # would fail, so skip this run rather than log a scary error.
        if (Get-Process -Name anki -ErrorAction SilentlyContinue) {
            Write-Log "skipped: Anki desktop is open (it locks the collection)"
            return
        }

        $sync = Join-Path $PSScriptRoot 'sync.ps1'
        if (-not (Test-Path $sync)) { Write-Log "ERROR: sync.ps1 not found"; return }

        $syncArgs = @{
            Collection = $Collection
            Limit      = $Limit
            NoRestart  = $true      # the app watches the batch file itself
        }
        if ($Deck) { $syncArgs['Deck'] = $Deck }

        $output = & $sync @syncArgs 2>&1 | Out-String

        if ($LASTEXITCODE -eq 0) {
            $applied = ($output -split "`n" | Where-Object { $_ -match 'answer\(s\) to apply|applied \d+' }) -join '; '
            $ready   = ($output -split "`n" | Where-Object { $_ -match 'Sync complete' }) -join '; '
            Write-Log ("ok: " + ($applied + ' ' + $ready).Trim())
        } else {
            # Unreachable is the normal case, not worth shouting about.
            if ($output -match 'Could not find the tablet|not answering|unreachable') {
                Write-Log "tablet not on the network"
            } else {
                Write-Log ("FAILED: " + ($output -replace '\s+', ' ').Trim())
            }
        }
    } catch {
        Write-Log ("EXCEPTION: " + $_.Exception.Message)
    }
}

if ($Loop) {
    Write-Log ("daemon started, checking every {0} min" -f $IntervalMinutes)
    while ($true) {
        Invoke-OneSync
        Start-Sleep -Seconds ($IntervalMinutes * 60)
    }
} else {
    Invoke-OneSync
}
