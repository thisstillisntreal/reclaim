# run-tests.ps1 - runs every tests\Test-*.ps1 against fixtures under .testrun\<stamp>.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 [-Filter Engine]
param([string]$Filter = '*')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'src\Load.ps1')
. (Join-Path $PSScriptRoot 'Assert.ps1')

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$script:TestRunRoot = Join-Path $repo ".testrun\$stamp"
[void](New-Item -ItemType Directory -Force -Path $script:TestRunRoot)

# Cross-volume target for move tests (Q: fixtures -> Y: quarantine), falls back to same volume.
$xvolBase = if ($env:RECLAIM_TEST_XVOL) { $env:RECLAIM_TEST_XVOL } else { 'Y:\_reclaim-tests' }
if (-not (Test-Path -LiteralPath (Split-Path -Qualifier $xvolBase))) { $xvolBase = Join-Path $script:TestRunRoot 'xvol' }
$script:TestXVolRoot = Join-Path $xvolBase $stamp

# Tests never talk to the hub and never touch the real data root.
$env:RECLAIM_NO_HUB = '1'
$env:RECLAIM_HOME   = Join-Path $script:TestXVolRoot 'data'
Reset-ReclaimConfig
Import-ReclaimEngine

Write-Host "Reclaim tests - fixtures: $script:TestRunRoot  cross-volume: $script:TestXVolRoot" -ForegroundColor Cyan
Get-ChildItem -Path $PSScriptRoot -Filter "Test-$Filter.ps1" | Sort-Object Name | ForEach-Object {
    Write-Host "`n== $($_.Name)" -ForegroundColor Cyan
    . $_.FullName
}

$failed = @($script:TestResults | Where-Object { -not $_.Ok })
Write-Host ("`n{0} passed, {1} failed" -f ($script:TestResults.Count - $failed.Count), $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
exit $failed.Count
