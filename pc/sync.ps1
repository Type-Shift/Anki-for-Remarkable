<#
    One-command sync for the reMarkable offline Anki setup.

      1. pull the tablet's answer queue
      2. apply it to the collection
      3. export a fresh batch of due cards
      4. push the batch back and clear the drained queue
      5. restart the app so it picks up the new batch

    The queue is only cleared after a successful apply, so a failure at any
    point leaves the tablet's reviews intact to retry.

    Usage:
        .\sync.ps1                          # uses the test collection
        .\sync.ps1 -Collection "C:\path\collection.anki2" -Deck "GCSE"
#>
[CmdletBinding()]
param(
    [string]$Device     = '',          # blank = discover by MAC
    [string]$Collection = "$PSScriptRoot\..\test-collection.anki2",
    [string]$Deck       = '',          # blank = every deck with cards due
    [int]   $Limit      = 100,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

# The tablet's WiFi MAC. Discovering by MAC rather than hardcoding an IP means
# this keeps working when the address changes -- a different network, a DHCP
# lease change, or the PC's own mobile hotspot (which uses 192.168.137.x).
$DeviceMac = 'c0-84-7d-38-83-51'

$CachePath = Join-Path $env:LOCALAPPDATA 'rmanki-offline\last-ip.txt'

function Get-MacFromArp {
    param([string]$Mac)
    $entry = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.LinkLayerAddress -eq $Mac -and
                            $_.State -notin @('Unreachable', 'Incomplete') } |
             Select-Object -First 1
    if ($entry) { return $entry.IPAddress }
    return $null
}

function Invoke-SubnetSweep {
    # Concurrent ping sweep to populate the ARP cache. Uses SendPingAsync
    # rather than ForEach-Object -Parallel, which is PowerShell 7 only and
    # this machine runs 5.1.
    $locals = Get-NetIPAddress -AddressFamily IPv4 |
              Where-Object { $_.IPAddress -notlike '127.*' -and
                             $_.IPAddress -notlike '169.254.*' -and
                             $_.PrefixLength -ge 24 }
    foreach ($l in $locals) {
        $prefix = ($l.IPAddress -split '\.')[0..2] -join '.'
        $pings = @()
        $pingers = @()
        foreach ($i in 1..254) {
            $p = New-Object System.Net.NetworkInformation.Ping
            $pingers += $p
            $pings   += $p.SendPingAsync("$prefix.$i", 700)
        }
        [void][System.Threading.Tasks.Task]::WaitAll($pings, 4000)
        foreach ($p in $pingers) { $p.Dispose() }
    }
}

function Find-Device {
    param([string]$Mac)

    # 1. Already in the ARP cache?
    $ip = Get-MacFromArp $Mac
    if ($ip) { return $ip }

    # 2. Last known good address, if it still answers on SSH.
    if (Test-Path $CachePath) {
        $last = (Get-Content $CachePath -Raw).Trim()
        if ($last -and (Test-NetConnection -ComputerName $last -Port 22 `
                        -WarningAction SilentlyContinue).TcpTestSucceeded) {
            return $last
        }
    }

    # 3. Sweep the subnet to populate ARP, then look again.
    Write-Host "    searching the network for the tablet..." -ForegroundColor DarkGray
    Invoke-SubnetSweep
    return Get-MacFromArp $Mac
}

$py      = "$env:LOCALAPPDATA\AnkiProgramFiles\.venv\Scripts\python.exe"
$rmanki  = Join-Path $PSScriptRoot 'rmanki.py'
$workDir = Join-Path $PSScriptRoot '..'
$queue   = Join-Path $workDir 'queue.json'
$batch   = Join-Path $workDir 'batch.json'

$sshOpts = @('-o','BatchMode=yes','-o','ConnectTimeout=15')

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $py))         { Fail "Anki's bundled Python not found at $py" }
if (-not (Test-Path $Collection)) { Fail "Collection not found: $Collection" }

Write-Host "==> locating tablet" -ForegroundColor Cyan
if (-not $Device) {
    $Device = Find-Device $DeviceMac
    if (-not $Device) {
        Fail "Could not find the tablet on any connected network. Wake it, check Wi-Fi is on, or pass -Device <ip>."
    }
}
Write-Host "    $Device"

if (-not (Test-NetConnection -ComputerName $Device -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded) {
    Fail "Tablet found at $Device but SSH is not answering. Is it awake?"
}

# Remember it so the next run skips discovery entirely.
New-Item -ItemType Directory -Force -Path (Split-Path $CachePath) | Out-Null
Set-Content -Path $CachePath -Value $Device -Encoding ascii

# --- 1. pull the queue ------------------------------------------------------

Write-Host "==> pulling answer queue" -ForegroundColor Cyan
$hasQueue = (& ssh @sshOpts "root@$Device" 'test -f /home/root/anki-queue.json && echo YES || echo NO').Trim()

if ($hasQueue -eq 'YES') {
    & scp @sshOpts "root@${Device}:/home/root/anki-queue.json" $queue
    if ($LASTEXITCODE -ne 0) { Fail "Could not copy the queue off the tablet." }

    $n = (Get-Content $queue -Raw | ConvertFrom-Json).answers.Count
    Write-Host "    $n answer(s) to apply"

    # --- 2. apply ----------------------------------------------------------
    Write-Host "==> applying to collection" -ForegroundColor Cyan
    & $py $rmanki apply --collection $Collection --queue $queue
    if ($LASTEXITCODE -ne 0) {
        Fail "Apply failed. The tablet's queue has NOT been cleared; nothing is lost."
    }

    # Only now is it safe to drop the tablet's copy.
    & ssh @sshOpts "root@$Device" 'rm -f /home/root/anki-queue.json'
    Write-Host "    applied and cleared from tablet"
} else {
    Write-Host "    nothing to apply"
}

# --- 3. export a fresh batch ------------------------------------------------

Write-Host "==> exporting due cards" -ForegroundColor Cyan
$exportArgs = @('export', '--collection', $Collection, '--limit', $Limit, '--out', $batch)
if ($Deck) { $exportArgs += @('--deck', $Deck) }   # omitted = every deck due
& $py $rmanki @exportArgs
if ($LASTEXITCODE -ne 0) { Fail "Export failed." }

$parsed    = Get-Content $batch -Raw | ConvertFrom-Json
$cardCount = $parsed.cards.Count
foreach ($d in $parsed.decks) { Write-Host ("    {0,-40} {1}" -f $d.name, $d.count) }

# --- 4. push it back --------------------------------------------------------

Write-Host "==> pushing batch to tablet" -ForegroundColor Cyan
& scp @sshOpts $batch "root@${Device}:/home/root/anki-batch.json"
if ($LASTEXITCODE -ne 0) { Fail "Could not copy the batch to the tablet." }

# --- 5. restart the app -----------------------------------------------------

if (-not $NoRestart) {
    Write-Host "==> restarting app" -ForegroundColor Cyan
    # Normally unnecessary: the app watches the batch file and picks up new
    # cards live. Kept as a fallback, and it re-establishes the sleep
    # inhibitor. setsid detaches it from this SSH session's process group,
    # which plain nohup does not survive.
    $launch = 'killall anki-offline 2>/dev/null; sleep 1; ' +
              'setsid nohup /home/root/run-anki.sh </dev/null >/dev/null 2>&1 & ' +
              'sleep 9; pidof anki-offline || echo DIED'
    $result = (& ssh @sshOpts "root@$Device" $launch) -join ' '
    if ($result -match 'DIED') { Fail "App failed to restart. See /home/root/anki-offline.log" }
}

Write-Host ""
Write-Host "Sync complete: $cardCount card(s) ready on the tablet." -ForegroundColor Green
