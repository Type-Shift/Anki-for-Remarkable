<#
    Move a real Anki collection between the PC and the tablet.

        .\collection.ps1 push     # PC  -> tablet
        .\collection.ps1 pull     # tablet -> PC
        .\collection.ps1 status

    With Anki's own backend on the device the tablet holds a genuine
    collection.anki2 and schedules against it directly, so there is no batch
    file and no answer queue any more.

    This is a FILE-level move, not a merge. Whichever side you copy over is
    replaced wholesale. That is safe as long as you treat one side as
    authoritative at a time, and every overwrite is backed up first.

    A proper two-way sync needs rslib's sync client, which is still pending;
    until then, discipline plus backups is the honest arrangement.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('push', 'pull', 'status')]
    [string]$Action = 'status',

    [string]$Device     = '',
    [string]$Collection = "$env:APPDATA\Anki2\User 1\collection.anki2",
    [string]$RemotePath = '/home/root/collection.anki2',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib-device.ps1')

$BackupDir = Join-Path $env:USERPROFILE 'rmanki-offline\backups'
$sshOpts = @('-o','BatchMode=yes','-o','ConnectTimeout=20',
             '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=8',
             '-o','StrictHostKeyChecking=accept-new')

function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Backup-File {
    param([string]$Path, [string]$Tag)
    if (-not (Test-Path $Path)) { return $null }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $BackupDir "collection-$Tag-$stamp.anki2"
    Copy-Item $Path $dest
    return $dest
}

# --- locate -----------------------------------------------------------------

Write-Host "==> locating tablet" -ForegroundColor Cyan
if (-not $Device) { $Device = Find-RemarkableDevice }
if (-not $Device) { Fail "Tablet not found. Wake it, or pass -Device <ip>." }
if (-not (Test-NetConnection -ComputerName $Device -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded) {
    Fail "Found $Device but SSH is not answering."
}
Write-Host "    $Device"
Save-RmAddress $Device

# --- status -----------------------------------------------------------------

if ($Action -eq 'status') {
    Write-Host "==> PC" -ForegroundColor Cyan
    if (Test-Path $Collection) {
        $f = Get-Item $Collection
        "    {0}  {1:N2} MB  modified {2}" -f $f.Name, ($f.Length/1MB), $f.LastWriteTime
    } else { "    no collection at $Collection" }

    Write-Host "==> tablet" -ForegroundColor Cyan
    & ssh @sshOpts "root@$Device" "ls -la $RemotePath 2>/dev/null || echo '    no collection on device'"

    Write-Host "==> backups" -ForegroundColor Cyan
    if (Test-Path $BackupDir) {
        Get-ChildItem $BackupDir -Filter '*.anki2' |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 5 |
            ForEach-Object { "    {0}  {1:N2} MB" -f $_.Name, ($_.Length/1MB) }
    } else { "    none yet" }
    return
}

# Anki desktop holds an exclusive lock, and copying a half-written SQLite
# file produces a collection that opens but is subtly wrong.
if (Get-Process -Name anki -ErrorAction SilentlyContinue) {
    Fail "Close Anki desktop first: it locks the collection."
}

# --- push -------------------------------------------------------------------

if ($Action -eq 'push') {
    if (-not (Test-Path $Collection)) { Fail "No collection at $Collection" }

    $existing = (& ssh @sshOpts "root@$Device" "test -f $RemotePath && echo YES || echo NO").Trim()
    if ($existing -eq 'YES' -and -not $Force) {
        Write-Host "The tablet already has a collection." -ForegroundColor Yellow
        Write-Host "Pushing replaces it, discarding anything reviewed there but not pulled back."
        Write-Host "Pull first, or re-run with -Force."
        exit 1
    }

    $bak = Backup-File -Path $Collection -Tag 'pc-before-push'
    if ($bak) { Write-Host "    backed up PC copy: $bak" }

    Write-Host "==> pushing to tablet" -ForegroundColor Cyan
    & scp -C @sshOpts $Collection "root@${Device}:${RemotePath}.new"
    if ($LASTEXITCODE -ne 0) { Fail "Transfer failed; the tablet's collection is untouched." }

    $local  = (Get-FileHash $Collection -Algorithm SHA256).Hash.ToLower()
    $remote = (& ssh @sshOpts "root@$Device" "sha256sum ${RemotePath}.new").Split(' ')[0]
    if ($local -ne $remote) { Fail "Checksum mismatch after transfer. Not installing." }
    Write-Host "    checksum verified"

    # Only swap in once the copy is proven, so an interrupted transfer can
    # never leave a truncated collection in place.
    & ssh @sshOpts "root@$Device" "mv ${RemotePath}.new ${RemotePath}"
    Write-Host "Pushed." -ForegroundColor Green
    return
}

# --- pull -------------------------------------------------------------------

if ($Action -eq 'pull') {
    $existing = (& ssh @sshOpts "root@$Device" "test -f $RemotePath && echo YES || echo NO").Trim()
    if ($existing -ne 'YES') { Fail "No collection on the tablet at $RemotePath" }

    $bak = Backup-File -Path $Collection -Tag 'pc-before-pull'
    if ($bak) { Write-Host "    backed up PC copy: $bak" }

    $tmp = Join-Path $env:TEMP 'collection-from-tablet.anki2'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue

    Write-Host "==> pulling from tablet" -ForegroundColor Cyan
    & scp -C @sshOpts "root@${Device}:${RemotePath}" $tmp
    if ($LASTEXITCODE -ne 0) { Fail "Transfer failed; the PC copy is untouched." }

    $remote = (& ssh @sshOpts "root@$Device" "sha256sum ${RemotePath}").Split(' ')[0]
    $local  = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
    if ($local -ne $remote) { Fail "Checksum mismatch after transfer. Not installing." }
    Write-Host "    checksum verified"

    Copy-Item $tmp $Collection -Force
    Write-Host "Pulled." -ForegroundColor Green
    return
}
