# Test-Quarantine.ps1 - verified moves, apply gates, receipts, undo, purge gating, status.

# Test-only KB rules that match fixture folders (merged through the kbExtra config key).
$kbExtra = Join-Path $script:TestRunRoot 'kb-extra.json'
[IO.File]::WriteAllText($kbExtra, @'
{ "entries": [
  { "id": "test-safe", "name": "test SAFE cache", "kind": "dir", "patterns": ["**\\reclaim-test-safe"],
    "creator": "test", "purpose": "test", "breaks": "nothing", "safety": "SAFE", "regenerates": "yes",
    "action": "DELETE", "method": "test", "command": "", "processes": [], "hotspot": false },
  { "id": "test-closed", "name": "test SAFE-IF-CLOSED cache", "kind": "dir", "patterns": ["**\\reclaim-test-closed"],
    "creator": "test", "purpose": "test", "breaks": "nothing", "safety": "SAFE-IF-CLOSED", "regenerates": "yes",
    "action": "DELETE", "method": "test", "command": "", "processes": ["reclaim-fake-proc"], "hotspot": false },
  { "id": "test-admin", "name": "test ADMIN-ONLY", "kind": "dir", "patterns": ["**\\reclaim-test-admin"],
    "creator": "test", "purpose": "test", "breaks": "nothing", "safety": "ADMIN-ONLY", "regenerates": "yes",
    "action": "DELETE", "method": "test", "command": "", "processes": [], "hotspot": false },
  { "id": "test-move", "name": "test MOVE", "kind": "dir", "patterns": ["**\\reclaim-test-move"],
    "creator": "test", "purpose": "test", "breaks": "nothing", "safety": "MOVE", "regenerates": "no",
    "action": "MOVE", "method": "test", "command": "", "processes": [], "hotspot": false },
  { "id": "test-logs", "name": "test log files", "kind": "file", "patterns": ["**\\reclaim-test-logs\\*.rlog"],
    "creator": "test", "purpose": "test", "breaks": "nothing", "safety": "SAFE", "regenerates": "yes",
    "action": "DELETE", "method": "test", "command": "", "processes": [], "hotspot": false }
] }
'@)
(Get-ReclaimConfig) | Add-Member -NotePropertyName kbExtra -NotePropertyValue $kbExtra -Force
Reset-ReclaimKb

function Get-TreeHashes([string]$Root) {
    $h = @{}
    foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        $h[$f.FullName.Substring($Root.Length)] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    }
    return (($h.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';')
}

function New-PlanEntry([string]$Id, [string]$Path, [string]$RuleId, [string[]]$Exclude = @()) {
    $e = Get-ReclaimEntry $RuleId
    return [pscustomobject]@{
        id = $Id; drive = $Path.Substring(0, 1); kind = 'dir'; path = $Path; ruleId = $RuleId; name = $e.name
        safety = $e.safety; action = $e.action; executable = $true; needsAdmin = $false
        onDisk = 0; logical = 0; frees = 0; freesNote = ''; command = "reclaim apply --only $Id"; method = ''
        reason = ''; processes = @($e.processes); runningNow = @(); members = @(); exclude = $Exclude
    }
}

function New-TestPlan([object[]]$Entries) {
    return [pscustomobject]@{ stamp = 'test'; time = (Get-Date).ToString('s'); mode = 'TEST'; scans = @(); entries = @($Entries); file = 'test' }
}

function New-FixtureDir([string]$Parent, [string]$Name, [int]$Files = 2) {
    $d = Join-Path (New-TestDir $Parent) $Name
    [void](New-Item -ItemType Directory -Force -Path $d)
    for ($i = 1; $i -le $Files; $i++) { New-FixtureFile (Join-Path $d "f$i.bin") (100000 * $i) $i }
    return $d
}

$yes = { param($Entry) $true }
$no = { param($Entry) $false }

Invoke-Test 'mover: cross-volume move is hash-verified, source removed only after, bytes identical' {
    $src = New-TestDir 'mv-src'
    $dst = New-TestDir 'mv-dst' $script:TestXVolRoot
    New-FixtureFile "$src\a.bin" 3000000 11
    $h = (Get-FileHash -LiteralPath "$src\a.bin" -Algorithm SHA256).Hash
    $r = [Reclaim.Mover]::MoveFile("$src\a.bin", "$dst\sub\a.bin")
    Assert-Equal 'ok' $r.Status "status ($($r.Error))"
    Assert-Equal $h $r.Sha256.ToUpperInvariant() 'sha256 recorded'
    Assert-True (-not (Test-Path -LiteralPath "$src\a.bin")) 'source removed after verification'
    Assert-Equal $h (Get-FileHash -LiteralPath "$dst\sub\a.bin" -Algorithm SHA256).Hash 'destination identical'
}

Invoke-Test 'mover: never overwrites an existing destination' {
    $src = New-TestDir 'mv2-src'
    $dst = New-TestDir 'mv2-dst' $script:TestXVolRoot
    New-FixtureFile "$src\a.bin" 5000 1
    New-FixtureFile "$dst\a.bin" 7000 2
    $r = [Reclaim.Mover]::MoveFile("$src\a.bin", "$dst\a.bin")
    Assert-Equal 'failed' $r.Status 'refused'
    Assert-Equal 5000 (Get-Item -LiteralPath "$src\a.bin").Length 'source untouched'
    Assert-Equal 7000 (Get-Item -LiteralPath "$dst\a.bin").Length 'destination untouched'
}

Invoke-Test 'mover: a file open for writing is not moved and leaves no copy' {
    $src = New-TestDir 'mv3-src'
    $dst = New-TestDir 'mv3-dst' $script:TestXVolRoot
    New-FixtureFile "$src\busy.log" 5000
    $fs = [IO.File]::Open("$src\busy.log", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try { $r = [Reclaim.Mover]::MoveFile("$src\busy.log", "$dst\busy.log") } finally { $fs.Close() }
    Assert-Equal 'failed' $r.Status "in-use file refused ($($r.Error))"
    Assert-True (Test-Path -LiteralPath "$src\busy.log") 'source still there'
    Assert-True (-not (Test-Path -LiteralPath "$dst\busy.log")) 'no destination file'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $dst -Force).Count 'no partial copy left'
}

Invoke-Test 'apply + undo: scan -> plan -> quarantine -> undo round trip; nested items excluded' {
    $root = New-TestDir 'qa'
    $nm = "$root\proj\node_modules"
    [void](New-Item -ItemType Directory -Force -Path "$nm\pkg\lib")
    New-FixtureFile "$nm\a.js" 1048576 3
    New-FixtureFile "$nm\pkg\lib\b.js" 2097152 4
    New-FixtureFile "$nm\pkg\disk.iso" 1048576 5
    $before = Get-TreeHashes $nm
    [void](Invoke-ReclaimScanPath -Root $root -Label 'A')
    $plan = New-ReclaimPlan -Drives @('A')
    $entry = @($plan.entries | Where-Object { $_.path -eq $nm })[0]
    Assert-True ($null -ne $entry) 'node_modules is in the plan'
    Assert-True (@($entry.exclude) -contains "$nm\pkg\disk.iso") 'nested iso item is excluded'

    $res = @(Invoke-ReclaimApply -Only @($entry.id) -Confirm $yes -Plan $plan)
    Assert-Equal 1 $res.Count 'one item applied'
    Assert-Equal 'ok' $res[0].Status "apply status ($($res[0].Reason))"
    Assert-True (-not (Test-Path -LiteralPath "$nm\a.js")) 'a.js moved out'
    Assert-True (-not (Test-Path -LiteralPath "$nm\pkg\lib\b.js")) 'b.js moved out'
    Assert-True (Test-Path -LiteralPath "$nm\pkg\disk.iso") 'excluded nested item left in place'
    Assert-True (Test-Path -LiteralPath $nm) 'item root folder kept'

    $rc = Get-ReclaimReceipt $res[0].ReceiptId
    Assert-Equal 2 ([int]$rc.counts.moved) 'two files moved'
    Assert-True ($rc.dest -like '*\quarantine\*') 'lands in quarantine'
    Assert-True (Test-Path -LiteralPath (Join-Path $rc.dest 'manifest.json')) 'manifest next to the files'
    Assert-True (Test-Path -LiteralPath (Join-Path $rc.dest 'manifest-files.tsv')) 'per-file manifest'
    Assert-Equal 'npm install / pnpm install' (($rc.explanation.regenerates -split ' - ')[1]) 'explanation shown is stored'

    $u = Invoke-ReclaimUndo -ReceiptId $res[0].ReceiptId
    Assert-Equal 'ok' $u.Status 'undo status'
    Assert-Equal 2 $u.Restored 'two files restored'
    Assert-Equal $before (Get-TreeHashes $nm) 'every file back, byte-identical'
}

Invoke-Test 'undo: a file that reappeared at the original path is not overwritten' {
    $dir = New-FixtureDir 'qb' 'reclaim-test-safe' 2
    $plan = New-TestPlan @(New-PlanEntry 'T-001' $dir 'test-safe')
    $res = @(Invoke-ReclaimApply -Only @('T-001') -Confirm $yes -Plan $plan)
    Assert-Equal 'ok' $res[0].Status "apply ($($res[0].Reason))"
    New-FixtureFile "$dir\f1.bin" 5 8
    $u = Invoke-ReclaimUndo -ReceiptId $res[0].ReceiptId
    Assert-Equal 'partial' $u.Status 'partial undo'
    Assert-Equal 1 $u.Conflicts 'one conflict'
    Assert-Equal 5 (Get-Item -LiteralPath "$dir\f1.bin").Length 'reappeared file untouched'
    Assert-True (Test-Path -LiteralPath "$dir\f2.bin") 'the other file restored'
}

Invoke-Test 'apply: SAFE-IF-CLOSED is refused while its creator process runs' {
    $dir = New-FixtureDir 'qc' 'reclaim-test-closed' 1
    $before = Get-TreeHashes $dir
    $plan = New-TestPlan @(New-PlanEntry 'T-002' $dir 'test-closed')
    $res = @(Invoke-ReclaimApply -Only @('T-002') -Confirm $yes -Plan $plan -Running @{ 'reclaim-fake-proc' = $true })
    Assert-Equal 'refused' $res[0].Status 'refused'
    Assert-True ($res[0].Reason -like '*reclaim-fake-proc*') "names the process: $($res[0].Reason)"
    Assert-Equal $before (Get-TreeHashes $dir) 'nothing moved'
}

Invoke-Test 'apply: --yes-to-safe approves SAFE only; everything else still asks' {
    $safe = New-FixtureDir 'qd' 'reclaim-test-safe' 1
    $move = New-FixtureDir 'qd2' 'reclaim-test-move' 1
    $plan = New-TestPlan @((New-PlanEntry 'T-003' $safe 'test-safe'), (New-PlanEntry 'T-004' $move 'test-move'))
    $res = @(Invoke-ReclaimApply -YesToSafe -Confirm $no -Plan $plan)
    $byId = @{}; foreach ($r in $res) { $byId[$r.Id] = $r }
    Assert-Equal 'ok' $byId['T-003'].Status 'SAFE auto-approved'
    Assert-Equal 'declined' $byId['T-004'].Status 'MOVE still asked and declined'
    Assert-True (Test-Path -LiteralPath "$move\f1.bin") 'MOVE item untouched'
}

Invoke-Test 'apply: admin-only item is never attempted unelevated; prints the elevated command' {
    $dir = New-FixtureDir 'qe' 'reclaim-test-admin' 1
    $before = Get-TreeHashes $dir
    $plan = New-TestPlan @(New-PlanEntry 'T-005' $dir 'test-admin')
    $res = @(Invoke-ReclaimApply -Only @('T-005') -Confirm $yes -Plan $plan -Elevated $false)
    Assert-Equal 'needs-admin' $res[0].Status 'not attempted'
    Assert-True ($res[0].Reason -like '*reclaim apply --only T-005*') "elevated command given: $($res[0].Reason)"
    Assert-Equal $before (Get-TreeHashes $dir) 'nothing moved'
}

Invoke-Test 'apply: refuses paths whose KB rule no longer matches, and anything inside the data root' {
    $dir = New-FixtureDir 'qf' 'not-a-cache' 1
    $plan = New-TestPlan @(New-PlanEntry 'T-006' $dir 'test-safe')
    $res = @(Invoke-ReclaimApply -Only @('T-006') -Confirm $yes -Plan $plan)
    Assert-Equal 'refused' $res[0].Status 'rule mismatch refused'
    $inside = Join-Path (Get-ReclaimPath 'scans') 'reclaim-test-safe'
    [void](New-Item -ItemType Directory -Force -Path $inside)
    New-FixtureFile "$inside\x.bin" 1000
    $plan2 = New-TestPlan @(New-PlanEntry 'T-007' $inside 'test-safe')
    $res2 = @(Invoke-ReclaimApply -Only @('T-007') -Confirm $yes -Plan $plan2)
    Assert-Equal 'refused' $res2[0].Status 'data root is protected'
    Assert-True (Test-Path -LiteralPath "$inside\x.bin") 'still there'
}

Invoke-Test 'apply: an interrupted move still leaves a receipt, and undo restores what moved' {
    $dir = New-FixtureDir 'qi' 'reclaim-test-safe' 3
    $before = Get-TreeHashes $dir
    $saved = $script:ReclaimMoveAll
    $script:ReclaimMoveAll = {
        param($Files, $DestRoot, $Tsv)
        $one = New-Object 'System.Collections.Generic.List[Reclaim.FileRec]'
        $one.Add($Files[0])
        [void][Reclaim.Mover]::MoveAll($one, $DestRoot, $Tsv)
        throw 'simulated crash mid-move'
    }
    try {
        $res = @(Invoke-ReclaimApply -Only @('T-030') -Confirm $yes -Plan (New-TestPlan @(New-PlanEntry 'T-030' $dir 'test-safe')))
    } finally { $script:ReclaimMoveAll = $saved }
    Assert-Equal 'interrupted' $res[0].Status "status ($($res[0].Reason))"
    $rc = Get-ReclaimReceipt $res[0].ReceiptId
    Assert-Equal 'interrupted' $rc.status 'receipt records the interruption'
    $u = Invoke-ReclaimUndo -ReceiptId $res[0].ReceiptId
    Assert-Equal 1 $u.Restored 'the one moved file comes back'
    Assert-Equal $before (Get-TreeHashes $dir) 'tree identical again'
}

Invoke-Test 'apply: nested items that appeared after the plan are excluded too (re-derived live)' {
    $root = New-TestDir 'qj'
    $nm = "$root\proj\node_modules"
    [void](New-Item -ItemType Directory -Force -Path "$nm\pkg")
    New-FixtureFile "$nm\a.js" 1048576 3
    $plan = New-TestPlan @(New-PlanEntry 'T-031' $nm 'node-modules')
    New-FixtureFile "$nm\pkg\late.iso" 1048576 9
    $res = @(Invoke-ReclaimApply -Only @('T-031') -Confirm $yes -Plan $plan)
    Assert-Equal 'ok' $res[0].Status "apply ($($res[0].Reason))"
    Assert-True (Test-Path -LiteralPath "$nm\pkg\late.iso") 'nested item that appeared later is left for its own decision'
    Assert-True (-not (Test-Path -LiteralPath "$nm\a.js")) 'the rest moved'
}

Invoke-Test 'apply: a files-kind item moves only its matching members' {
    $dir = New-TestDir 'qk\reclaim-test-logs'
    New-FixtureFile "$dir\a.rlog" 5000 1
    New-FixtureFile "$dir\b.rlog" 6000 2
    New-FixtureFile "$dir\keep.txt" 7000 3
    $pe = New-PlanEntry 'T-032' $dir 'test-logs'
    $pe.kind = 'files'
    $pe.members = @("$dir\a.rlog", "$dir\b.rlog")
    $res = @(Invoke-ReclaimApply -Only @('T-032') -Confirm $yes -Plan (New-TestPlan @($pe)))
    Assert-Equal 'ok' $res[0].Status "apply ($($res[0].Reason))"
    Assert-True (-not (Test-Path -LiteralPath "$dir\a.rlog")) 'member a moved'
    Assert-True (-not (Test-Path -LiteralPath "$dir\b.rlog")) 'member b moved'
    Assert-True (Test-Path -LiteralPath "$dir\keep.txt") 'non-member untouched'
}

Invoke-Test 'apply: folders listed in config protectedPaths are never moved' {
    $dir = New-FixtureDir 'qh' 'reclaim-test-safe' 1
    $cfg = Get-ReclaimConfig
    $cfg | Add-Member -NotePropertyName protectedPaths -NotePropertyValue @((Split-Path -Parent $dir)) -Force
    try {
        $res = @(Invoke-ReclaimApply -Only @('T-020') -Confirm $yes -Plan (New-TestPlan @(New-PlanEntry 'T-020' $dir 'test-safe')))
        Assert-Equal 'refused' $res[0].Status 'protected by config'
        Assert-True ($res[0].Reason -like '*protected*') "reason: $($res[0].Reason)"
        Assert-True (Test-Path -LiteralPath "$dir\f1.bin") 'untouched'
    } finally { $cfg.protectedPaths = @() }
}

Invoke-Test 'purge: lists unpinned quarantine past its date; --execute refuses without a person present' {
    $a = New-FixtureDir 'qg' 'reclaim-test-safe' 1
    $b = New-FixtureDir 'qg2' 'reclaim-test-safe' 1
    $plan = New-TestPlan @((New-PlanEntry 'T-008' $a 'test-safe'), (New-PlanEntry 'T-009' $b 'test-safe'))
    $res = @(Invoke-ReclaimApply -Confirm $yes -Plan $plan)
    Assert-Equal 2 @($res | Where-Object { $_.Status -eq 'ok' }).Count 'both quarantined'
    Set-ReclaimPin -ReceiptId $res[1].ReceiptId
    $ids = @(Get-ReclaimPurgeCandidates -AsOf (Get-Date).AddDays(31) | ForEach-Object { $_.id })
    Assert-True ($ids -contains $res[0].ReceiptId) 'expired entry is a candidate'
    Assert-True (-not ($ids -contains $res[1].ReceiptId)) 'pinned entry is not'
    Assert-Equal 0 @(Get-ReclaimPurgeCandidates -AsOf (Get-Date) | Where-Object { $_.id -eq $res[0].ReceiptId }).Count 'not before 30 days'
    $p = Invoke-ReclaimPurge -Execute -Interactive:$false -AsOf (Get-Date).AddDays(31)
    Assert-Equal 'refused' $p.Status 'no unattended purge'
    Assert-True (Test-Path -LiteralPath (Get-ReclaimReceipt $res[0].ReceiptId).dest) 'quarantined files still there'
}

Invoke-Test 'status: free space per drive and measured quarantine size' {
    $s = Get-ReclaimStatus
    Assert-True (@($s.Drives).Count -ge 1) 'drives listed'
    Assert-True ([long]$s.QuarantineOnDisk -gt 0) 'quarantine measured on disk'
    Assert-True (@($s.NextPurge).Count -ge 1) 'next purge-eligible entries listed'
}
