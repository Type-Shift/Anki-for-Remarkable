<#
    Shared reMarkable discovery. Dot-sourced by sync.ps1 and deploy.ps1 so the
    two cannot drift apart -- they already had, and the weaker copy failed to
    find a tablet that was sitting on the network.

    Finds the tablet by MAC rather than a fixed IP, so it keeps working across
    DHCP lease changes, different networks, and a PC-hosted hotspot.
#>

$script:RM_MAC   = 'c0-84-7d-38-83-51'
$script:RM_CACHE = "$env:LOCALAPPDATA\rmanki-offline\last-ip.txt"

function Get-RmMacFromArp {
    $entry = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.LinkLayerAddress -eq $script:RM_MAC -and
                            $_.State -notin @('Unreachable', 'Incomplete') } |
             Select-Object -First 1
    if ($entry) { return $entry.IPAddress }
    return $null
}

function Get-RmSweepTargets {
    <#
        Every address in each connected IPv4 subnet, honouring the real prefix
        length. Deriving a /24 from the host address was the bug: this network
        is a /22 (192.168.68.0-192.168.71.255), so three quarters of it were
        never probed and the tablet could sit unfound at .69/.70/.71.
    #>
    $targets = @()
    $locals = Get-NetIPAddress -AddressFamily IPv4 |
              Where-Object { $_.IPAddress -notlike '127.*' -and
                             $_.IPAddress -notlike '169.254.*' -and
                             $_.PrefixLength -ge 20 }   # cap the work at 4096 hosts

    foreach ($l in $locals) {
        $ipBytes = ([System.Net.IPAddress]::Parse($l.IPAddress)).GetAddressBytes()
        [Array]::Reverse($ipBytes)
        $ipInt = [BitConverter]::ToUInt32($ipBytes, 0)

        $hostBits = 32 - $l.PrefixLength
        $mask     = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, $hostBits))
        $network  = $ipInt -band $mask
        $count    = [uint32][math]::Pow(2, $hostBits)

        # Skip network and broadcast addresses.
        for ($i = 1; $i -lt ($count - 1); $i++) {
            $addr = $network + $i
            $b = [BitConverter]::GetBytes([uint32]$addr)
            [Array]::Reverse($b)
            $targets += ([System.Net.IPAddress]::new($b)).IPAddressToString
        }
    }
    return $targets
}

function Invoke-RmSweep {
    # SendPingAsync rather than ForEach-Object -Parallel, which is PowerShell 7
    # only; this machine runs 5.1.
    $targets = Get-RmSweepTargets
    if ($targets.Count -eq 0) { return }

    $tasks = @(); $pingers = @()
    foreach ($t in $targets) {
        $p = New-Object System.Net.NetworkInformation.Ping
        $pingers += $p
        $tasks   += $p.SendPingAsync($t, 900)
    }
    # Generous: an under-short wait meant ARP had not populated by the time we
    # looked, and discovery reported "not found" for a device that was there.
    [void][System.Threading.Tasks.Task]::WaitAll($tasks, 25000)
    foreach ($p in $pingers) { $p.Dispose() }

    Start-Sleep -Milliseconds 800     # let the ARP cache settle
}

function Find-RemarkableDevice {
    param([switch]$Quiet)

    $ip = Get-RmMacFromArp
    if ($ip) { return $ip }

    if (Test-Path $script:RM_CACHE) {
        $last = (Get-Content $script:RM_CACHE -Raw).Trim()
        if ($last -and (Test-NetConnection -ComputerName $last -Port 22 `
                        -WarningAction SilentlyContinue).TcpTestSucceeded) {
            return $last
        }
    }

    if (-not $Quiet) {
        Write-Host "    searching the network for the tablet..." -ForegroundColor DarkGray
    }
    Invoke-RmSweep
    return Get-RmMacFromArp
}

function Save-RmAddress {
    param([string]$Address)
    New-Item -ItemType Directory -Force -Path (Split-Path $script:RM_CACHE) | Out-Null
    Set-Content -Path $script:RM_CACHE -Value $Address -Encoding ascii
}
