# Test-Plan.ps1 - plan maps KB knowledge to actions deterministically and never touches the disk.

function New-SyntheticScan([string]$Drive, [object[]]$Items) {
    $n = 0
    $recs = foreach ($i in $Items) {
        $n++
        $e = Get-ReclaimEntry $i.ruleId
        [pscustomobject]@{
            id = ('{0}-{1:000}' -f $Drive, $n); kind = $i.kind; path = $i.path; ruleId = $i.ruleId
            name = $e.name; safety = $e.safety; action = $e.action
            onDisk = [long]$i.onDisk; logical = [long]$i.onDisk; totalOnDisk = [long]$i.onDisk
            totalLogical = [long]$i.onDisk; files = 1; newestWrite = ''; placeholderLogical = 0; members = @()
        }
    }
    return [pscustomobject]@{
        drive = $Drive; root = "$($Drive):\"; stamp = 'synthetic'; time = (Get-Date).ToString('s')
        mode = 'UNELEVATED'; items = @($recs); file = 'synthetic'
    }
}

Invoke-Test 'plan: actions come from the KB; UNKNOWN is KEEP; admin locations flagged; same volume frees 0' {
    $same = (Get-ReclaimConfig).dataRoot.Substring(0, 1).ToUpperInvariant()
    $other = if ($same -eq 'Z') { 'W' } else { 'Z' }
    $u = [IO.Path]::GetFileName($env:USERPROFILE)   # own profile: not an admin-only location
    $scan = New-SyntheticScan $other @(
        @{ kind = 'file'; path = "$($other):\hiberfil.sys"; ruleId = 'hiberfil'; onDisk = 8GB },
        @{ kind = 'dir'; path = "$($other):\Users\$u\AppData\Local\npm-cache"; ruleId = 'npm-cache'; onDisk = 3GB },
        @{ kind = 'dir'; path = "$($other):\stuff"; ruleId = $null; onDisk = 2GB },
        @{ kind = 'dir'; path = "$($other):\Windows\WinSxS"; ruleId = 'winsxs'; onDisk = 9GB },
        @{ kind = 'dir'; path = "$($other):\Windows\Temp"; ruleId = 'windows-temp'; onDisk = 1GB },
        @{ kind = 'dir'; path = "$($other):\Users\$u\Downloads"; ruleId = 'downloads'; onDisk = 4GB }
    )
    $sameScan = New-SyntheticScan $same @(
        @{ kind = 'dir'; path = "$($same):\Users\$u\Downloads"; ruleId = 'downloads'; onDisk = 5GB }
    )
    $byPath = @{}
    foreach ($e in @(ConvertTo-ReclaimPlanEntries -Scan $scan) + @(ConvertTo-ReclaimPlanEntries -Scan $sameScan)) { $byPath[$e.path] = $e }

    $h = $byPath["$($other):\hiberfil.sys"]
    Assert-Equal 'DISABLE' $h.action 'hiberfil -> DISABLE'
    Assert-Equal $false $h.executable 'DISABLE is never executed by Reclaim'
    Assert-True ($h.command -like 'powercfg /hibernate off*') "hiberfil command: $($h.command)"

    $n = $byPath["$($other):\Users\$u\AppData\Local\npm-cache"]
    Assert-Equal 'DELETE' $n.action 'npm cache -> DELETE (quarantine)'
    Assert-Equal $true $n.executable 'quarantine is executable'
    Assert-Equal "reclaim apply --only $($other)-002" $n.command 'exact apply command'
    Assert-Equal ([long]3GB) ([long]$n.frees) 'cross-volume quarantine frees its on-disk size'

    $unk = $byPath["$($other):\stuff"]
    Assert-Equal 'KEEP' $unk.action 'UNKNOWN is never proposed'
    Assert-Equal 'UNKNOWN' $unk.safety 'safety stays UNKNOWN'
    Assert-True ($unk.reason -like '*unknown*') "UNKNOWN reason: $($unk.reason)"

    Assert-Equal 'KEEP' $byPath["$($other):\Windows\WinSxS"].action 'WinSxS -> KEEP'

    $t = $byPath["$($other):\Windows\Temp"]
    Assert-Equal $true $t.needsAdmin 'Windows\Temp needs admin'
    Assert-True ($t.command -like '*(elevated)*') "elevated command: $($t.command)"

    $d = $byPath["$($same):\Users\$u\Downloads"]
    Assert-True ($null -ne $d) "same-volume entry present; keys: $($byPath.Keys -join ' | ')"
    Assert-Equal 'MOVE' $d.action 'Downloads -> MOVE'
    Assert-Equal ([long]0) ([long]$d.frees) 'same volume as the data root frees nothing now'
}

Invoke-Test 'plan: builds from the latest scan, is saved, and changes nothing on disk' {
    $root = New-TestDir 'planroot'
    [void](New-Item -ItemType Directory -Force -Path "$root\web\node_modules")
    New-FixtureFile "$root\web\node_modules\x.js" 3145728
    New-FixtureFile "$root\keep.txt" 4096
    [void](Invoke-ReclaimScanPath -Root $root -Label 'P')
    $before = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$((Get-FileHash -LiteralPath $_.FullName).Hash)" })
    $plan = New-ReclaimPlan -Drives @('P')
    $after = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$((Get-FileHash -LiteralPath $_.FullName).Hash)" })
    Assert-Equal ($before -join "`n") ($after -join "`n") 'fixture tree unchanged'
    Assert-True (Test-Path -LiteralPath $plan.file) 'plan saved'
    $nm = @($plan.entries | Where-Object { $_.path -eq "$root\web\node_modules" })
    Assert-Equal 1 $nm.Count 'node_modules in the plan'
    Assert-Equal 'DELETE' $nm[0].action 'node_modules -> DELETE'
}
