# reclaim.ps1 - Reclaim: explain, then ask, then act, then leave a receipt.
# No param block on purpose: "--flags" arrive untouched in $args under powershell.exe -File.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'src\Load.ps1')

$script:ReclaimArgs = @($args)
$command = if ($args.Count) { ([string]$args[0]).ToLowerInvariant() } else { 'help' }
$rest = @(if ($args.Count -gt 1) { $args[1..($args.Count - 1)] | ForEach-Object { [string]$_ } })
$valueFlags = @('--only')

function Test-Flag([string]$Name) { return ($rest -contains "--$Name") }

function Get-FlagValue([string]$Name) {
    $i = [array]::IndexOf($rest, "--$Name")
    if ($i -ge 0 -and $i + 1 -lt $rest.Count) { return $rest[$i + 1] }
    return $null
}

function Get-Positional {
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $rest.Count; $i++) {
        if ($rest[$i] -in $valueFlags) { $i++; continue }
        if ($rest[$i] -like '--*') { continue }
        [void]$out.Add($rest[$i])
    }
    return , @($out)
}

function Resolve-DriveArgs([string]$Default) {
    $pos = Get-Positional
    $v = if ($pos.Count) { $pos[0] } else { $Default }
    if ($v -eq 'all') { return , @(Get-FixedDriveLetters) }
    return , @(ConvertTo-DriveLetter $v)
}

function Get-RequiredPositional([string]$What) {
    $pos = Get-Positional
    if (-not $pos.Count) { throw "Missing $What. See: reclaim help" }
    return $pos[0]
}

function Show-ReclaimHelp {
    @'
Reclaim - a disk cleaner that explains before it acts and never deletes.

  reclaim scan [drive|all] [--view]        read-only inventory, ranked table, denied paths (default C:)
  reclaim hotspots [drive|all]             what is filling the disk right now (default all drives)
  reclaim explain <path> [--ai]            one item, full explanation, exact reclaim command
  reclaim plan [drive|all]                 proposes DELETE / MOVE / DISABLE / CLEAR-FROM-APP / KEEP; runs nothing
  reclaim apply [--only ids] [--yes-to-safe]
                                           acts on the last plan, one item at a time, confirming each
  reclaim undo <receipt-id>                moves a quarantined item back
  reclaim show <path|drive>                HTML visual (treemap) + terminal bars
  reclaim status                           free space, quarantine size, next purge, last hub worklog line
  reclaim pin <receipt-id>                 keep a quarantine entry past the purge date
  reclaim purge [--execute]                lists entries past the purge date; --execute is owner-only

DELETE never deletes: items move to <dataRoot>\quarantine\<date>\<receipt-id>\ with a manifest.
'@ | Write-Host
}

$exit = 0
try {
    if ($command -in 'help', '-h', '--help', '/?') { Show-ReclaimHelp; exit 0 }
    $script:ReclaimMode = Write-ModeBanner
    Import-ReclaimEngine
    switch ($command) {
        'scan'     { [void](Invoke-ReclaimScan -Drives (Resolve-DriveArgs 'C') -View:(Test-Flag 'view')) }
        'hotspots' { Invoke-ReclaimHotspots -Drives (Resolve-DriveArgs 'all') }
        'explain'  { Invoke-ReclaimExplain -Path (Get-RequiredPositional 'path') -Ai:(Test-Flag 'ai') }
        'plan'     { [void](Invoke-ReclaimPlan -Drives (Resolve-DriveArgs 'all')) }
        'apply'    {
            $only = @(if (Get-FlagValue 'only') { (Get-FlagValue 'only') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
            Invoke-ReclaimApply -Only $only -YesToSafe:(Test-Flag 'yes-to-safe')
        }
        'undo'     { Invoke-ReclaimUndo -ReceiptId (Get-RequiredPositional 'receipt id') }
        'show'     { Invoke-ReclaimShow -Target (Get-RequiredPositional 'path or drive') -NoOpen:(Test-Flag 'no-open') }
        'status'   { Show-ReclaimStatus }
        'pin'      { Set-ReclaimPin -ReceiptId (Get-RequiredPositional 'receipt id') }
        'purge'    { Invoke-ReclaimPurge -Execute:(Test-Flag 'execute') }
        default    { Write-Host "Unknown command '$command'." -ForegroundColor Red; Show-ReclaimHelp; $exit = 2 }
    }
} catch {
    $exit = 1
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    try {
        $res = Write-ReclaimWorklog -Command $command -Note ("FAILED: " + $_.Exception.Message)
        Write-WorklogStatus $res
    } catch { Write-Host "Hub worklog: NOT sent - $($_.Exception.Message)" -ForegroundColor Yellow }
}
exit $exit
