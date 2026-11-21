<#
.SYNOPSIS
Make the USB-connected test node send one uplink: open its serial port, send command lines in
order, and print what the node answers.

.DESCRIPTION
The test node does not transmit on a schedule. It sends one confirmed uplink when it gets a
command over its USB serial port (docs/demo-day.md, "The test node"). This script only writes
the command lines you give it; it holds no node keys and changes nothing on the node.

A serial reply is not proof that the uplink went out. The uplink is confirmed only when it shows
in Station's log and in AWS (docs/demo-day.md, section 5).

.PARAMETER List
Print the serial ports of this PC and exit.

.PARAMETER Port
The node's serial port, for example COM5 (see -List, or Device Manager, "Ports (COM & LPT)").

.PARAMETER Command
The command lines that make the node send one uplink, in order. There is no default: see
docs/demo-day.md for the commands, for example -Command BLUETOOTH_EXIT, LORA_LINK_TEST

.PARAMETER Help
Send HELP first and print the node's command list, to check that the commands exist on the
firmware that is on the node.

.PARAMETER Dtr
Turn DTR on when the port is opened. Off by default, because on the test node it resets the board.

.PARAMETER Baud
Default 115200.

.PARAMETER LineEnding
What ends each command: CRLF (default), LF or CR.

.PARAMETER PauseSeconds
How long to print the node's answer after each command but the last. Default 3 s.

.PARAMETER Seconds
How long to print the node's answer after the last command. Default 15 s, enough for a
confirmed uplink and its acknowledgement in the first receive window.

.EXAMPLE
.\scripts\demo\send-uplink.ps1 -List
.\scripts\demo\send-uplink.ps1 -Port COM5 -Help
.\scripts\demo\send-uplink.ps1 -Port COM5 -Command BLUETOOTH_EXIT, LORA_LINK_TEST

This script was partially generated using Claude Code using the chat session at:
Link to chat session (issue #9): ISSUE9_SESSION_LINK
#>
param(
    [switch]$List,
    [string]$Port,
    [string[]]$Command,
    [switch]$Help,
    [int]$Baud = 115200,
    [ValidateSet('CRLF', 'LF', 'CR')][string]$LineEnding = 'CRLF',
    [int]$PauseSeconds = 3,
    [int]$Seconds = 15,
    [switch]$Dtr
)

if ($List) {
    [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    exit 0
}
if (-not $Port -or (-not $Command -and -not $Help)) {
    Write-Error 'Give -Port, and -Help and/or -Command (or -List). The commands are in docs/demo-day.md.'
    exit 2
}

$eol = @{ CRLF = "`r`n"; LF = "`n"; CR = "`r" }[$LineEnding]
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
# DTR and RTS stay off: on the node's USB serial port, toggling them resets the board (seen on
# 2026-11-21: opening the port with DTR on rebooted the node). -Dtr turns DTR on for other boards.
$sp.DtrEnable = [bool]$Dtr
$sp.RtsEnable = $false
try {
    $sp.Open()
} catch {
    Write-Error "send-uplink: cannot open ${Port}: $($_.Exception.Message). Is a serial monitor still holding it?"
    exit 3
}

# Send one line, then print what comes back for the given number of seconds.
function Send-Line([string]$line, [int]$listen) {
    $sent = Get-Date
    $sp.Write($line + $eol)
    Write-Output ("send-uplink: {0:HH:mm:ss} UTC sent {1}, node output for {2} s:" -f $sent.ToUniversalTime(), $line, $listen)
    $end = $sent.AddSeconds($listen)
    while ((Get-Date) -lt $end) {
        try { Write-Output ('  ' + $sp.ReadLine().TrimEnd("`r")) } catch [System.TimeoutException] { }
    }
}

try {
    $sp.DiscardInBuffer()
    if ($Help) { Send-Line 'HELP' $PauseSeconds }
    for ($i = 0; $i -lt $Command.Count; $i++) {
        $listen = if ($i -eq $Command.Count - 1) { $Seconds } else { $PauseSeconds }
        Send-Line $Command[$i] $listen
    }
} finally {
    $sp.Close()
}
if ($Command) {
    Write-Output 'send-uplink: a serial reply does not prove the uplink. Check gwmon (uplinks goes up by 1), Station''s log and AWS (docs/demo-day.md, section 5).'
}
exit 0
