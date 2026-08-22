<#
    Shared reMarkable discovery. Dot-sourced by sync.ps1 and deploy.ps1 so the
    two cannot drift apart -- they already had, and the weaker copy failed to
    find a tablet that was sitting on the network.

    Finds the tablet by MAC rather than a fixed IP, so it keeps working across
    DHCP lease changes, different networks, and a PC-hosted hotspot.
#>

$script:RM_MAC   = 'c0-84-7d-38-83-51'
$script:RM_CACHE = "$env:LOCALAPPDATA\rmanki-offline\last-ip.txt"
$script:RM_PORT  = 22

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
        length. Deriving a /24 from the host address was the bug: one network
        here is a /22 (192.168.68.0-192.168.71.255), so three quarters of it
        were never probed and the tablet could sit unfound at .69/.70/.71.
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

function Invoke-RmTcpSweep {
    <#
        Probe port 22 rather than ICMP. The tablet does not answer ping at all
        -- an ICMP sweep finds nothing and reports "Tablet not found" for a
        device that is sitting right there answering SSH. A TCP SYN also forces
        ARP resolution, so it populates the neighbour table either way.

        Returns every address whose port 22 accepted a connection.
    #>
    $targets = Get-RmSweepTargets
    if ($targets.Count -eq 0) { return @() }

    # Async connects rather than ForEach-Object -Parallel, which is PowerShell 7
    # only; this machine runs 5.1.
    $clients = @(); $tasks = @()
    foreach ($t in $targets) {
        $c = New-Object System.Net.Sockets.TcpClient
        $clients += $c
        $tasks   += $c.ConnectAsync($t, $script:RM_PORT)
    }

    # Unreachable addresses do not fail fast, so the wait has to cover the OS
    # SYN retry window rather than the round trip to a host that is present.
    [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks, 12000)

    $found = @()
    for ($i = 0; $i -lt $clients.Count; $i++) {
        if ($tasks[$i].Status -eq 'RanToCompletion' -and $clients[$i].Connected) {
            $found += $targets[$i]
        }
        $clients[$i].Close()
    }
    return $found
}

function Test-RmIsRemarkable {
    <#
        A host answering SSH is not necessarily the tablet. Confirm by MAC
        before we start pushing binaries at it.
    #>
    param([string]$Address)
    $n = Get-NetNeighbor -IPAddress $Address -ErrorAction SilentlyContinue |
         Select-Object -First 1
    return ($n -and $n.LinkLayerAddress -eq $script:RM_MAC)
}

function Find-RemarkableDevice {
    param([switch]$Quiet)

    $ip = Get-RmMacFromArp
    if ($ip) { return $ip }

    if (Test-Path $script:RM_CACHE) {
        $last = (Get-Content $script:RM_CACHE -Raw).Trim()
        if ($last -and (Test-NetConnection -ComputerName $last -Port $script:RM_PORT `
                        -WarningAction SilentlyContinue).TcpTestSucceeded) {
            return $last
        }
    }

    if (-not $Quiet) {
        Write-Host "    searching the network for the tablet..." -ForegroundColor DarkGray
    }

    $hosts = Invoke-RmTcpSweep

    # The sweep just forced ARP resolution across the subnet, so the neighbour
    # table is the most reliable answer now.
    $ip = Get-RmMacFromArp
    if ($ip) { return $ip }

    foreach ($h in $hosts) {
        if (Test-RmIsRemarkable $h) { return $h }
    }
    return $null
}

function Save-RmAddress {
    param([string]$Address)
    New-Item -ItemType Directory -Force -Path (Split-Path $script:RM_CACHE) | Out-Null
    Set-Content -Path $script:RM_CACHE -Value $Address -Encoding ascii
}
