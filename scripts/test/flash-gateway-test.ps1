<#
.SYNOPSIS
Host test for scripts/flash-gateway.ps1 (issue #10). Needs no card, no administrator rights
and no AWS account.

.DESCRIPTION
Runs the flash script in its test mode: the image goes to a file instead of a disk
(-TargetFile), a directory stands for the boot partition (-BootDir), and the allow-list is a
local file (-AllowList file). That covers everything except the Windows disk handling
(diskpart, \\.\PhysicalDriveN, waiting for the boot partition), which only a real card can test.

  powershell -ExecutionPolicy Bypass -File scripts\test\flash-gateway-test.ps1

Exit code: 0 if every check passed, 1 otherwise.

This file was partially generated using Claude Code using the chat session at:
Link to chat session (issue #10): ISSUE10_SESSION_LINK
#>
$ErrorActionPreference = 'Stop'
$flash = Join-Path (Split-Path -Parent $PSScriptRoot) 'flash-gateway.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ("flash-gateway-test-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work
$failed = 0

function Check([bool]$Ok, [string]$What) {
    if ($Ok) { Write-Host "ok    $What" } else { Write-Host "FAIL  $What"; $script:failed++ }
}

# A file of random bytes that stands for sdcard.img.
function New-Image([string]$Name, [int]$Bytes) {
    $path = Join-Path $work $Name
    $data = New-Object byte[] $Bytes
    (New-Object Random 5713).NextBytes($data)
    [IO.File]::WriteAllBytes($path, $data)
    return $path
}

function Get-Sha256([string]$Text) {
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($Text))
    return -join ($hash | ForEach-Object { $_.ToString('x2') })
}

# Run the flash script in a new PowerShell, as a production script would. Returns its exit code
# and everything it printed.
function Invoke-Flash([string[]]$Arguments) {
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $flash @Arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output }
}

function New-Run([string]$Name) {
    $dir = Join-Path $work $Name
    $null = New-Item -ItemType Directory -Path (Join-Path $dir 'boot') -Force
    return @{
        Target = Join-Path $dir 'card.img'; Boot = Join-Path $dir 'boot'
        List = Join-Path $dir 'allowlist.jsonl'; Log = Join-Path $dir 'flash.log'
    }
}

function Get-FlashArguments($Run, [string]$ImagePath) {
    return @('-Force', '-Image', $ImagePath, '-TargetFile', $Run.Target, '-BootDir', $Run.Boot,
        '-AllowList', 'file', '-AllowListFile', $Run.List, '-LogFile', $Run.Log,
        '-ProvisionUrl', 'https://function.example/provision')
}

try {
    # 9 MiB + 512 bytes: three chunks, the last one short. 1 MiB: smaller than one chunk.
    $big = New-Image 'big.img' (9MB + 512)
    $small = New-Image 'small.img' 1MB
    $odd = New-Image 'odd.img' (1MB + 100)

    foreach ($case in @(@{ Name = 'three-chunks'; Image = $big }, @{ Name = 'one-short-chunk'; Image = $small })) {
        $name = $case.Name
        $run = New-Run $name
        $result = Invoke-Flash (Get-FlashArguments $run $case.Image)
        Check ($result.Code -eq 0) "${name}: exit code 0 (got $($result.Code))"
        Check ((Get-FileHash $run.Target).Hash -eq (Get-FileHash $case.Image).Hash) "${name}: the target equals the image"

        $secretText = [IO.File]::ReadAllText((Join-Path $run.Boot 'provision.secret'))
        Check ($secretText -cmatch '^[0-9a-f]{64}\n$') "${name}: provision.secret is 64 hex characters and a line end"
        $secret = $secretText.Trim()
        $urlText = [IO.File]::ReadAllText((Join-Path $run.Boot 'provision.url'))
        Check ($urlText -ceq "https://function.example/provision`n") "${name}: provision.url holds the address"

        $fingerprint = Get-Sha256 $secret
        $entries = @(Get-Content $run.List | ForEach-Object { $_ | ConvertFrom-Json })
        $listed = ($entries.Count -eq 1 -and $entries[0].fingerprint -eq $fingerprint -and $entries[0].state -eq 'unused')
        Check $listed "${name}: the allow-list has the secret's SHA-256 fingerprint, unused"
        Check ($result.Output -match "RESULT ok fingerprint=$fingerprint ") "${name}: the last line reports the fingerprint"
        $everything = $result.Output + (Get-Content $run.Log -Raw) + (Get-Content $run.List -Raw)
        Check (-not $everything.Contains($secret)) "${name}: the secret is not in the output, the log or the allow-list"
    }

    # Two cards never get the same secret.
    $again = New-Run 'again'
    $null = Invoke-Flash (Get-FlashArguments $again $small)
    $first = [IO.File]::ReadAllText((Join-Path $work 'one-short-chunk\boot\provision.secret'))
    $second = [IO.File]::ReadAllText((Join-Path $again.Boot 'provision.secret'))
    Check ($second -cne $first) 'a second card gets a different secret'

    # Documented exit codes.
    $run = New-Run 'no-image'
    $result = Invoke-Flash (Get-FlashArguments $run (Join-Path $work 'missing.img'))
    Check ($result.Code -eq 3 -and $result.Output -match 'RESULT error code=3') 'a missing image gives exit code 3'
    Check (-not (Test-Path $run.Target)) 'a missing image writes nothing'

    $run = New-Run 'odd-image'
    $result = Invoke-Flash (Get-FlashArguments $run $odd)
    Check ($result.Code -eq 3) 'an image that is not a multiple of 512 bytes gives exit code 3'

    $run = New-Run 'no-allowlist'
    $arguments = Get-FlashArguments $run $small
    $arguments[$arguments.IndexOf('-AllowListFile') + 1] = Join-Path $work 'no-such-dir\allowlist.jsonl'
    $result = Invoke-Flash $arguments
    Check ($result.Code -eq 8) "an allow-list that cannot be written gives exit code 8 (got $($result.Code))"
    Check (-not (Test-Path (Join-Path $run.Boot 'provision.secret'))) 'and the secret is deleted from the card again'

    $result = Invoke-Flash @('-Force', '-Image', $small)
    Check ($result.Code -eq 1) 'no disk number gives exit code 1'

    $run = New-Run 'http-address'
    $arguments = Get-FlashArguments $run $small
    $arguments[$arguments.IndexOf('-ProvisionUrl') + 1] = 'http://function.example/provision'
    $result = Invoke-Flash $arguments
    Check ($result.Code -eq 1 -and -not (Test-Path $run.Target)) 'an address that is not https gives exit code 1 and writes nothing'

    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $result = Invoke-Flash @('-Force', '-Image', $small, '-DiskNumber', '99')
        Check ($result.Code -eq 2) 'a disk without administrator rights gives exit code 2'
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { Write-Host "$failed checks FAILED"; exit 1 }
Write-Host 'all checks passed'
exit 0
