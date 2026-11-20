<#
.SYNOPSIS
Make the USB-connected test node send one uplink: open its serial port, send one command line,
and print what the node answers for a few seconds.

.DESCRIPTION
The test node does not transmit on a schedule. It sends one confirmed uplink when it gets a
command over its USB serial port (docs/demo-day.md, "The test node"). This script only writes
the command you give it; it holds no node keys and changes nothing on the node.

.PARAMETER List
Print the serial ports of this PC and exit.

.PARAMETER Port
The node's serial port, for example COM5 (see -List, or Device Manager, "Ports (COM & LPT)").

.PARAMETER Command
The command line that makes the node send one uplink. There is no default: see
docs/demo-day.md for the command.

.PARAMETER Baud
Default 115200.

.PARAMETER LineEnding
What ends the command: CRLF (default), LF or CR.

.PARAMETER Seconds
How long to print the node's answer. Default 15 s, enough for a confirmed uplink and its
acknowledgement in the first receive window.

.EXAMPLE
.\scripts\demo\send-uplink.ps1 -List
.\scripts\demo\send-uplink.ps1 -Port COM5 -Command "<command from docs/demo-day.md>"

This script was partially generated using Claude Code using the chat session at:
Link to chat session (issue #9): ISSUE9_SESSION_LINK
#>
param(
    [switch]$List,
    [string]$Port,
    [string]$Command,
    [int]$Baud = 115200,
    [ValidateSet('CRLF', 'LF', 'CR')][string]$LineEnding = 'CRLF',
    [int]$Seconds = 15
)

if ($List) {
    [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    exit 0
}
if (-not $Port -or -not $Command) {
    Write-Error 'Give -Port and -Command (or -List). The command is in docs/demo-day.md.'
    exit 2
}

$eol = @{ CRLF = "`r`n"; LF = "`n"; CR = "`r" }[$LineEnding]
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
$sp.DtrEnable = $true
try {
    $sp.Open()
} catch {
    Write-Error "send-uplink: cannot open ${Port}: $($_.Exception.Message). Is a serial monitor still holding it?"
    exit 3
}
try {
    $sp.DiscardInBuffer()
    $sent = Get-Date
    $sp.Write($Command + $eol)
    Write-Output ("send-uplink: sent at {0:HH:mm:ss} UTC, node output for {1} s:" -f $sent.ToUniversalTime(), $Seconds)
    $end = $sent.AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        try { Write-Output ('  ' + $sp.ReadLine().TrimEnd("`r")) } catch [System.TimeoutException] { }
    }
} finally {
    $sp.Close()
}
Write-Output 'send-uplink: now check gwmon (uplinks goes up by 1) and AWS (docs/demo-day.md, step 5).'
exit 0
