# Test-Hotspots.ps1 - growth between two scans and recently written files.

Invoke-Test 'hotspots: a planted growing file is the top growth and is listed in the last 24h' {
    $root = New-TestDir 'hot'
    [void](New-Item -ItemType Directory -Force -Path "$root\grow", "$root\still")
    New-FixtureFile "$root\grow\log.txt" 1048576
    New-FixtureFile "$root\still\x.bin" 2097152
    $cl = [Reclaim.Native]::ClusterSize($root)

    [void](Invoke-ReclaimScanPath -Root $root -Label 'H')
    $fs = [IO.File]::Open("$root\grow\log.txt", [IO.FileMode]::Append)
    try { $fs.Write((New-Object byte[] 5242880), 0, 5242880) } finally { $fs.Close() }
    [void](Invoke-ReclaimScanPath -Root $root -Label 'H')

    $h = Get-ReclaimHotspots -Drive 'H'
    Assert-True ($null -ne $h.Previous) 'previous scan found'
    $top = @($h.Growth)[0]
    Assert-Equal "$root\grow" $top.Path 'fastest-growing folder'
    Assert-Equal ((Get-Alloc 6291456 $cl) - (Get-Alloc 1048576 $cl)) $top.Delta 'growth = allocation difference'
    Assert-True (-not (@($h.Growth) | Where-Object { $_.Path -eq $root })) 'parent suppressed when a child explains its growth'
    Assert-True (-not (@($h.Growth) | Where-Object { $_.Path -eq "$root\still" })) 'unchanged folder not reported'

    $recent = @($h.Recent24 | Where-Object { $_.path -eq "$root\grow\log.txt" })
    Assert-Equal 1 $recent.Count 'growing file listed in the last 24h'
    Assert-Equal (Get-Alloc 6291456 $cl) ([long]$recent[0].onDisk) 'recent file on-disk is the new size'
}

Invoke-Test 'hotspots: growth split between children keeps the parent; a grandchild that explains it wins' {
    $root = New-TestDir 'hot-split'
    [void](New-Item -ItemType Directory -Force -Path "$root\split\a", "$root\split\b", "$root\deep\x\y")
    foreach ($f in 'split\a\1.bin', 'split\b\1.bin', 'deep\x\y\1.bin') { New-FixtureFile "$root\$f" 1048576 }
    [void](Invoke-ReclaimScanPath -Root $root -Label 'G')
    foreach ($g in @(@('split\a\1.bin', 3145728), @('split\b\1.bin', 3145728), @('deep\x\y\1.bin', 6291456))) {
        $fs = [IO.File]::Open("$root\$($g[0])", [IO.FileMode]::Append)
        try { $fs.Write((New-Object byte[] $g[1]), 0, $g[1]) } finally { $fs.Close() }
    }
    [void](Invoke-ReclaimScanPath -Root $root -Label 'G')
    $paths = @((Get-ReclaimHotspots -Drive 'G').Growth | ForEach-Object { $_.Path })
    foreach ($p in 'split', 'split\a', 'split\b', 'deep\x\y') { Assert-True ($paths -contains "$root\$p") "$p reported" }
    foreach ($p in 'deep', 'deep\x') { Assert-True (-not ($paths -contains "$root\$p")) "$p suppressed by its grandchild" }
}

Invoke-Test 'hotspots: growth is only measured against a previous scan taken in the same mode' {
    $root = New-TestDir 'hot-mode'
    New-FixtureFile "$root\a.bin" 2097152
    $first = Invoke-ReclaimScanPath -Root $root -Label 'M'
    $j = [IO.File]::ReadAllText($first.file) -replace '"mode":\s*"[A-Z]+"', '"mode":  "OTHER-MODE"'
    [IO.File]::WriteAllText($first.file, $j)
    New-FixtureFile "$root\b.bin" 3145728
    [void](Invoke-ReclaimScanPath -Root $root -Label 'M')
    $h = Get-ReclaimHotspots -Drive 'M'
    Assert-Equal $null $h.Previous 'a scan from another mode is not a baseline'
    Assert-Equal 0 @($h.Growth).Count 'no growth invented across modes'
    Assert-Equal 1 $h.SkippedOtherMode 'the skipped scan is reported'
}

Invoke-Test 'hotspots: first scan of a drive reports no growth instead of inventing it' {
    $root = New-TestDir 'hot-first'
    New-FixtureFile "$root\a.bin" 2097152
    [void](Invoke-ReclaimScanPath -Root $root -Label 'F')
    $h = Get-ReclaimHotspots -Drive 'F'
    Assert-Equal $null $h.Previous 'no previous scan'
    Assert-Equal 0 @($h.Growth).Count 'no growth rows'
}
