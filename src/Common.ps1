# Common.ps1 - configuration, data paths, engine loading, elevation, formatting.

$script:ReclaimSrcDir  = $PSScriptRoot
$script:ReclaimRepoDir = Split-Path -Parent $PSScriptRoot
$script:ReclaimConfig  = $null

function Get-ReclaimConfig {
    if ($null -ne $script:ReclaimConfig) { return $script:ReclaimConfig }
    $cfg = [ordered]@{
        dataRoot            = 'Y:\_reclaim'
        hubClient           = ''
        python              = 'python'
        hubEnabled          = $true
        worklogKey          = 'worklog-reclaim'
        dirUnknownMinBytes  = [long]1GB
        fileUnknownMinBytes = [long]500MB
        tableRows           = 40
        purgeDays           = 30
        advisorModel        = 'claude-haiku-4-5'
        hostName            = $env:COMPUTERNAME
        protectedPaths      = @()          # never proposed, never moved (e.g. wallet folders); set in config.local.json
    }
    $local = Join-Path $script:ReclaimRepoDir 'config.local.json'
    if (Test-Path -LiteralPath $local) {
        $j = [IO.File]::ReadAllText($local) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    }
    if ($env:RECLAIM_HOME)           { $cfg.dataRoot   = $env:RECLAIM_HOME }
    if ($env:RECLAIM_NO_HUB -eq '1') { $cfg.hubEnabled = $false }
    $script:ReclaimConfig = [pscustomobject]$cfg
    return $script:ReclaimConfig
}

function Reset-ReclaimConfig { $script:ReclaimConfig = $null }

# Returns a folder under the data root, creating it (folders only) when missing.
function Get-ReclaimPath([string]$Name) {
    $root = (Get-ReclaimConfig).dataRoot
    $p = if ($Name) { Join-Path $root $Name } else { $root }
    if (-not (Test-Path -LiteralPath $p)) { [void](New-Item -ItemType Directory -Force -Path $p) }
    return $p
}

function Test-ReclaimElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ReclaimMode { if (Test-ReclaimElevated) { 'ELEVATED' } else { 'UNELEVATED' } }

function Get-StringSha256([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        return -join ($bytes | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

# Compiles src\*.cs together, once per source hash, into %LOCALAPPDATA%\Reclaim\bin and loads it.
function Import-ReclaimEngine {
    if ('Reclaim.Walker' -as [type]) { return }
    $srcs = @(Get-ChildItem -LiteralPath $script:ReclaimSrcDir -Filter '*.cs' | Sort-Object Name | ForEach-Object { $_.FullName })
    $code = ($srcs | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n"
    $hash = (Get-StringSha256 $code).Substring(0, 16)
    $bin  = Join-Path $env:LOCALAPPDATA 'Reclaim\bin'
    $dll  = Join-Path $bin "Reclaim.Engine.$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        if (-not (Test-Path -LiteralPath $bin)) { [void](New-Item -ItemType Directory -Force -Path $bin) }
        Add-Type -Path $srcs -OutputAssembly $dll -OutputType Library -ReferencedAssemblies 'System.Core'
    }
    if (-not ('Reclaim.Walker' -as [type])) { Add-Type -Path $dll }
}

function Format-Bytes([long]$Bytes) {
    $abs = [math]::Abs($Bytes)
    if ($abs -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($abs -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($abs -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($abs -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Format-GB([long]$Bytes) { return ('{0:N2}' -f ($Bytes / 1GB)) }

function Get-ReclaimStamp { return (Get-Date).ToString('yyyyMMdd-HHmmss') }

# Normalizes "c", "C:", "c:\" to "C".
function ConvertTo-DriveLetter([string]$Drive) {
    $d = $Drive.Trim().TrimEnd('\').TrimEnd(':')
    if ($d -notmatch '^[A-Za-z]$') { throw "Not a drive letter: '$Drive'" }
    return $d.ToUpperInvariant()
}

function Get-FixedDriveLetters {
    return @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
        Where-Object { $_.Size -gt 1GB } |
        ForEach-Object { $_.DeviceID.TrimEnd(':') })
}

function Write-ReclaimLog([string]$Line) {
    $dir = Get-ReclaimPath 'logs'
    $stamp = (Get-Date).ToString('s')
    [IO.File]::AppendAllText((Join-Path $dir 'reclaim.log'), "$stamp $Line`r`n")
}

# Exclusive lock shared by every local run (elevated or not) on the same data root: an open file
# with FileShare.None. Returns the stream (dispose to release) or $null after the timeout.
# The .lock file itself is left in place.
function Enter-ReclaimLock([string]$Name, [int]$TimeoutSec = 120) {
    $path = Join-Path (Get-ReclaimPath) "$Name.lock"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        try {
            return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ((Get-Date) -gt $deadline) { return $null }
            Start-Sleep -Milliseconds 150
        }
    }
}

function ConvertFrom-FileTicks([long]$Ticks) {
    if ($Ticks -le 0) { return $null }
    return [DateTime]::FromFileTimeUtc($Ticks).ToLocalTime()
}

function Write-ModeBanner {
    $mode = Get-ReclaimMode
    if ($mode -eq 'ELEVATED') {
        Write-Host "MODE: ELEVATED (admin) - backup privilege on; other profiles and System Volume Information are visible." -ForegroundColor Green
    } else {
        Write-Host "MODE: UNELEVATED - other user profiles, System Volume Information and other users' recycle bins are NOT visible." -ForegroundColor Yellow
        Write-Host "      Elevated run: open 'Windows PowerShell' as Administrator, then: $(Get-ReclaimSelfCommand)" -ForegroundColor Yellow
    }
    return $mode
}

function Get-ReclaimSelfCommand {
    $cmd = Join-Path $script:ReclaimRepoDir 'reclaim.cmd'
    $argsText = ($script:ReclaimArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    return "& `"$cmd`" $argsText".TrimEnd()
}
