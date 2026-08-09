<#
    Fetch the latest CI-built binary and install it on the reMarkable.

        .\deploy.ps1                 # deploy app + scripts, then start it
        .\deploy.ps1 -InstallLauncher # also enable the boot-time launcher
        .\deploy.ps1 -RemoveLauncher  # go back to a stock reMarkable

    Finds the tablet by MAC, so it works on school Wi-Fi, at home, or on a
    PC-hosted hotspot without editing anything.

    If the tablet is ever left in a bad state, the escape hatch is:
        ssh root@<ip> "systemctl disable --now anki-launcher; systemctl start xochitl"
#>
[CmdletBinding()]
param(
    [string]$Device = '',
    [switch]$InstallLauncher,
    [switch]$RemoveLauncher,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$Repo      = 'Type-Shift/Anki-for-Remarkable'
$DeviceMac = 'c0-84-7d-38-83-51'
$TokenPath = "$env:LOCALAPPDATA\rmanki-offline\gh-token.txt"
$CachePath = "$env:LOCALAPPDATA\rmanki-offline\last-ip.txt"
$DeviceDir = Join-Path $PSScriptRoot '..\device'

# accept-new: the tablet's IP changes with its DHCP lease, and an unknown
# address otherwise fails with "Host key verification failed" under BatchMode.
# Still refuses a CHANGED key for a known host, so this is not blanket trust.
$sshOpts = @('-o','BatchMode=yes','-o','ConnectTimeout=20','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=8',
             '-o','StrictHostKeyChecking=accept-new')

function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Get-Token {
    if (-not (Test-Path $TokenPath)) { Fail "No GitHub token at $TokenPath" }
    $raw = [System.IO.File]::ReadAllText($TokenPath).TrimStart([char]0xFEFF).Trim()
    $sec = $raw | ConvertTo-SecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

# Device discovery lives in one place so sync and deploy cannot drift apart.
. (Join-Path $PSScriptRoot 'lib-device.ps1')
# --- locate ----------------------------------------------------------------

Write-Host "==> locating tablet" -ForegroundColor Cyan
if (-not $Device) { $Device = Find-RemarkableDevice }
if (-not $Device) {
    Fail "Tablet not found. Wake it, confirm Wi-Fi is on, or pass -Device <ip>."
}
if (-not (Test-NetConnection -ComputerName $Device -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded) {
    Fail "Found $Device but SSH is not answering. Is the tablet awake?"
}
Write-Host "    $Device"
New-Item -ItemType Directory -Force -Path (Split-Path $CachePath) | Out-Null
Save-RmAddress $Device

# --- removal short-circuit --------------------------------------------------

if ($RemoveLauncher) {
    Write-Host "==> removing boot launcher" -ForegroundColor Cyan
    & ssh @sshOpts "root@$Device" '/home/root/install-launcher.sh uninstall'
    exit $LASTEXITCODE
}

# --- fetch artifact ---------------------------------------------------------

Write-Host "==> fetching latest CI build" -ForegroundColor Cyan
$h = @{ Authorization = "Bearer $(Get-Token)"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'rmanki-deploy' }

$arts = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/artifacts" `
                          -Headers $h -TimeoutSec 30
if (-not $arts.artifacts) { Fail "No build artifacts found." }
$art = $arts.artifacts[0]

$zip  = Join-Path $env:TEMP 'rmanki-deploy.zip'
$dest = Join-Path $env:TEMP 'rmanki-deploy'

# Invoke-WebRequest buffers the whole body and kept failing on this artifact
# with "connection forcibly closed". HttpClient streams straight to disk and
# succeeds where it does not.
Add-Type -AssemblyName System.Net.Http
$hc = New-Object System.Net.Http.HttpClient
try {
    $hc.Timeout = [TimeSpan]::FromMinutes(10)
    $hc.DefaultRequestHeaders.Add('Authorization', "Bearer $(Get-Token)")
    $hc.DefaultRequestHeaders.Add('User-Agent', 'rmanki-deploy')
    $resp = $hc.GetAsync($art.archive_download_url,
                         [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) { Fail "Artifact download failed: $($resp.StatusCode)" }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    $fs = [System.IO.File]::Create($zip)
    try   { $resp.Content.CopyToAsync($fs).GetAwaiter().GetResult() }
    finally { $fs.Close() }
} finally {
    $hc.Dispose()
}
Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip -DestinationPath $dest
$bin = (Get-ChildItem $dest -File | Select-Object -First 1).FullName
Write-Host ("    {0:N0} bytes" -f (Get-Item $bin).Length)

# --- copy -------------------------------------------------------------------
# Staged as .new then moved, so an interrupted transfer never replaces a
# working binary with a truncated one.

# Hold the tablet awake for the duration. At 29 MB the copy takes minutes over
# the tablet's Wi-Fi, and if the app is not running nothing holds a sleep
# inhibitor -- the device suspends mid-copy and the transfer times out.
Write-Host "==> holding tablet awake" -ForegroundColor Cyan
& ssh @sshOpts "root@$Device" 'setsid nohup systemd-inhibit --what=sleep:idle --who=deploy --why="Receiving update" sleep 1800 </dev/null >/dev/null 2>&1 & echo held'

Write-Host "==> copying to tablet (slow over the tablet's Wi-Fi)" -ForegroundColor Cyan
& scp -C @sshOpts $bin "root@${Device}:/home/root/anki-offline.new"
$copyRc = $LASTEXITCODE
if ($copyRc -ne 0) {
    & ssh @sshOpts "root@$Device" 'pkill -f "systemd-inhibit --what=sleep:idle --who=deploy" 2>/dev/null; true'
    Fail "Binary transfer failed; the existing app is untouched."
}

& scp @sshOpts `
    (Join-Path $DeviceDir 'run-anki.sh') `
    (Join-Path $DeviceDir 'install-launcher.sh') `
    (Join-Path $DeviceDir 'anki-launcher.service') `
    "root@${Device}:/home/root/"
if ($LASTEXITCODE -ne 0) { Fail "Script transfer failed." }

$localHash = (Get-FileHash $bin -Algorithm SHA256).Hash.ToLower()
$remoteHash = (& ssh @sshOpts "root@$Device" 'sha256sum /home/root/anki-offline.new').Split(' ')[0]
if ($localHash -ne $remoteHash) { Fail "Checksum mismatch after transfer. Not installing." }
Write-Host "    checksum verified"

& ssh @sshOpts "root@$Device" 'killall anki-offline 2>/dev/null; sleep 1; mv /home/root/anki-offline.new /home/root/anki-offline; chmod +x /home/root/anki-offline /home/root/run-anki.sh /home/root/install-launcher.sh'

# --- launcher ---------------------------------------------------------------

if ($InstallLauncher) {
    Write-Host "==> installing boot launcher" -ForegroundColor Cyan
    & ssh @sshOpts "root@$Device" '/home/root/install-launcher.sh install'
}

# --- start ------------------------------------------------------------------

if (-not $NoStart) {
    Write-Host "==> starting app" -ForegroundColor Cyan
    $launch = 'killall anki-offline 2>/dev/null; sleep 1; ' +
              'setsid nohup /home/root/run-anki.sh </dev/null >/dev/null 2>&1 & ' +
              'sleep 10; pidof anki-offline || echo DIED'
    $res = (& ssh @sshOpts "root@$Device" $launch) -join ' '
    if ($res -match 'DIED') {
        Write-Host "App did not start. Log:" -ForegroundColor Red
        & ssh @sshOpts "root@$Device" 'tail -n 15 /home/root/anki-offline.log'
        exit 1
    }
    Write-Host "    running (pid $($res.Trim()))"
}

# Release the deploy-time inhibitor; the app holds its own while it runs.
& ssh @sshOpts "root@$Device" 'pkill -f "systemd-inhibit --what=sleep:idle --who=deploy" 2>/dev/null; true'

& ssh @sshOpts "root@$Device" '/home/root/install-launcher.sh status'
Write-Host ""
Write-Host "Deploy complete." -ForegroundColor Green
