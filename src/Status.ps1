# Status.ps1 - free space per drive, quarantine size (measured), next purge-eligible entries,
# last hub worklog line.

function Get-ReclaimStatus {
    $cfg = Get-ReclaimConfig
    $drives = @(foreach ($d in Get-FixedDriveLetters) {
            $root = "$($d):\"
            [pscustomobject]@{ Drive = $d; Total = [Reclaim.Native]::TotalBytes($root); Free = [Reclaim.Native]::FreeBytes($root) }
        })
    $measure = {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return @([long]0, [long]0, [long]0) }
        $o = New-Object Reclaim.ScanOptions
        $o.UseBackupPrivilege = $false
        $top = [Reclaim.Walker]::Scan($Path, $o).Dirs[0]
        return @($top.OnDisk, $top.Logical, $top.Files)
    }
    $q = & $measure (Join-Path $cfg.dataRoot 'quarantine')
    $mv = & $measure (Join-Path $cfg.dataRoot 'moved')
    $entries = @(Get-ReclaimQuarantineEntries | Sort-Object purgeAfter)
    $now = Get-Date
    return [pscustomobject]@{
        Mode             = (Get-ReclaimMode)
        Drives           = $drives
        QuarantineOnDisk = $q[0]; QuarantineLogical = $q[1]; QuarantineFiles = $q[2]
        MovedOnDisk      = $mv[0]; MovedFiles = $mv[2]
        NextPurge        = @($entries | Where-Object { -not $_.pinned } | Select-Object -First 5)
        EligibleNow      = @($entries | Where-Object { -not $_.pinned -and [datetime]$_.purgeAfter -le $now }).Count
        Pinned           = @($entries | Where-Object { $_.pinned }).Count
        LastWorklog      = (Get-ReclaimLastWorklogLine)
    }
}

function Show-ReclaimStatus {
    $cfg = Get-ReclaimConfig
    $s = Get-ReclaimStatus
    Write-Host ''
    Write-Host "Status   $((Get-Date).ToString('s'))   $($s.Mode)" -ForegroundColor White
    Write-Host '  Free space (measured now):'
    foreach ($d in $s.Drives) {
        $usedFrac = if ($d.Total) { 1 - ($d.Free / $d.Total) } else { 0 }
        $bar = ('#' * [int][math]::Round($usedFrac * 30)).PadRight(30, '.')
        $color = if ($d.Free -lt 0.1 * $d.Total) { 'Yellow' } else { 'Gray' }
        Write-Host ('    {0}:  [{1}] {2,10} free of {3}' -f $d.Drive, $bar, (Format-Bytes $d.Free), (Format-Bytes $d.Total)) -ForegroundColor $color
    }
    Write-Host ('  Quarantine    {0} on disk in {1:N0} files  ({2})' -f (Format-Bytes $s.QuarantineOnDisk), $s.QuarantineFiles, (Join-Path $cfg.dataRoot 'quarantine'))
    Write-Host ('  Moved         {0} on disk in {1:N0} files  ({2})' -f (Format-Bytes $s.MovedOnDisk), $s.MovedFiles, (Join-Path $cfg.dataRoot 'moved'))
    Write-Host ("  Purge         never automatic. {0} entr(ies) eligible now, {1} pinned. List: reclaim purge   Delete (owner only): reclaim purge --execute" -f $s.EligibleNow, $s.Pinned)
    if (@($s.NextPurge).Count) {
        Write-Host '  Next to become purge-eligible:'
        foreach ($x in $s.NextPurge) { Write-Host ('    {0}  after {1}  {2,10}  {3} -> {4}' -f $x.id, $x.purgeAfter, (Format-Bytes $x.onDisk), $x.name, $x.path) }
    }
    Write-Host "  Last hub worklog line: $($s.LastWorklog)" -ForegroundColor DarkGray
    Write-WorklogStatus (Write-ReclaimWorklog -Command 'status' -Note ("quarantine {0}; {1} eligible for purge" -f (Format-Bytes $s.QuarantineOnDisk), $s.EligibleNow))
}
