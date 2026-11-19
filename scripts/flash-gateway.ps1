<#
.SYNOPSIS
Flash one gateway card for zero-touch provisioning (issue #10).

.DESCRIPTION
Writes sdcard.img to a microSD card, gives the card a new random secret, and records the
secret's SHA-256 fingerprint in the allow-list. That is the only per-gateway step: at its
first boot the gateway uses the secret once to register itself (see the README, "Flash and
first boot").

What it does, in this order:
  1. Checks everything that can be checked before the card is touched: the image, the disk,
     and that the allow-list can be reached.
  2. Erases the card's partition table (diskpart "clean"), writes the image and reads it back.
  3. Generates a 256-bit secret and writes two files to the card's boot partition:
       provision.secret   the secret, 64 hex characters
       provision.url      the address of the provisioning function
  4. Records the fingerprint, SHA-256 of those 64 characters, in the allow-list as "unused".
     If that fails, it deletes the secret from the card again, so no card leaves with a secret
     that the function would refuse.

The secret is never printed, logged or stored on this PC. Only the card has it. The fingerprint
is not secret: it cannot be turned back into the secret.

Writing a card needs Windows and an elevated ("Run as administrator") PowerShell. This is a
PowerShell script and not the shell script that the issue first named, because the image is
built in WSL2, and WSL2 cannot open the PC's card reader as a block device.

.PARAMETER DiskNumber
The card's disk number, from "flash-gateway.ps1 -List". Only removable USB, SD or MMC disks of
at most -MaxSizeGB are accepted, and never the system or boot disk.

.PARAMETER Image
The image to write. Default: buildroot\output\images\sdcard.img next to this script's folder.

.PARAMETER Force
Non-interactive mode: do not ask for confirmation before erasing the card. For a production
test script. The exit code and the last output line ("RESULT ...") tell it what happened.

.PARAMETER StackName
The CloudFormation stack of the provisioning function (provisioning/deploy.sh). The function's
address and the allow-list table are read from its outputs, unless -ProvisionUrl and
-AllowListTable give them.

.PARAMETER AllowList
Where fingerprints are recorded: "dynamodb" (the stand-in table, the default) or "file" (one
JSON line per card appended to -AllowListFile; used by the host test). The SoilData API will be
a third choice. Each one is a pair of functions below: Test-AllowList and Add-AllowListFingerprint.

.PARAMETER Label
Optional note stored with the fingerprint, for example a batch or serial number. Not secret.

.PARAMETER LogFile
Also append every output line to this file.

.PARAMETER TargetFile
For the host test (scripts/test/flash-gateway-test.ps1): write the image to this file instead
of a disk. Needs -BootDir, a directory that stands for the mounted boot partition. No
administrator rights are needed.

.NOTES
Exit codes:
   0  the card is flashed and its fingerprint is recorded
   1  wrong arguments
   2  not running as administrator
   3  the image is missing, unreadable, or its size is not a multiple of 512 bytes
   4  the disk is refused: not found, not a removable USB/SD/MMC disk, the system disk,
      smaller than the image, or larger than -MaxSizeGB
   5  the allow-list cannot be reached (not signed in to AWS, no such stack or table).
      Nothing was written to the card
   6  the card could not be erased or written, or the read-back differs
   7  the boot partition did not appear, or the secret could not be written to it
   8  the fingerprint could not be recorded. The secret was deleted from the card again:
      the card boots but cannot provision itself. Flash it again
   9  the user did not confirm
  10  an unexpected error

Codes 0 to 5 and 9 leave the card as it was, except 0. After 6, 7 or 8 the card must be
flashed again.

This file was partially generated using Claude Code using the chat session at:
Link to chat session (issue #10): ISSUE10_SESSION_LINK
#>
[CmdletBinding()]
param(
    [int]$DiskNumber = -1,
    [string]$Image,
    [switch]$Force,
    [switch]$List,
    [string]$StackName = 'aesd-gateway-provisioning',
    [string]$Region = 'us-east-1',
    [string]$ProvisionUrl,
    [ValidateSet('dynamodb', 'file')][string]$AllowList = 'dynamodb',
    [string]$AllowListTable,
    [string]$AllowListFile,
    [string]$Label = '',
    [int]$MaxSizeGB = 128,
    [string]$LogFile,
    [string]$TargetFile,
    [string]$BootDir
)

$ErrorActionPreference = 'Stop'
$ChunkSize = 4MB

function Say([string]$Text) {
    Write-Host $Text
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $Text -Encoding ASCII }
}

# End the script with one of the documented exit codes.
function Stop-Flash([int]$Code, [string]$Text) {
    Say "flash-gateway: ERROR: $Text"
    Say "RESULT error code=$Code"
    exit $Code
}

function ConvertTo-Hex([byte[]]$Bytes) {
    return -join ($Bytes | ForEach-Object { $_.ToString('x2') })
}

# Run the AWS CLI and return its text output, or $null if it failed. Its error text is dropped:
# with "2>&1" Windows PowerShell 5.1 would turn it into a terminating error.
function Invoke-Aws([string[]]$Arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & aws @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (($out | Out-String).Trim())
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $old
    }
}

# --- The allow-list interface: two functions per implementation. ---------------------------

# Check, before the card is touched, that fingerprints can be recorded. Returns an error text,
# or $null when all is well.
function Test-AllowList {
    if ($AllowList -eq 'file') {
        if (-not $AllowListFile) { return '-AllowList file needs -AllowListFile' }
        return $null
    }
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { return 'the AWS CLI (aws) is not installed' }
    $status = Invoke-Aws @('dynamodb', 'describe-table', '--table-name', $script:Table,
        '--region', $Region, '--query', 'Table.TableStatus', '--output', 'text')
    if ($status -ne 'ACTIVE') {
        return "cannot read the allow-list table '$($script:Table)'. Is the AWS CLI signed in (aws login)?"
    }
    return $null
}

# Record a new fingerprint as unused. Returns $true on success. A fingerprint that is already
# listed is an error: every card must get its own secret.
function Add-AllowListFingerprint([string]$Fingerprint) {
    $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    if ($AllowList -eq 'file') {
        try {
            $line = '{"fingerprint":"' + $Fingerprint + '","state":"unused","created_at":"' + $now + '"}'
            Add-Content -LiteralPath $AllowListFile -Value $line -Encoding ASCII
            return $true
        } catch {
            return $false
        }
    }
    $item = @{
        fingerprint = @{ S = $Fingerprint }
        state       = @{ S = 'unused' }
        created_at  = @{ S = $now }
    }
    if ($Label) { $item.label = @{ S = $Label } }
    # The item goes through a file, because Windows PowerShell 5.1 strips the double quotes
    # from JSON passed on a command line. The file holds the fingerprint, not the secret.
    $itemFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($itemFile, ($item | ConvertTo-Json -Compress))
        $out = Invoke-Aws @('dynamodb', 'put-item', '--table-name', $script:Table, '--region', $Region,
            '--item', "file://$itemFile", '--condition-expression', 'attribute_not_exists(fingerprint)',
            '--output', 'text')
        return ($null -ne $out)
    } finally {
        Remove-Item -LiteralPath $itemFile -Force -ErrorAction SilentlyContinue
    }
}

# --- Raw disk access -------------------------------------------------------------------------

# .NET's FileStream refuses a device path such as \\.\PhysicalDrive2, but it accepts a handle
# that CreateFile opened.
Add-Type -Namespace FlashGateway -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(
    string name, uint access, uint share, System.IntPtr security, uint disposition,
    uint flags, System.IntPtr template);
'@

function Open-Target([string]$Path, [bool]$Create) {
    $GENERIC_READ_WRITE = [uint32]3221225472   # GENERIC_READ | GENERIC_WRITE
    $disposition = [uint32]3                   # OPEN_EXISTING
    if ($Create) { $disposition = [uint32]2 }  # CREATE_ALWAYS
    $handle = [FlashGateway.Native]::CreateFile($Path, $GENERIC_READ_WRITE, [uint32]3,
        [IntPtr]::Zero, $disposition, [uint32]0, [IntPtr]::Zero)
    if ($handle.IsInvalid) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "cannot open $Path (Windows error $code)"
    }
    return New-Object IO.FileStream($handle, [IO.FileAccess]::ReadWrite, 4096, $false)
}

# Fill the buffer from the stream. Returns the number of bytes read: less than $Count only at
# the end of the stream. A disk accepts only whole sectors, so a short read must not be passed on.
function Read-Fully([IO.Stream]$Stream, [byte[]]$Buffer, [int]$Count) {
    $total = 0
    while ($total -lt $Count) {
        $n = $Stream.Read($Buffer, $total, $Count - $total)
        if ($n -le 0) { break }
        $total += $n
    }
    return $total
}

# Write the image and read it back. The first 4 MiB go last: they hold the partition table, and
# as long as it is missing Windows sees an empty disk and does not mount (and then write to, or
# lock) the boot partition under us. The read-back of the rest is done before that for the
# same reason.
function Write-Image([string]$ImagePath, [IO.Stream]$Target) {
    $source = [IO.File]::OpenRead($ImagePath)
    try {
        $length = $source.Length
        $buffer = New-Object byte[] $ChunkSize
        $written = [Security.Cryptography.SHA256]::Create()
        $empty = New-Object byte[] 0

        $first = [int][Math]::Min([long]$ChunkSize, $length)
        $source.Position = $first
        $Target.Position = $first
        $done = [long]$first
        $nextMark = 10
        while (($n = Read-Fully $source $buffer $ChunkSize) -gt 0) {
            $Target.Write($buffer, 0, $n)
            [void]$written.TransformBlock($buffer, 0, $n, $null, 0)
            $done += $n
            $percent = [int](100 * $done / $length)
            if ($percent -ge $nextMark) {
                Say "flash-gateway: written $percent %"
                $nextMark += 10
            }
        }
        $Target.Flush($true)
        [void]$written.TransformFinalBlock($empty, 0, 0)

        $readBack = [Security.Cryptography.SHA256]::Create()
        $Target.Position = $first
        $left = $length - $first
        while ($left -gt 0) {
            $want = [int][Math]::Min([long]$ChunkSize, $left)
            $n = Read-Fully $Target $buffer $want
            if ($n -ne $want) { throw 'the card returned less data than was written' }
            [void]$readBack.TransformBlock($buffer, 0, $n, $null, 0)
            $left -= $n
        }
        [void]$readBack.TransformFinalBlock($empty, 0, 0)
        if ((ConvertTo-Hex $written.Hash) -ne (ConvertTo-Hex $readBack.Hash)) {
            throw 'the read-back differs from the image'
        }

        $source.Position = 0
        $head = New-Object byte[] $first
        [void](Read-Fully $source $head $first)
        $Target.Position = 0
        $Target.Write($head, 0, $first)
        $Target.Flush($true)
        $check = New-Object byte[] $first
        $Target.Position = 0
        if ((Read-Fully $Target $check $first) -ne $first -or
            -not [Linq.Enumerable]::SequenceEqual([byte[]]$head, [byte[]]$check)) {
            throw 'the read-back of the first block differs from the image'
        }
    } finally {
        $source.Dispose()
    }
}

# The disks this script is willing to erase.
function Get-CardDisks {
    Get-Disk | Where-Object {
        ($_.BusType -in 'USB', 'SD', 'MMC') -and -not $_.IsSystem -and -not $_.IsBoot
    } | Where-Object {
        $drive = Get-CimInstance Win32_DiskDrive -Filter "Index=$($_.Number)" -ErrorAction SilentlyContinue
        $drive -and $drive.MediaType -like 'Removable*'
    }
}

# Wait for Windows to mount the new boot partition, and return its root, for example "E:\".
function Wait-BootPartition([int]$Number) {
    for ($try = 0; $try -lt 30; $try++) {
        Update-HostStorageCache -ErrorAction SilentlyContinue
        $part = Get-Partition -DiskNumber $Number -PartitionNumber 1 -ErrorAction SilentlyContinue
        if ($part) {
            if ($part.DriveLetter -and ([int][char]$part.DriveLetter) -ne 0) {
                $root = "$($part.DriveLetter):\"
                if (Test-Path -LiteralPath (Join-Path $root 'config.txt')) { return $root }
            } elseif ($try -ge 3) {
                Add-PartitionAccessPath -DiskNumber $Number -PartitionNumber 1 -AssignDriveLetter -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

# --- Main --------------------------------------------------------------------------------------

try {
    if ($List) {
        $cards = @(Get-CardDisks)
        if ($cards.Count -eq 0) { Say 'flash-gateway: no removable USB, SD or MMC disk found' }
        foreach ($disk in $cards) {
            Say ("disk {0}: {1}, {2:N1} GB" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB))
        }
        exit 0
    }

    $toFile = [bool]$TargetFile
    if ($toFile -and -not $BootDir) { Stop-Flash 1 '-TargetFile needs -BootDir' }
    if (-not $toFile -and $DiskNumber -lt 0) {
        Stop-Flash 1 'give the card''s disk number: flash-gateway.ps1 -DiskNumber <n> (see -List)'
    }

    if (-not $toFile) {
        $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Stop-Flash 2 'writing a card needs an elevated PowerShell (Run as administrator)'
        }
    }

    # The image.
    if (-not $Image) { $Image = Join-Path (Split-Path -Parent $PSScriptRoot) 'buildroot\output\images\sdcard.img' }
    if (-not (Test-Path -LiteralPath $Image -PathType Leaf)) { Stop-Flash 3 "no image at $Image" }
    $imageLength = (Get-Item -LiteralPath $Image).Length
    if ($imageLength -eq 0 -or ($imageLength % 512) -ne 0) {
        Stop-Flash 3 "the size of $Image ($imageLength bytes) is not a multiple of 512"
    }
    try {
        $imageHash = (Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash.ToLower()
    } catch {
        Stop-Flash 3 "cannot read $Image"
    }

    # The disk.
    if (-not $toFile) {
        $disk = Get-CardDisks | Where-Object { $_.Number -eq $DiskNumber }
        if (-not $disk) {
            Stop-Flash 4 "disk $DiskNumber is not a removable USB, SD or MMC disk (see -List)"
        }
        if ($disk.Size -lt $imageLength) { Stop-Flash 4 "disk $DiskNumber is smaller than the image" }
        if ($disk.Size -gt ([long]$MaxSizeGB * 1GB)) {
            Stop-Flash 4 ("disk $DiskNumber has {0:N0} GB, more than -MaxSizeGB $MaxSizeGB" -f ($disk.Size / 1GB))
        }
    }

    # The allow-list and the function's address.
    if ($AllowList -eq 'dynamodb' -and (-not $ProvisionUrl -or -not $AllowListTable)) {
        foreach ($name in 'ProvisionUrl', 'AllowListTableName') {
            $value = Invoke-Aws @('cloudformation', 'describe-stacks', '--stack-name', $StackName,
                '--region', $Region, '--query', "Stacks[0].Outputs[?OutputKey=='$name'].OutputValue",
                '--output', 'text')
            if (-not $value -or $value -eq 'None') {
                Stop-Flash 5 "cannot read $name from the stack '$StackName'. Is the AWS CLI signed in (aws login), and is the function deployed?"
            }
            if ($name -eq 'ProvisionUrl' -and -not $ProvisionUrl) { $ProvisionUrl = $value }
            if ($name -eq 'AllowListTableName' -and -not $AllowListTable) { $AllowListTable = $value }
        }
    }
    $script:Table = $AllowListTable
    if ($ProvisionUrl -notmatch '^https://\S+$') { Stop-Flash 1 '-ProvisionUrl must be an https address' }
    $problem = Test-AllowList
    if ($problem) { Stop-Flash 5 $problem }

    Say "flash-gateway: image $Image"
    Say "flash-gateway: image SHA-256 $imageHash, $imageLength bytes"
    if ($toFile) {
        Say "flash-gateway: target file $TargetFile (test mode)"
    } else {
        Say ("flash-gateway: target disk {0}: {1}, {2:N1} GB" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB))
        if (-not $Force) {
            $answer = Read-Host "Everything on disk $DiskNumber will be erased. Type the disk number to go on"
            if ($answer -ne "$DiskNumber") { Stop-Flash 9 'not confirmed, nothing was written' }
        }
    }

    # Erase and write.
    try {
        if ($toFile) {
            $target = Open-Target $TargetFile $true
        } else {
            # Remove the partition table, so that Windows unmounts whatever is on the card and
            # lets go of it. Raspberry Pi Imager does the same.
            $commands = [IO.Path]::GetTempFileName()
            [IO.File]::WriteAllText($commands, "select disk $DiskNumber`r`nclean`r`nrescan`r`n")
            $null = & diskpart /s $commands
            $cleaned = ($LASTEXITCODE -eq 0)
            Remove-Item -LiteralPath $commands -Force -ErrorAction SilentlyContinue
            if (-not $cleaned) { throw 'diskpart could not erase the partition table' }
            $target = Open-Target "\\.\PhysicalDrive$DiskNumber" $false
        }
        try {
            Write-Image $Image $target
        } finally {
            $target.Dispose()
        }
    } catch {
        Stop-Flash 6 "$($_.Exception.Message)"
    }
    Say 'flash-gateway: image written and read back'

    # The secret. From here to the end of the script it exists in $secret and on the card only.
    if ($toFile) {
        $bootRoot = $BootDir
    } else {
        $bootRoot = Wait-BootPartition $DiskNumber
        if (-not $bootRoot) { Stop-Flash 7 'the boot partition of the new image did not appear' }
    }
    $random = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    $generator.GetBytes($random)
    $generator.Dispose()
    $secret = ConvertTo-Hex $random
    $ascii = New-Object Text.ASCIIEncoding
    $fingerprint = ConvertTo-Hex ([Security.Cryptography.SHA256]::Create().ComputeHash($ascii.GetBytes($secret)))
    $secretFile = Join-Path $bootRoot 'provision.secret'
    $urlFile = Join-Path $bootRoot 'provision.url'
    try {
        [IO.File]::WriteAllText($secretFile, "$secret`n", $ascii)
        [IO.File]::WriteAllText($urlFile, "$ProvisionUrl`n", $ascii)
        if ([IO.File]::ReadAllText($secretFile, $ascii) -ne "$secret`n") { throw 'read-back differs' }
        if (-not $toFile) { Write-VolumeCache -DriveLetter $bootRoot.Substring(0, 1) }
    } catch {
        Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue
        Stop-Flash 7 'the secret could not be written to the boot partition'
    }
    $secret = $null
    $random = $null
    Say 'flash-gateway: provision.secret and provision.url written to the boot partition'

    # The allow-list.
    if (-not (Add-AllowListFingerprint $fingerprint)) {
        Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue
        if (-not $toFile) { Write-VolumeCache -DriveLetter $bootRoot.Substring(0, 1) -ErrorAction SilentlyContinue }
        Stop-Flash 8 'the fingerprint could not be recorded in the allow-list. The secret was deleted from the card: flash it again'
    }
    $where = $AllowListFile
    if ($AllowList -eq 'dynamodb') { $where = "table $AllowListTable" }
    Say "flash-gateway: fingerprint $fingerprint recorded as unused ($AllowList allow-list, $where)"
    if (-not $toFile) { Say 'flash-gateway: done. The card can be taken out.' }
    Say "RESULT ok fingerprint=$fingerprint image_sha256=$imageHash"
    exit 0
} catch {
    Say "flash-gateway: ERROR: unexpected: $($_.Exception.Message)"
    Say 'RESULT error code=10'
    exit 10
}
