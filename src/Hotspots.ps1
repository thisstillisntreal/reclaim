# Hotspots.ps1 - "what is filling my disk right now": largest recent writes, folder growth between
# the last two scans of a drive, and the knowledge base's known log/dump locations. Read-only.

function Get-EntryValue($Entry, [string]$Name, $Default) {
    $p = $Entry.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Get-ReclaimHotspots([string]$Drive) {
    $cur = Get-LatestScan -Drive $Drive
    if ($null -eq $cur) { throw "No scan of $Drive yet." }
    # Baseline = newest earlier scan in the SAME mode: an elevated walk sees folders an unelevated
    # one cannot, and that difference must never be reported as growth.
    $prev = $null
    $skippedOtherMode = 0
    $all = @(Get-ReclaimScanFiles $Drive)
    for ($k = 1; $k -lt $all.Count; $k++) {
        $cand = [IO.File]::ReadAllText($all[$k].FullName) | ConvertFrom-Json
        if ($cand.mode -eq $cur.mode) { $prev = $cand; break }
        $skippedOtherMode++
    }
    $scans = Get-ReclaimPath 'scans'
    $growth = @()
    $hours = $null
    if ($null -ne $prev) {
        $growth = @([Reclaim.Growth]::Compare((Join-Path $scans $prev.dirsTsv), (Join-Path $scans $cur.dirsTsv), 15))
        $hours = ([datetime]$cur.time - [datetime]$prev.time).TotalHours
    }
    $now = Get-Date
    $recent = @($cur.recentFiles | Where-Object { $_.lastWrite })
    $window = {
        param([double]$MaxHours)
        @($recent | Where-Object { ($now - [datetime]$_.lastWrite).TotalHours -le $MaxHours } | Select-Object -First 10)
    }
    $kb = Get-ReclaimKb
    $known = @($cur.items | Where-Object {
            $_.ruleId -and $kb.ById.ContainsKey($_.ruleId) -and (Get-EntryValue $kb.ById[$_.ruleId] 'hotspot' $false)
        })
    return [pscustomobject]@{
        Drive    = $Drive
        Current  = $cur
        Previous = $prev
        Hours    = $hours
        Growth   = $growth
        Recent24 = (& $window 24)
        Recent48 = (& $window 48)
        Recent7d = (& $window 168)
        Known    = $known
        SkippedOtherMode = $skippedOtherMode
    }
}

function Write-ReclaimHotspotsReport($H) {
    $c = $H.Current
    Write-Host ''
    Write-Host ("Hotspots on {0}   scan {1}   {2}" -f $c.root, $c.time, $c.mode) -ForegroundColor White
    Write-Host ("  Free now     {0} of {1}" -f (Format-Bytes $c.volume.free), (Format-Bytes $c.volume.total))
    if ($null -eq $H.Previous) {
        $why = if ($H.SkippedOtherMode) { "no earlier $($c.mode) scan ($($H.SkippedOtherMode) scan(s) in the other mode ignored: different visibility is not growth)" } else { 'no earlier scan of this drive' }
        Write-Host "  Growth       $why - this walk is the baseline; growth shows from the next run." -ForegroundColor Yellow
    } else {
        $p = $H.Previous
        $used = [long]$p.volume.free - [long]$c.volume.free
        $verb = if ($used -ge 0) { 'filled' } else { 'freed' }
        Write-Host ("  Growth       since {0} ({1:N1} h): the volume {2} {3}" -f $p.time, $H.Hours, $verb, (Format-Bytes ([math]::Abs($used))))
        $rows = @($H.Growth)
        if (-not $rows.Count) { Write-Host '               no folder grew' }
        foreach ($g in $rows) {
            $rate = if ($H.Hours -gt 0.01) { (Format-Bytes ([long]($g.Delta / $H.Hours))) + '/h' } else { '' }
            Write-Host ('    +{0,10}   {1,10} -> {2,-10} {3,12}   {4}' -f (Format-Bytes $g.Delta), (Format-Bytes $g.Before),
                (Format-Bytes $g.After), $rate, $g.Path) -ForegroundColor Yellow
        }
    }
    foreach ($w in @(@('24 hours', $H.Recent24), @('48 hours', $H.Recent48), @('7 days', $H.Recent7d))) {
        Write-Host "  Largest files written in the last $($w[0]):"
        $rows = @($w[1])
        if (-not $rows.Count) { Write-Host '    none >= 1 MB' }
        foreach ($f in $rows) {
            Write-Host ('    {0,10}   {1}   {2}' -f (Format-Bytes $f.onDisk), $f.lastWrite, $f.path)
        }
    }
    Write-Host '  Known log and dump locations (from the knowledge base):'
    $known = @($H.Known)
    if (-not $known.Count) { Write-Host '    none over 1 MB on this drive' }
    foreach ($k in $known) {
        Write-Host ('    {0,10}   newest write {1}   {2} -> {3}' -f (Format-Bytes $k.onDisk), $k.newestWrite, $k.name, $k.path)
    }
    if (@($c.denied).Count) {
        Write-Host "  Not visible  $(@($c.denied).Count) denied folders were not walked in $($c.mode) mode (see: reclaim scan $($c.drive):)." -ForegroundColor Yellow
    }
}

function Invoke-ReclaimHotspots([string[]]$Drives) {
    foreach ($d in $Drives) {
        $root = "$($d):\"
        if (-not (Test-Path -LiteralPath $root)) { Write-Host "Drive $($d): not found." -ForegroundColor Red; continue }
        Write-Host "Walking $root for hotspots (read-only) ..."
        $doc = Invoke-ReclaimScanPath -Root $root -Label $d
        $h = Get-ReclaimHotspots -Drive $d
        Write-ReclaimHotspotsReport $h
        $top = @($h.Growth) | Select-Object -First 1
        $note = if ($top) { 'top growth +{0} {1}' -f (Format-Bytes $top.Delta), $top.Path } else { 'baseline walk, no earlier scan' }
        Write-WorklogStatus (Write-ReclaimWorklog -Command 'hotspots' -Drive "$($d):" -Mode $doc.mode -Note $note)
    }
}
