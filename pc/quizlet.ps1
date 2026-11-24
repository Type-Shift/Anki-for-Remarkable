<#
    Quizlet set -> flashcard deck -> reMarkable, in one command.

        .\quizlet.ps1 -Url https://quizlet.com/123456/french-food-flash-cards/
        .\quizlet.ps1 -From export.txt -Title "French Food"

    -Url is the requested path but is NOT verified working: Quizlet answers
    plain HTTP clients with a PerimeterX captcha page (HTTP 403), from this
    network and from an off-network fetcher alike, so the wall is Quizlet's,
    not the school's. When it refuses, quizlet2rm.py prints the export recipe
    and you rerun with -From.

    -From takes the text out of Quizlet's own Export box (separators Tab and
    New line), which is already this deck format.

    The deck lands at $env:USERPROFILE\rmanki-offline\decks\<name>.tsv on the
    PC and /home/root/flashcards/<name>.tsv on the tablet. Nothing else on
    the device is touched -- in particular not collection.anki2 -- and the
    Anki app is deliberately not restarted.
#>
[CmdletBinding()]
param(
    [string]$Url,
    [string]$From,
    [string]$Title,
    [string]$Device = '',
    [int]$WaitMinutes = 5,
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib-device.ps1')

$RemoteDir = '/home/root/flashcards'
$DeckDir = Join-Path $env:USERPROFILE 'rmanki-offline\decks'
$Py = Join-Path $PSScriptRoot 'quizlet2rm.py'

function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not $Url -and -not $From) { Fail 'give either -Url or -From <export file>' }
if ($From -and -not $Title) { Fail '-From needs -Title (the deck name)' }

# --- build the deck file ----------------------------------------------------

New-Item -ItemType Directory -Force -Path $DeckDir | Out-Null

if ($Url) {
    $args = @('fetch', '--url', $Url, '--out-dir', $DeckDir)
    if ($Title) { $args += @('--title', $Title) }
}
else {
    if (-not (Test-Path $From)) { Fail "no such file: $From" }
    $args = @('paste', '--title', $Title, '--in', (Resolve-Path $From).Path,
              '--out-dir', $DeckDir)
}

# -I keeps the interpreter from importing anything out of the working
# directory; this script only ever runs stdlib.
$before = Get-ChildItem -Path $DeckDir -Filter *.tsv -ErrorAction SilentlyContinue |
          Select-Object -ExpandProperty FullName
& python -I $Py @args
if ($LASTEXITCODE -ne 0) { Fail 'could not build the deck file' }

# quizlet2rm.py derives the filename from the set title, so find what it wrote.
$deck = Get-ChildItem -Path $DeckDir -Filter *.tsv |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $deck) { Fail 'no deck file was produced' }

Write-Host ''
Write-Host "deck: $($deck.FullName)" -ForegroundColor Cyan
Get-Content -LiteralPath $deck.FullName -TotalCount 8 |
    ForEach-Object { "    $($_ -replace "`t", '  |  ')" }
$cards = (Get-Content -LiteralPath $deck.FullName | Measure-Object -Line).Lines
Write-Host "    ($cards cards)"

if ($NoPush) { Write-Host 'left on the PC (-NoPush)'; exit 0 }

# --- push it to the tablet --------------------------------------------------

# The name is ASCII, space-free and metacharacter-free by construction
# (safe_deck_name in quizlet2rm.py), so it needs no remote quoting.
$name = $deck.Name
if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.tsv$') {
    Fail "refusing to scp an unsafe deck name: $name"
}

if (-not $Device) {
    # The tablet is often still booting or being plugged in, so wait for it.
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    do {
        $Device = Find-RemarkableDevice
        if ($Device) { break }
        Write-Host '    no tablet yet, retrying...' -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
}
if (-not $Device) { Fail "no tablet found in $WaitMinutes min (USB, or same Wi-Fi?)" }

$sshOpts = Get-RmSshOpts
Write-Host "tablet: $Device" -ForegroundColor Cyan

function Invoke-RmRetry {
    param([scriptblock]$Action, [string]$What)
    # The other agent's deploy restarts the app and briefly disturbs ssh.
    for ($i = 1; $i -le 4; $i++) {
        try { return & $Action }
        catch {
            if ($i -eq 4) { Fail "$What failed: $($_.Exception.Message)" }
            Write-Host "    $What failed, retry $i..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 10
        }
    }
}

Reset-RmHostKey $Device | Out-Null

Invoke-RmRetry -What 'mkdir' -Action {
    & ssh @sshOpts "root@$Device" "mkdir -p $RemoteDir"
    if ($LASTEXITCODE -ne 0) { throw "ssh exit $LASTEXITCODE" }
}

Invoke-RmRetry -What 'scp' -Action {
    & scp @sshOpts $deck.FullName "root@${Device}:$RemoteDir/$name"
    if ($LASTEXITCODE -ne 0) { throw "scp exit $LASTEXITCODE" }
}

# BusyBox: -n on head/tail, no getent, so keep remote commands plain.
$listing = Invoke-RmRetry -What 'verify' -Action {
    $out = & ssh @sshOpts "root@$Device" "ls -l $RemoteDir/$name; wc -l < $RemoteDir/$name"
    if ($LASTEXITCODE -ne 0) { throw "ssh exit $LASTEXITCODE" }
    return $out
}

Write-Host ''
Write-Host "on the tablet at $RemoteDir/$name" -ForegroundColor Green
$listing | ForEach-Object { "    $_" }
