# Load.ps1 - dot-sources every module in dependency order.
. (Join-Path $PSScriptRoot 'Common.ps1')
foreach ($m in @('Kb', 'Worklog', 'Scan', 'Hotspots', 'Explain', 'Advisor', 'Plan', 'Quarantine', 'Status', 'Show')) {
    $f = Join-Path $PSScriptRoot "$m.ps1"
    if (Test-Path -LiteralPath $f) { . $f }
}
