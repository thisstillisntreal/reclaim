# Scan.ps1 - walk + classify + persist, then the ranked table. Read-only.

$script:ItemMinBytes = [long]1MB

function New-ReclaimScanOptions {
    $o = New-Object Reclaim.ScanOptions
    $o.Rules = (Get-ReclaimKb).Rules
    $o.UseBackupPrivilege = (Test-ReclaimElevated)
    $o.Progress = -not [Console]::IsErrorRedirected
    return $o
}

function Format-FileTime([long]$Ticks) {
    $t = ConvertFrom-FileTicks $Ticks
    if ($null -eq $t) { return '' }
    return $t.ToString('s')
}

function ConvertTo-ReclaimItemRecord($Item, [string]$Id) {
    $e = Get-ReclaimEntry $Item.RuleId
    return [ordered]@{
        id                 = $Id
        kind               = $Item.Kind
        path               = $Item.Path
        ruleId             = $Item.RuleId
        name               = $e.name
        safety             = $e.safety
        action             = $e.action
        onDisk             = $Item.OnDisk
        logical            = $Item.Logical
        totalOnDisk        = $Item.TotalOnDisk
        totalLogical       = $Item.TotalLogical
        files              = $Item.Files
        newestWrite        = (Format-FileTime $Item.NewestWrite)
        placeholderLogical = $Item.PlaceholderLogical
        members            = @(if ($Item.Kind -eq 'files') { $Item.Members })
    }
}

function ConvertTo-FileRecord($F, $Rules) {
    return [ordered]@{
        path      = $F.Path
        onDisk    = $F.OnDisk
        logical   = $F.Logical
        lastWrite = (Format-FileTime $F.LastWrite)
        ruleId    = $(if ($F.RuleIndex -ge 0) { $Rules[$F.RuleIndex].Id } else { $null })
    }
}

# Walks $Root, classifies against the KB, writes scans\<Label>-<stamp>.json + .dirs.tsv.
function Invoke-ReclaimScanPath([string]$Root, [string]$Label) {
    $cfg = Get-ReclaimConfig
    $kb = Get-ReclaimKb
    $scans = Get-ReclaimPath 'scans'
    do {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
        $jsonPath = Join-Path $scans "$Label-$stamp.json"
    } while (Test-Path -LiteralPath $jsonPath)
    $tsvPath = Join-Path $scans "$Label-$stamp.dirs.tsv"

    $total = [Reclaim.Native]::TotalBytes($Root)
    $free = [Reclaim.Native]::FreeBytes($Root)
    $r = [Reclaim.Walker]::Scan($Root, (New-ReclaimScanOptions))
    $items = [Reclaim.Classifier]::Classify($r, $kb.Rules, [long]$cfg.dirUnknownMinBytes, [long]$cfg.fileUnknownMinBytes)
    [void][Reclaim.ScanStore]::WriteDirsTsv($r, $tsvPath, [long]1MB)

    $records = New-Object System.Collections.ArrayList
    $itemized = [long]0
    foreach ($it in $items) {
        if ($it.OnDisk -lt $script:ItemMinBytes) { continue }
        [void]$records.Add((ConvertTo-ReclaimItemRecord $it ('{0}-{1:000}' -f $Label, ($records.Count + 1))))
        $itemized += $it.OnDisk
    }
    $cutoff = (Get-Date).AddDays(-7).ToFileTimeUtc()
    $files = @($r.Files)
    $top = @($files | Sort-Object OnDisk -Descending | Select-Object -First 100 | ForEach-Object { ConvertTo-FileRecord $_ $kb.Rules })
    $recent = @($files | Where-Object { $_.LastWrite -ge $cutoff } | Sort-Object OnDisk -Descending |
        Select-Object -First 300 | ForEach-Object { ConvertTo-FileRecord $_ $kb.Rules })
    $rootDir = $r.Dirs[0]

    $doc = [ordered]@{
        version         = 1
        kind            = 'scan'
        drive           = $Label
        root            = $r.Root
        stamp           = $stamp
        time            = (Get-Date).ToString('s')
        host            = $cfg.hostName
        mode            = (Get-ReclaimMode)
        backupPrivilege = $r.BackupPrivilege
        elapsedMs       = $r.ElapsedMs
        volume          = [ordered]@{ total = $total; free = $free; used = ($total - $free) }
        totals          = [ordered]@{
            onDisk = $rootDir.OnDisk; logical = $rootDir.Logical; files = $r.TotalFiles
            dirs = $r.Dirs.Count; placeholderLogical = $rootDir.PlaceholderLogical; futureDated = $r.FutureDated
        }
        itemizedOnDisk  = $itemized
        items           = @($records)
        denied          = @($r.Denied)
        skipped         = @($r.Skipped | ForEach-Object { [ordered]@{ path = $_.Path; kind = $_.Kind } })
        errors          = @($r.Errors)
        topFiles        = $top
        recentFiles     = $recent
        dirsTsv         = [IO.Path]::GetFileName($tsvPath)
        file            = $jsonPath
    }
    $json = $doc | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($jsonPath, $json, (New-Object Text.UTF8Encoding $false))
    Write-ReclaimLog ("scan {0} {1}: {2} on disk, {3} items, {4} denied -> {5}" -f $Label, $doc.mode,
        (Format-Bytes $rootDir.OnDisk), $records.Count, $r.Denied.Count, $jsonPath)
    return $doc
}

function Get-ReclaimScanFiles([string]$Drive) {
    $dir = Get-ReclaimPath 'scans'
    return @(Get-ChildItem -LiteralPath $dir -Filter "$Drive-*.json" | Sort-Object Name -Descending)
}

# Newest scan for a drive ($Skip = 1 gives the one before it).
function Get-LatestScan([string]$Drive, [int]$Skip = 0) {
    $files = @(Get-ReclaimScanFiles $Drive)
    if ($files.Count -le $Skip) { return $null }
    return ([IO.File]::ReadAllText($files[$Skip].FullName) | ConvertFrom-Json)
}

function Get-SafetyColor([string]$Safety) {
    switch ($Safety) {
        'SAFE'           { return 'Green' }
        'SAFE-IF-CLOSED' { return 'Cyan' }
        'MOVE'           { return 'White' }
        'ADMIN-ONLY'     { return 'Magenta' }
        'KEEP'           { return 'Gray' }
        default          { return 'Yellow' }
    }
}

function Format-ItemName($It) {
    $n = $It.name
    if ($It.kind -eq 'files') { $n = "$n ($($It.files) files)" }
    $below = [long]$It.totalOnDisk - [long]$It.onDisk
    if ($below -ge 1MB) { $n = "$n [+$(Format-Bytes $below) in items below]" }
    return $n
}

function Write-ReclaimScanReport($Doc) {
    $cfg = Get-ReclaimConfig
    $v = $Doc.volume
    $t = $Doc.totals
    Write-Host ''
    Write-Host ("Scan of {0}   {1}   {2}   walked in {3:N1} s" -f $Doc.root, $Doc.time, $Doc.mode, ($Doc.elapsedMs / 1000)) -ForegroundColor White
    Write-Host ("  Volume       {0} total, {1} used, {2} free" -f (Format-Bytes $v.total), (Format-Bytes $v.used), (Format-Bytes $v.free))
    Write-Host ("  Measured     {0} on disk ({1} logical) in {2:N0} files, {3:N0} folders" -f (Format-Bytes $t.onDisk), (Format-Bytes $t.logical), $t.files, $t.dirs)
    if ($Doc.root.Length -le 3) {
        $gap = [long]$v.used - [long]$t.onDisk
        if ($gap -ge 0) {
            Write-Host ("  Unmeasured   {0} = volume used minus measured: denied folders, NTFS metadata, shadow copies. A lower bound: hard links (WinSxS) are counted once per link." -f (Format-Bytes $gap)) -ForegroundColor Yellow
        } else {
            Write-Host ("  Overcount    measured is {0} MORE than the volume uses: hard links (WinSxS, pnpm stores and the like) are counted once per link, so the folders holding them overstate real usage by at least that much." -f (Format-Bytes (-$gap))) -ForegroundColor Yellow
        }
    }
    if ([long]$t.placeholderLogical -gt 0) {
        Write-Host ("  Cloud-only   {0} of OneDrive placeholders occupy ~0 on disk; never counted as reclaimable" -f (Format-Bytes $t.placeholderLogical))
    }
    $spread = [long]$t.onDisk - [long]$Doc.itemizedOnDisk
    Write-Host ("  Itemized     {0} in {1} items; {2} is spread across folders each under the UNKNOWN threshold ({3})" -f
        (Format-Bytes $Doc.itemizedOnDisk), @($Doc.items).Count, (Format-Bytes $spread), (Format-Bytes $cfg.dirUnknownMinBytes))
    Write-Host ''

    $items = @($Doc.items)
    $rows = [Math]::Min([int]$cfg.tableRows, $items.Count)
    Write-Host ('  {0,-7} {1,10} {2,10}  {3,-14} {4,-14} {5}' -f 'ID', 'ON-DISK', 'LOGICAL', 'SAFETY', 'ACTION', 'NAME -> PATH')
    for ($i = 0; $i -lt $rows; $i++) {
        $it = $items[$i]
        $line = '  {0,-7} {1,10} {2,10}  {3,-14} {4,-14} {5} -> {6}' -f $it.id, (Format-Bytes $it.onDisk),
            (Format-Bytes $it.logical), $it.safety, $it.action, (Format-ItemName $it), $it.path
        Write-Host $line -ForegroundColor (Get-SafetyColor $it.safety)
    }
    if ($items.Count -gt $rows) { Write-Host "  ... $($items.Count - $rows) more items (>= 1 MB) in the scan file." }

    $denied = @($Doc.denied)
    Write-Host ''
    if ($denied.Count) {
        Write-Host "Denied ($($denied.Count)) - not measured in this mode:" -ForegroundColor Yellow
        foreach ($d in $denied) { Write-Host "  $d" -ForegroundColor Yellow }
    } else { Write-Host 'Denied: none.' -ForegroundColor Green }
    $skipped = @($Doc.skipped)
    if ($skipped.Count) {
        Write-Host "Skipped reparse points ($($skipped.Count)) - junctions/symlinks are not followed, so nothing is counted twice:" -ForegroundColor DarkGray
        foreach ($s in ($skipped | Select-Object -First 10)) { Write-Host "  $($s.path)  [$($s.kind)]" -ForegroundColor DarkGray }
        if ($skipped.Count -gt 10) { Write-Host "  ... $($skipped.Count - 10) more in the scan file" -ForegroundColor DarkGray }
    }
    $errors = @($Doc.errors)
    if ($errors.Count) {
        Write-Host "Errors ($($errors.Count)):" -ForegroundColor Red
        foreach ($e in $errors) { Write-Host "  $e" -ForegroundColor Red }
    }
    Write-Host "Saved: $($Doc.file)" -ForegroundColor DarkGray
    Write-Host 'Next: reclaim explain <path>   |   reclaim plan   |   reclaim hotspots' -ForegroundColor DarkGray
}

function Invoke-ReclaimScan([string[]]$Drives, [switch]$View) {
    $docs = New-Object System.Collections.ArrayList
    foreach ($d in $Drives) {
        $root = "$($d):\"
        if (-not (Test-Path -LiteralPath $root)) { Write-Host "Drive $($d): not found." -ForegroundColor Red; continue }
        Write-Host "Scanning $root (read-only) ..."
        $doc = Invoke-ReclaimScanPath -Root $root -Label $d
        Write-ReclaimScanReport $doc
        $res = Write-ReclaimWorklog -Command 'scan' -Drive "$($d):" -Mode $doc.mode -Note (
            "measured {0} GB on disk; {1} items; {2} denied" -f (Format-GB $doc.totals.onDisk), @($doc.items).Count, @($doc.denied).Count)
        Write-WorklogStatus $res
        if ($View -and (Get-Command New-ReclaimScanView -ErrorAction SilentlyContinue)) { [void](New-ReclaimScanView $doc -Open) }
        [void]$docs.Add($doc)
    }
    return , $docs
}
