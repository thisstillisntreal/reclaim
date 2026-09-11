# Test-Show.ps1 - offline HTML view (treemap or ranked bars, reason stated) and terminal bars.

function Assert-Offline([string]$Html) {
    Assert-True ($Html -notmatch '(?i)(src|href)\s*=\s*["'']?\s*(https?:)?//') 'no external src/href'
    Assert-True ($Html -notmatch '(?i)@import') 'no @import'
    Assert-True ($Html -notmatch '(?i)url\(\s*["'']?\s*(https?:)?//') 'no external url()'
    Assert-True ($Html -notmatch '(?i)<link[^>]+stylesheet') 'no linked stylesheet'
}

Invoke-Test 'show: self-contained HTML, treemap for a balanced folder' {
    $root = New-TestDir 'show'
    foreach ($d in @(@('a', 2097152), @('b', 3145728), @('c', 4194304))) {
        [void](New-Item -ItemType Directory -Force -Path "$root\$($d[0])")
        New-FixtureFile "$root\$($d[0])\x.bin" $d[1]
    }
    $v = New-ReclaimView -Path $root -NoOpen
    Assert-True (Test-Path -LiteralPath $v.File) 'view written'
    Assert-True ($v.File -like '*\views\*.html') 'under views\'
    $html = [IO.File]::ReadAllText($v.File)
    Assert-Offline $html
    Assert-Equal 'treemap' $v.Chart 'treemap chosen'
    Assert-True ($html.Contains('"chart":"treemap"')) 'chart choice embedded'
    Assert-True ($html.Contains('<svg') -or $html.Contains('createElementNS')) 'inline SVG'
}

Invoke-Test 'show: one child holding >= 85% switches to ranked bars and says why' {
    $root = New-TestDir 'show-skew'
    [void](New-Item -ItemType Directory -Force -Path "$root\big", "$root\small")
    New-FixtureFile "$root\big\x.bin" 9437184
    New-FixtureFile "$root\small\y.bin" 524288
    $v = New-ReclaimView -Path $root -NoOpen
    Assert-Equal 'bars' $v.Chart 'bar chart chosen'
    Assert-True ($v.Reason -like '*85%*') "reason names the rule: $($v.Reason)"
    $html = [IO.File]::ReadAllText($v.File)
    Assert-True ($html.Contains($v.Reason)) 'reason shown in the page'
    Assert-Offline $html
}

Invoke-Test 'show: terminal fallback bars are proportional to on-disk bytes' {
    $lines = @(Format-ReclaimBars -Nodes @(
            [pscustomobject]@{ Name = 'a'; OnDisk = 100; Safety = 'SAFE' },
            [pscustomobject]@{ Name = 'b'; OnDisk = 50; Safety = 'KEEP' }) -Width 20)
    Assert-Equal 20 ([regex]::Matches($lines[0], '#').Count) 'largest gets the full width'
    Assert-Equal 10 ([regex]::Matches($lines[1], '#').Count) 'half the bytes, half the bar'
}
