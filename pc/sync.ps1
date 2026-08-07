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
    [string]$Device     = '192.168.68.64',
    [string]$Collection = "$PSScriptRoot\..\test-collection.anki2",
    [string]$Deck       = 'Offline Test',
    [int]   $Limit      = 100,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

$py      = "$env:LOCALAPPDATA\AnkiProgramFiles\.venv\Scripts\python.exe"
$rmanki  = Join-Path $PSScriptRoot 'rmanki.py'
$workDir = Join-Path $PSScriptRoot '..'
$queue   = Join-Path $workDir 'queue.json'
$batch   = Join-Path $workDir 'batch.json'

$sshOpts = @('-o','BatchMode=yes','-o','ConnectTimeout=15')

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $py))         { Fail "Anki's bundled Python not found at $py" }
if (-not (Test-Path $Collection)) { Fail "Collection not found: $Collection" }

Write-Host "==> checking tablet" -ForegroundColor Cyan
if (-not (Test-NetConnection -ComputerName $Device -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded) {
    Fail "Tablet unreachable at $Device. Wake it and make sure Wi-Fi is on."
}

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
& $py $rmanki export --collection $Collection --deck $Deck --limit $Limit --out $batch
if ($LASTEXITCODE -ne 0) { Fail "Export failed." }

$cardCount = (Get-Content $batch -Raw | ConvertFrom-Json).cards.Count

# --- 4. push it back --------------------------------------------------------

Write-Host "==> pushing batch to tablet" -ForegroundColor Cyan
& scp @sshOpts $batch "root@${Device}:/home/root/anki-batch.json"
if ($LASTEXITCODE -ne 0) { Fail "Could not copy the batch to the tablet." }

# --- 5. restart the app -----------------------------------------------------

if (-not $NoRestart) {
    Write-Host "==> restarting app" -ForegroundColor Cyan
    # The app reads the batch once at startup, so it needs a restart to see
    # new cards. setsid detaches it from this SSH session's process group.
    $launch = 'killall anki-offline 2>/dev/null; sleep 1; systemctl stop xochitl; sleep 1; ' +
              'cd /home/root; QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS=rotate=180 ' +
              'QT_QUICK_BACKEND=epaper setsid nohup /home/root/anki-offline -platform epaper ' +
              '</dev/null > /home/root/anki-offline.log 2>&1 & sleep 8; ' +
              'pidof anki-offline || echo DIED'
    $result = (& ssh @sshOpts "root@$Device" $launch) -join ' '
    if ($result -match 'DIED') { Fail "App failed to restart. See /home/root/anki-offline.log" }
}

Write-Host ""
Write-Host "Sync complete: $cardCount card(s) ready on the tablet." -ForegroundColor Green
