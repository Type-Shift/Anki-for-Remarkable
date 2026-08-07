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

$sshOpts = @('-o','BatchMode=yes','-o','ConnectTimeout=20')

function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Get-Token {
    if (-not (Test-Path $TokenPath)) { Fail "No GitHub token at $TokenPath" }
    $raw = [System.IO.File]::ReadAllText($TokenPath).TrimStart([char]0xFEFF).Trim()
    $sec = $raw | ConvertTo-SecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

function Get-MacFromArp {
    $entry = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.LinkLayerAddress -eq $DeviceMac -and
                            $_.State -notin @('Unreachable','Incomplete') } |
             Select-Object -First 1
    if ($entry) { return $entry.IPAddress }
    return $null
}

function Invoke-SubnetSweep {
    # Populate the ARP cache. SendPingAsync, not ForEach-Object -Parallel,
    # which is PowerShell 7 only; this machine runs 5.1.
    $locals = Get-NetIPAddress -AddressFamily IPv4 |
              Where-Object { $_.IPAddress -notlike '127.*' -and
                             $_.IPAddress -notlike '169.254.*' -and
                             $_.PrefixLength -ge 22 }
    foreach ($l in $locals) {
        $prefix = ($l.IPAddress -split '\.')[0..2] -join '.'
        $tasks = @(); $pingers = @()
        foreach ($i in 1..254) {
            $p = New-Object System.Net.NetworkInformation.Ping
            $pingers += $p
            $tasks   += $p.SendPingAsync("$prefix.$i", 700)
        }
        [void][System.Threading.Tasks.Task]::WaitAll($tasks, 5000)
        foreach ($p in $pingers) { $p.Dispose() }
    }
}

function Find-Device {
    # An ARP-only lookup was why this failed when the tablet was asleep:
    # nothing in the cache, no cache file yet, and it gave up immediately.
    $ip = Get-MacFromArp
    if ($ip) { return $ip }

    if (Test-Path $CachePath) {
        $last = (Get-Content $CachePath -Raw).Trim()
        if ($last -and (Test-NetConnection -ComputerName $last -Port 22 `
                        -WarningAction SilentlyContinue).TcpTestSucceeded) { return $last }
    }

    Write-Host "    searching the network for the tablet..." -ForegroundColor DarkGray
    Invoke-SubnetSweep
    return Get-MacFromArp
}

# --- locate ----------------------------------------------------------------

Write-Host "==> locating tablet" -ForegroundColor Cyan
if (-not $Device) { $Device = Find-Device }
if (-not $Device) {
    Fail "Tablet not found. Wake it, confirm Wi-Fi is on, or pass -Device <ip>."
}
if (-not (Test-NetConnection -ComputerName $Device -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded) {
    Fail "Found $Device but SSH is not answering. Is the tablet awake?"
}
Write-Host "    $Device"
New-Item -ItemType Directory -Force -Path (Split-Path $CachePath) | Out-Null
Set-Content -Path $CachePath -Value $Device -Encoding ascii

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
Invoke-WebRequest -Uri $art.archive_download_url -Headers $h -OutFile $zip -TimeoutSec 300
Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip -DestinationPath $dest
$bin = (Get-ChildItem $dest -File | Select-Object -First 1).FullName
Write-Host ("    {0:N0} bytes" -f (Get-Item $bin).Length)

# --- copy -------------------------------------------------------------------
# Staged as .new then moved, so an interrupted transfer never replaces a
# working binary with a truncated one.

Write-Host "==> copying to tablet (slow over the tablet's Wi-Fi)" -ForegroundColor Cyan
& scp @sshOpts $bin "root@${Device}:/home/root/anki-offline.new"
if ($LASTEXITCODE -ne 0) { Fail "Binary transfer failed; the existing app is untouched." }

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

& ssh @sshOpts "root@$Device" '/home/root/install-launcher.sh status'
Write-Host ""
Write-Host "Deploy complete." -ForegroundColor Green
