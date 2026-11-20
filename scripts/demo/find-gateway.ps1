<#
.SYNOPSIS
Find the gateway on a phone hotspot or another small network: try TCP port 9000 (gwmon) on
every address of a /24 and print the status line of each address that answers.

.DESCRIPTION
On a phone hotspot the Pi has no name to look up: the image has no mDNS, and on Wi-Fi it does
not send its host name with its DHCP request (docs/demo-day.md, Wi-Fi risks). gwmon answers on
port 9000 on every interface, so a short scan finds it. Nothing is sent to the Pi but a TCP
connect; gwmon prints one line and closes.

.PARAMETER Subnet
The first three numbers of the network, for example 172.20.10 (iPhone hotspot) or
192.168.137 (Windows Internet Connection Sharing). Default: the network of this PC's Wi-Fi
adapter.

.PARAMETER Port
Default 9000.

.PARAMETER TimeoutMs
How long to wait for each address. Default 400 ms; all addresses are tried at once.

.EXAMPLE
.\scripts\demo\find-gateway.ps1
.\scripts\demo\find-gateway.ps1 -Subnet 192.168.137

This script was partially generated using Claude Code using the chat session at:
Link to chat session (issue #9): ISSUE9_SESSION_LINK
#>
param(
    [string]$Subnet,
    [int]$Port = 9000,
    [int]$TimeoutMs = 400
)

if (-not $Subnet) {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -match 'Wi-?Fi|Wireless|WLAN' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1
    if (-not $ip) { Write-Error 'No IPv4 address on a Wi-Fi adapter. Give -Subnet, for example -Subnet 172.20.10'; exit 2 }
    $Subnet = ($ip.IPAddress -split '\.')[0..2] -join '.'
}
Write-Output "find-gateway: trying $Subnet.1 to $Subnet.254 on TCP $Port"

$tries = foreach ($n in 1..254) {
    $client = New-Object System.Net.Sockets.TcpClient
    [pscustomobject]@{ Address = "$Subnet.$n"; Client = $client; Task = $client.ConnectAsync("$Subnet.$n", $Port) }
}
Start-Sleep -Milliseconds $TimeoutMs

$found = 0
foreach ($t in $tries) {
    if ($t.Task.Status -eq 'RanToCompletion' -and $t.Client.Connected) {
        $line = ''
        try {
            $stream = $t.Client.GetStream()
            $stream.ReadTimeout = 2000
            $line = (New-Object System.IO.StreamReader($stream)).ReadLine()
        } catch { $line = '(connected, but no status line)' }
        Write-Output "$($t.Address): $line"
        $found++
    }
    $t.Client.Close()
}
if ($found -eq 0) {
    Write-Output "find-gateway: nothing answered on $Subnet.x port $Port. The Pi may still be booting (about 60 s on Wi-Fi), on another network, or the hotspot may block traffic between its clients."
    exit 1
}
exit 0
