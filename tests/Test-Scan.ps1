# Test-Scan.ps1 - scan persistence and ranking, worklog queueing and additive hub append.

Invoke-Test 'scan: persists json + tsv, ranks items by on-disk, assigns drive ids' {
    $root = New-TestDir 'scanroot'
    [void](New-Item -ItemType Directory -Force -Path "$root\web\node_modules", "$root\blob")
    New-FixtureFile "$root\web\node_modules\x.js" 3145728
    New-FixtureFile "$root\blob\big.dat" 4194304
    $cfg = Get-ReclaimConfig
    $saved = $cfg.dirUnknownMinBytes
    $cfg.dirUnknownMinBytes = 2MB
    try { $doc = Invoke-ReclaimScanPath -Root $root -Label 'T' } finally { $cfg.dirUnknownMinBytes = $saved }
    $cl = [Reclaim.Native]::ClusterSize($root)

    Assert-Equal 'T-001' $doc.items[0].id 'largest item ranked first'
    Assert-Equal "$root\blob" $doc.items[0].path 'UNKNOWN blob is largest'
    Assert-Equal 'UNKNOWN' $doc.items[0].safety 'blob safety'
    Assert-Equal (Get-Alloc 4194304 $cl) $doc.items[0].onDisk 'blob on-disk'
    Assert-Equal 'T-002' $doc.items[1].id 'second id'
    Assert-Equal 'node-modules' $doc.items[1].ruleId 'node_modules matched by the shipped KB'
    Assert-Equal 'SAFE-IF-CLOSED' $doc.items[1].safety 'node_modules safety'
    Assert-Equal ((Get-Alloc 4194304 $cl) + (Get-Alloc 3145728 $cl)) $doc.totals.onDisk 'total on-disk'

    $json = Join-Path (Get-ReclaimPath 'scans') ("T-{0}.json" -f $doc.stamp)
    $tsv  = Join-Path (Get-ReclaimPath 'scans') ("T-{0}.dirs.tsv" -f $doc.stamp)
    Assert-True (Test-Path -LiteralPath $json) 'scan json written'
    Assert-True (Test-Path -LiteralPath $tsv) 'dirs tsv written'
    $line = @(Get-Content -LiteralPath $tsv | Where-Object { $_ -like "$root\blob`t*" })
    Assert-Equal 1 $line.Count 'blob row in tsv'
    Assert-Equal ([string](Get-Alloc 4194304 $cl)) ($line[0] -split "`t")[1] 'tsv on-disk column'

    $latest = Get-LatestScan -Drive 'T'
    Assert-Equal $doc.stamp $latest.stamp 'latest scan is the one just written'
}

Invoke-Test 'worklog: hub disabled -> line queued locally, reported as not sent' {
    $res = Write-ReclaimWorklog -Command 'scan' -Drive 'T' -Mode 'UNELEVATED' -ReclaimedBytes 0 -Note 'test'
    Assert-Equal $false $res.Sent 'not sent'
    $pending = Join-Path (Get-ReclaimPath) 'worklog-pending.txt'
    $text = [IO.File]::ReadAllText($pending)
    Assert-True ($text -like '*| scan | T | UNELEVATED | reclaimed 0.000 GB | receipts - | test*') "pending line: $text"
}

function New-FakeHub([string]$Dir) {
    $py = @'
import io, json, os, urllib.error
STORE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "store.json")
def _load():
    return json.load(open(STORE)) if os.path.exists(STORE) else {}
def call(method, path, body=None):
    key = path.split("/kv/")[1]
    if os.environ.get("FAKEHUB_FAIL") == "1":
        raise urllib.error.HTTPError(path, 500, "boom", {}, io.BytesIO(b""))
    kv = _load()
    if method == "GET":
        if os.environ.get("FAKEHUB_DELAY"):
            import time
            time.sleep(float(os.environ["FAKEHUB_DELAY"]))   # hand back the value read before the pause
        if key not in kv:
            raise urllib.error.HTTPError(path, 404, "not found", {}, io.BytesIO(b""))
        return json.dumps({"key": key, "value": kv[key]})
    kv[key] = body["value"]
    json.dump(kv, open(STORE, "w"))
    return json.dumps({"key": key})
'@
    [IO.File]::WriteAllText((Join-Path $Dir 'fakehub.py'), $py)
    return (Join-Path $Dir 'fakehub.py')
}

Invoke-Test 'worklog: notes never carry file paths to the hub' {
    $res = Write-ReclaimWorklog -Command 'explain' -Drive 'C:' -Note 'C:\Users\someone\Wallets\key.dat -> UNKNOWN (1 MB); also D:\x y\z and \\server\share\f'
    Assert-True ($res.Line -notmatch '[A-Za-z]:\\') "no drive path in: $($res.Line)"
    Assert-True ($res.Line -notmatch '\\\\server') "no UNC path in: $($res.Line)"
    Assert-True ($res.Line -like '*<path>*') 'paths replaced by a marker'
    Assert-True ($res.Line -like '*| explain | C: |*') 'drive field kept'
}

Invoke-Test 'worklog: hub append only adds lines, never replaces; failures do not write' {
    $dir = New-TestDir 'fakehub'
    $cfg = Get-ReclaimConfig
    $saved = @($cfg.hubEnabled, $cfg.hubClient, $cfg.dataRoot)
    $cfg.hubEnabled = $true
    $cfg.hubClient = New-FakeHub $dir
    $cfg.dataRoot = Join-Path $dir 'data'
    $store = Join-Path $dir 'store.json'
    [IO.File]::WriteAllText($store, '{"worklog-reclaim": "existing line from before"}')
    try {
        $a = Write-ReclaimWorklog -Command 'scan' -Drive 'T' -Mode 'UNELEVATED' -Note 'first'
        Assert-Equal $true $a.Sent "first append sent ($($a.Error))"
        $env:FAKEHUB_FAIL = '1'
        $b = Write-ReclaimWorklog -Command 'plan' -Drive 'T' -Mode 'UNELEVATED' -Note 'second'
        Assert-Equal $false $b.Sent 'hub failure reported'
        $env:FAKEHUB_FAIL = $null
        $c = Write-ReclaimWorklog -Command 'status' -Drive '-' -Mode 'UNELEVATED' -Note 'third'
        Assert-Equal $true $c.Sent 'third append sent and flushes the queued line'
    } finally {
        $env:FAKEHUB_FAIL = $null
        $cfg.hubEnabled = $saved[0]; $cfg.hubClient = $saved[1]; $cfg.dataRoot = $saved[2]
    }
    $value = ([IO.File]::ReadAllText($store) | ConvertFrom-Json).'worklog-reclaim'
    $lines = @($value -split "`n")
    Assert-Equal 'existing line from before' $lines[0] 'pre-existing content kept'
    Assert-True ($lines[1] -like '*| scan | T |*first') "line 2: $($lines[1])"
    Assert-True (@($lines | Where-Object { $_ -like '*second' }).Count -eq 1) 'queued line flushed exactly once'
    Assert-True ($lines[-1] -like '*third') "last line: $($lines[-1])"
}

Invoke-Test 'worklog: concurrent runs all land (read-modify-write is serialized by a lock)' {
    $dir = New-TestDir 'fakehub-concurrent'
    $hub = New-FakeHub $dir
    [IO.File]::WriteAllText((Join-Path $dir 'store.json'), '{"worklog-reclaim": "start"}')
    $child = Join-Path $dir 'child.ps1'
    [IO.File]::WriteAllText($child, @'
param([string]$Repo, [string]$Hub, [string]$Data, [string]$Tag)
$ErrorActionPreference = 'Stop'
. (Join-Path $Repo 'src\Load.ps1')
$env:RECLAIM_NO_HUB = $null
$env:RECLAIM_HOME = $Data
$env:FAKEHUB_DELAY = '1'
Reset-ReclaimConfig
$c = Get-ReclaimConfig
$c.hubEnabled = $true
$c.hubClient = $Hub
$r = Write-ReclaimWorklog -Command 'scan' -Drive 'X' -Mode 'TEST' -Note $Tag
if (-not $r.Sent) { exit 1 }
'@)
    $data = Join-Path $dir 'data'
    $procs = foreach ($t in 'p1', 'p2', 'p3') {
        Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $child, $script:ReclaimRepoDir, $hub, $data, $t)
    }
    $procs | Wait-Process -Timeout 90
    $value = ([IO.File]::ReadAllText((Join-Path $dir 'store.json')) | ConvertFrom-Json).'worklog-reclaim'
    $lines = @($value -split "`n")
    Assert-Equal 'start' $lines[0] 'original content kept'
    foreach ($t in 'p1', 'p2', 'p3') { Assert-Equal 1 @($lines | Where-Object { $_ -like "*| $t" }).Count "line from $t landed once" }
}
