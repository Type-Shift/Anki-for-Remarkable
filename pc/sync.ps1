<#
    One-command sync for the reMarkable offline Anki setup.

      1. pull the tablet's answer queue
      2. apply it to the collection
      3. export a fresh batch of due cards
      4. push the batch back and clear the drained queue
      5. optionally restart the app

    The queue is only cleared after a successful apply, so a failure at any
    point leaves the tablet's reviews intact to retry.

    Usage:
        .\sync.ps1
        .\sync.ps1 -Collection "$env:APPDATA\Anki2\User 1\collection.anki2"
        .\sync.ps1 -Deck "GCSE::Physics"

    Close Anki desktop first when using a real collection: it holds a lock.
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

# Device discovery lives in one place so sync and deploy cannot drift apart.
# They already had, and the weaker copy failed to find a tablet that was
# sitting on the network.
. (Join-Path $PSScriptRoot 'lib-device.ps1')

$py      = "$env:LOCALAPPDATA\AnkiProgramFiles\.venv\Scripts\python.exe"
$rmanki  = Join-Path $PSScriptRoot 'rmanki.py'
$workDir = Join-Path $PSScriptRoot '..'
$queue   = Join-Path $workDir 'queue.json'
$batch   = Join-Path $workDir 'batch.json'

# accept-new: the tablet's IP changes with its DHCP lease, and an unknown
# address otherwise fails with "Host key verification failed" under BatchMode.
# Still refuses a CHANGED key for a known host, so this is not blanket trust.
$sshOpts = @('-o','BatchMode=yes','-o','ConnectTimeout=15',
             '-o','StrictHostKeyChecking=accept-new')

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $py))         { Fail "Anki's bundled Python not found at $py" }
if (-not (Test-Path $Collection)) { Fail "Collection not found: $Collection" }

# --- 0. locate the tablet ---------------------------------------------------

Write-Host "==> locating tablet" -ForegroundColor Cyan
if (-not $Device) {
    $Device = Find-RemarkableDevice
    if (-not $Device) {
        Fail "Could not find the tablet on any connected network. Wake it, check Wi-Fi is on, or pass -Device <ip>."
    }
}
Write-Host "    $Device"

if (-not (Test-NetConnection -ComputerName $Device -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded) {
    Fail "Tablet found at $Device but SSH is not answering. Is it awake?"
}
Save-RmAddress $Device

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
