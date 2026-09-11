# Test-Classify.ps1 - glob patterns, KB loading, and the residual item model.

Invoke-Test 'kb: glob patterns become anchored, case-insensitive regexes' {
    $rx = ConvertTo-ReclaimRegex '?:\Windows\Temp'
    Assert-True ('C:\Windows\Temp' -match $rx) 'exact path'
    Assert-True ('d:\windows\temp' -match $rx) 'any drive, any case'
    Assert-True (-not ('C:\Windows\Temp\x' -match $rx)) 'child does not match'
    Assert-True (-not ('C:\X\Windows\Temp' -match $rx)) 'anchored at the drive'

    $rx = ConvertTo-ReclaimRegex '%USERS%\AppData\Local\Temp'
    Assert-True ('C:\Users\alice\AppData\Local\Temp' -match $rx) '%USERS% = one profile segment'
    Assert-True (-not ('C:\Users\alice\x\AppData\Local\Temp' -match $rx)) 'profile is exactly one segment'

    $rx = ConvertTo-ReclaimRegex '**\node_modules'
    Assert-True ('Q:\node_modules' -match $rx) '** matches zero extra segments'
    Assert-True ('Q:\a\b\node_modules' -match $rx) '** matches many segments'
    Assert-True (-not ('Q:\a\node_modulesX' -match $rx)) 'last segment is whole'

    $rx = ConvertTo-ReclaimRegex '?:\Users\TEMP.*'
    Assert-True ('C:\Users\TEMP.PC01' -match $rx) '* inside a segment'
    Assert-True (-not ('C:\Users\TEMPX' -match $rx)) 'dot is literal'
    Assert-True (-not ('C:\Users\TEMP.PC01\Downloads' -match $rx)) '* never crosses a backslash'
}

Invoke-Test 'kb: more literal characters = more specific' {
    $a = Get-ReclaimPatternSpecificity '?:\Windows\SoftwareDistribution\Download'
    $b = Get-ReclaimPatternSpecificity '?:\Windows\SoftwareDistribution'
    $c = Get-ReclaimPatternSpecificity '**\*.iso'
    Assert-True ($a -gt $b) "Download ($a) beats SoftwareDistribution ($b)"
    Assert-True ($b -gt $c) "SoftwareDistribution ($b) beats **\*.iso ($c)"
}

Invoke-Test 'kb: specificity of a pattern with one literal character (StrictMode scalar trap)' {
    Assert-Equal 1 (Get-ReclaimPatternSpecificity 'a*') 'one literal character'
    Assert-Equal 0 (Get-ReclaimPatternSpecificity '*') 'no literal characters'
}

Invoke-Test 'kb: shipped knowledge base loads and covers the required seeds' {
    $kb = Get-ReclaimKb
    foreach ($id in 'hiberfil', 'pagefile', 'swapfile', 'windows-old', 'winreagent', 'softwaredistribution',
        'sd-download', 'windows-temp', 'windows-installer', 'winsxs', 'minidump', 'memory-dmp', 'winevt',
        'chrome-cache', 'edge-cache', 'npm-cache', 'pip-cache', 'pnpm-store', 'nuget', 'gradle', 'cargo',
        'docker-vhdx', 'wsl-vhdx', 'adobe-media-cache', 'store-packages', 'downloads', 'desktop',
        'recycle-bin', 'svi', 'onedrive', 'claude-home', 'cursor-home', 'grok-home', 'ollama-models',
        'lmstudio-models', 'pcap', 'wireshark-temp', 'postgres-data', 'teamviewer-logs') {
        Assert-True $kb.ById.ContainsKey($id) "KB has '$id'"
    }
    Assert-Equal 'KEEP' $kb.ById['winsxs'].safety 'WinSxS is KEEP'
    foreach ($e in $kb.Entries) {
        Assert-True ($e.safety -in 'SAFE', 'SAFE-IF-CLOSED', 'MOVE', 'ADMIN-ONLY', 'KEEP') "$($e.id) safety valid"
        Assert-True ($e.action -in 'DELETE', 'MOVE', 'DISABLE', 'CLEAR-FROM-APP', 'KEEP') "$($e.id) action valid"
        foreach ($f in 'name', 'creator', 'purpose', 'breaks', 'regenerates', 'method') {
            Assert-True ([string]$e.$f).Length "$($e.id) has $f"
        }
    }
    Assert-True ($kb.Rules.Count -ge $kb.Entries.Count) 'one rule per pattern'
}

function New-TestRules {
    $entries = @(
        [pscustomobject]@{ id = 't-cache'; kind = 'dir';  patterns = @('**\Cache') },
        [pscustomobject]@{ id = 't-nm';    kind = 'dir';  patterns = @('**\node_modules') },
        [pscustomobject]@{ id = 't-dl';    kind = 'dir';  patterns = @('**\cls\Downloads') },
        [pscustomobject]@{ id = 't-iso';   kind = 'file'; patterns = @('**\*.iso') }
    )
    return , (ConvertTo-ReclaimRules $entries)
}

Invoke-Test 'classify: KB items, UNKNOWN residual, same-rule absorption, file rule splits off' {
    $root = New-TestDir 'cls'
    foreach ($d in 'app\Cache', 'proj\node_modules\pkg\node_modules', 'Downloads') {
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $d))
    }
    New-FixtureFile "$root\app\data.bin" 3145728
    New-FixtureFile "$root\app\Cache\c.bin" 5242880
    New-FixtureFile "$root\proj\node_modules\a.js" 1048576
    New-FixtureFile "$root\proj\node_modules\pkg\node_modules\b.js" 1048576
    New-FixtureFile "$root\Downloads\big.iso" 2097152
    New-FixtureFile "$root\Downloads\notes.txt" 1048576
    $cl = [Reclaim.Native]::ClusterSize($root)

    $rules = New-TestRules
    $o = New-Object Reclaim.ScanOptions
    $o.UseBackupPrivilege = $false
    $o.Rules = $rules
    $r = [Reclaim.Walker]::Scan($root, $o)
    $items = [Reclaim.Classifier]::Classify($r, $rules, 2MB, 100MB)
    $byPath = @{}
    foreach ($i in $items) { $byPath[$i.Path] = $i }

    $cache = $byPath["$root\app\Cache"]
    Assert-Equal 't-cache' $cache.RuleId 'Cache matched'
    Assert-Equal (Get-Alloc 5242880 $cl) $cache.OnDisk 'Cache on-disk'

    $app = $byPath["$root\app"]
    Assert-True ($null -ne $app) 'app became an UNKNOWN item'
    Assert-Equal $null $app.RuleId 'app is UNKNOWN'
    Assert-Equal (Get-Alloc 3145728 $cl) $app.OnDisk 'UNKNOWN sized by residual only'
    Assert-Equal ((Get-Alloc 3145728 $cl) + (Get-Alloc 5242880 $cl)) $app.TotalOnDisk 'total includes the Cache item'

    $nm = @($items | Where-Object { $_.RuleId -eq 't-nm' })
    Assert-Equal 1 $nm.Count 'nested node_modules absorbed into the outer one'
    Assert-Equal "$root\proj\node_modules" $nm[0].Path 'outer node_modules'
    Assert-Equal (2 * (Get-Alloc 1048576 $cl)) $nm[0].OnDisk 'outer includes nested bytes'

    $iso = $byPath["$root\Downloads\big.iso"]
    Assert-Equal 'file' $iso.Kind 'single matching file is a file item'
    Assert-Equal 't-iso' $iso.RuleId 'iso rule'
    Assert-Equal (Get-Alloc 2097152 $cl) $iso.OnDisk 'iso on-disk'

    $dl = $byPath["$root\Downloads"]
    Assert-Equal 't-dl' $dl.RuleId 'Downloads rule'
    Assert-Equal (Get-Alloc 1048576 $cl) $dl.OnDisk 'Downloads residual excludes the iso'

    Assert-True (-not $byPath.ContainsKey("$root\proj")) 'proj residual is 0: no item'
    Assert-True (-not $byPath.ContainsKey($root)) 'scan root is never an UNKNOWN item'
}
