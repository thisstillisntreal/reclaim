# Assert.ps1 - minimal test harness (no Pester dependency; PS 5.1 ships Pester 3 only).

$script:TestResults = New-Object System.Collections.ArrayList

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "ASSERT FAILED: $Message`n        expected: $Expected`n        actual:   $Actual"
    }
}

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Invoke-Test([string]$Name, [scriptblock]$Body) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
        [void]$script:TestResults.Add([pscustomobject]@{ Name = $Name; Ok = $true; Error = $null })
        Write-Host ("PASS  {0}  ({1} ms)" -f $Name, $sw.ElapsedMilliseconds) -ForegroundColor Green
    } catch {
        [void]$script:TestResults.Add([pscustomobject]@{ Name = $Name; Ok = $false; Error = $_.Exception.Message })
        Write-Host ("FAIL  {0}`n      {1}`n      at {2}" -f $Name, $_.Exception.Message, $_.InvocationInfo.PositionMessage) -ForegroundColor Red
    }
}

# Fresh directory under this run's fixture root (fixtures are never auto-deleted).
function New-TestDir([string]$Name, [string]$Base = $script:TestRunRoot) {
    $p = Join-Path $Base $Name
    [void](New-Item -ItemType Directory -Force -Path $p)
    return $p
}

# Deterministic content so hashes are reproducible.
function New-FixtureFile([string]$Path, [long]$Size, [int]$Seed = 7) {
    $bytes = New-Object byte[] $Size
    if ($Size -gt 0) { (New-Object Random $Seed).NextBytes($bytes) }
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-Alloc([long]$Size, [long]$Cluster) {
    if ($Size -eq 0) { return [long]0 }
    return [long]([math]::Ceiling($Size / $Cluster)) * $Cluster
}
