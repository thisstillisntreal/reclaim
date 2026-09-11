# Test-Engine.ps1 - walker measures exact bytes, skips junctions, records denied dirs.

function New-WalkOptions {
    $o = New-Object Reclaim.ScanOptions
    $o.UseBackupPrivilege = $false
    return $o
}

Invoke-Test 'walker: exact logical and on-disk bytes' {
    $root = New-TestDir 'walker'
    New-FixtureFile "$root\a.bin" 5000
    New-FixtureFile "$root\b.bin" 1048576
    [void](New-Item -ItemType Directory -Path "$root\sub")
    New-FixtureFile "$root\sub\c.bin" 3145729
    New-FixtureFile "$root\sub\empty.bin" 0
    $cl = [Reclaim.Native]::ClusterSize($root)
    Assert-True ($cl -ge 512) "cluster size read ($cl)"

    $r = [Reclaim.Walker]::Scan($root, (New-WalkOptions))
    $top = $r.Dirs[0]
    $sub = @($r.Dirs | Where-Object { $_.Path -eq "$root\sub" })[0]
    Assert-Equal $root $top.Path 'root path'
    Assert-Equal 4199305 $top.Logical 'root logical bytes'
    Assert-Equal 4 $top.Files 'root file count'
    Assert-Equal 3145729 $sub.Logical 'sub logical bytes'
    Assert-Equal 2 $sub.Files 'sub file count'
    $expected = (Get-Alloc 5000 $cl) + (Get-Alloc 1048576 $cl) + (Get-Alloc 3145729 $cl)
    Assert-Equal $expected $top.OnDisk 'root on-disk bytes = cluster-rounded allocation'
    Assert-Equal (Get-Alloc 3145729 $cl) $sub.OnDisk 'sub on-disk bytes'
    Assert-Equal 0 $r.Denied.Count 'no denied paths'
}

Invoke-Test 'walker: junction is skipped, not followed' {
    $root = New-TestDir 'junction'
    [void](New-Item -ItemType Directory -Path "$root\real")
    New-FixtureFile "$root\real\x.bin" 1048576
    [void](New-Item -ItemType Junction -Path "$root\link" -Target "$root\real")
    $r = [Reclaim.Walker]::Scan($root, (New-WalkOptions))
    Assert-Equal 1048576 $r.Dirs[0].Logical 'junction target counted once'
    Assert-Equal 1 $r.Skipped.Count 'one skipped reparse point'
    Assert-Equal "$root\link" $r.Skipped[0].Path 'skipped path'
}

Invoke-Test 'walker: access-denied directory is recorded' {
    $root = New-TestDir 'denied'
    [void](New-Item -ItemType Directory -Path "$root\locked")
    New-FixtureFile "$root\locked\hidden.bin" 4096
    & icacls.exe "$root\locked" /deny '*S-1-1-0:(RD)' | Out-Null
    try {
        $r = [Reclaim.Walker]::Scan($root, (New-WalkOptions))
        Assert-Equal 1 $r.Denied.Count 'one denied path'
        Assert-Equal "$root\locked" $r.Denied[0] 'denied path'
    } finally {
        & icacls.exe "$root\locked" /remove:d '*S-1-1-0' | Out-Null
    }
}

Invoke-Test 'walker: UseBackupPrivilege=$false holds even after an elevated walk enabled it in this process' {
    $root = New-TestDir 'denied2'
    [void](New-Item -ItemType Directory -Path "$root\locked")
    New-FixtureFile "$root\locked\hidden.bin" 4096
    & icacls.exe "$root\locked" /deny '*S-1-1-0:(RD)' | Out-Null
    try {
        $on = New-Object Reclaim.ScanOptions
        $on.UseBackupPrivilege = $true
        [void][Reclaim.Walker]::Scan($root, $on)
        $r = [Reclaim.Walker]::Scan($root, (New-WalkOptions))
        Assert-Equal 1 $r.Denied.Count 'denied again once the option turns the privilege off'
    } finally {
        & icacls.exe "$root\locked" /remove:d '*S-1-1-0' | Out-Null
    }
}

Invoke-Test 'walker: cloud placeholder attributes are recognised' {
    Assert-True ([Reclaim.Walker]::IsPlaceholder(0x400000)) 'RecallOnDataAccess'
    Assert-True ([Reclaim.Walker]::IsPlaceholder(0x40000)) 'RecallOnOpen'
    Assert-True ([Reclaim.Walker]::IsPlaceholder(0x1000)) 'Offline'
    Assert-True (-not [Reclaim.Walker]::IsPlaceholder(0x20)) 'Archive only is local'
}

Invoke-Test 'walker: recent files are captured with write time' {
    $root = New-TestDir 'recent'
    New-FixtureFile "$root\new.bin" 2097152
    $o = New-WalkOptions
    $o.RecentMinBytes = 1048576
    $r = [Reclaim.Walker]::Scan($root, $o)
    $f = @($r.Files | Where-Object { $_.Path -eq "$root\new.bin" })
    Assert-Equal 1 $f.Count 'recent file recorded'
    $age = (Get-Date).ToUniversalTime() - [DateTime]::FromFileTimeUtc($f[0].LastWrite)
    Assert-True ($age.TotalMinutes -lt 10) "write time is recent ($($age.TotalMinutes) min)"
}
