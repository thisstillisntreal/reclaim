# Test-Explain.ps1 - explanations come from the KB or say "unknown"; advisor replies are parsed
# defensively and never fill gaps with guesses.

Invoke-Test 'explain: a KB folder resolves to its entry and is measured live' {
    $root = New-TestDir 'explain'
    [void](New-Item -ItemType Directory -Force -Path "$root\proj\node_modules")
    New-FixtureFile "$root\proj\node_modules\x.js" 1048576
    $cl = [Reclaim.Native]::ClusterSize($root)
    $x = Resolve-ReclaimExplanation -Path "$root\proj\node_modules"
    Assert-Equal 'node-modules' $x.Entry.id 'entry'
    Assert-Equal 'exact' $x.MatchedBy 'matched directly'
    Assert-Equal (Get-Alloc 1048576 $cl) $x.OnDisk 'on-disk measured now'
    Assert-Equal 1048576 $x.Logical 'logical measured now'
    Assert-True (@($x.Commands) -match 'reclaim').Count 'offers the reclaim command'
}

Invoke-Test 'explain: a file inside a KB folder resolves to the ancestor entry' {
    $root = New-TestDir 'explain-anc'
    [void](New-Item -ItemType Directory -Force -Path "$root\web\node_modules\pkg")
    New-FixtureFile "$root\web\node_modules\pkg\i.js" 5000
    $cl = [Reclaim.Native]::ClusterSize($root)
    $x = Resolve-ReclaimExplanation -Path "$root\web\node_modules\pkg\i.js"
    Assert-Equal 'node-modules' $x.Entry.id 'ancestor entry'
    Assert-Equal 'ancestor' $x.MatchedBy 'matched via ancestor'
    Assert-Equal "$root\web\node_modules" $x.MatchedPath 'ancestor path'
    Assert-Equal $false $x.IsDir 'is a file'
    Assert-Equal (Get-Alloc 5000 $cl) $x.OnDisk 'file on-disk'
}

Invoke-Test 'explain: an unmatched folder is UNKNOWN and nothing is invented' {
    $root = New-TestDir 'explain-unknown'
    [void](New-Item -ItemType Directory -Force -Path "$root\mystery")
    New-FixtureFile "$root\mystery\blob.xyz" 70000
    $x = Resolve-ReclaimExplanation -Path "$root\mystery"
    Assert-Equal 'UNKNOWN' $x.Entry.safety 'safety'
    foreach ($f in 'creator', 'purpose', 'breaks', 'regenerates') { Assert-Equal 'unknown' $x.Entry.$f "$f says unknown" }
    Assert-Equal 'none' $x.MatchedBy 'no match'
    Assert-Equal 0 @(@($x.Commands) | Where-Object { $_ -match 'apply' }).Count 'no reclaim command for UNKNOWN'
}

Invoke-Test 'engine: StatFile measures one file without walking its folder' {
    $root = New-TestDir 'stat'
    New-FixtureFile "$root\one.bin" 12345
    $cl = [Reclaim.Native]::ClusterSize($root)
    $f = [Reclaim.Walker]::StatFile("$root\one.bin")
    Assert-True ($null -ne $f) 'found'
    Assert-Equal 12345 $f.Logical 'logical'
    Assert-Equal (Get-Alloc 12345 $cl) $f.OnDisk 'on-disk'
    Assert-Equal $null ([Reclaim.Walker]::StatFile("$root\missing.bin")) 'missing file -> null'
}

Invoke-Test 'advisor: replies are parsed defensively; gaps stay unknown' {
    $a = ConvertFrom-ReclaimAdvisorReply '```json
{"what": "Blender cache", "creator": "Blender", "purpose": "render cache", "risk": ""}
```'
    Assert-Equal $true $a.Parsed 'fenced JSON parsed'
    Assert-Equal 'Blender cache' $a.what 'what'
    Assert-Equal 'unknown' $a.risk 'empty field becomes unknown'
    $b = ConvertFrom-ReclaimAdvisorReply 'I think this is probably a game.'
    Assert-Equal $false $b.Parsed 'prose is not accepted'
    foreach ($f in 'what', 'creator', 'purpose', 'risk') { Assert-Equal 'unknown' $b.$f "$f unknown on unparseable reply" }
}

Invoke-Test 'advisor: prompt carries names and sizes only and demands "unknown" over guessing' {
    $root = New-TestDir 'advisor'
    [void](New-Item -ItemType Directory -Force -Path "$root\thing")
    [IO.File]::WriteAllText("$root\thing\secret-notes.txt", 'TOP SECRET CONTENT 12345')
    $x = Resolve-ReclaimExplanation -Path "$root\thing"
    $p = Get-ReclaimAdvisorPrompt $x
    Assert-True ($p -like '*secret-notes.txt*') 'file names included'
    Assert-True ($p -notlike '*TOP SECRET CONTENT*') 'file contents never included'
    Assert-True ($p -like '*"unknown"*') 'instructs to answer unknown'
}
