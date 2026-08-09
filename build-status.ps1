<#
  build-status.ps1 - probe the public site and regenerate the status page.

  Runs on a schedule from .github/workflows/status.yml, and works in both
  Windows PowerShell 5.1 and PowerShell Core, so it can be tested locally.

  The page is generated as plain static HTML with the results baked in. It
  deliberately does NOT fetch JSON at runtime:

    * the site's Content-Security-Policy is `default-src 'none'`, which blocks
      fetch() outright, so a client-side status page would silently show
      nothing if it were ever served from brooklinefire.org;
    * a status page that needs JavaScript to tell you something is broken is
      the wrong tool. This one renders with scripting disabled.

  ASCII only. PowerShell 5.1 reads .ps1 as ANSI unless it carries a BOM, so a
  non-ASCII character here is written into the generated page mangled.

  Usage:
      powershell -ExecutionPolicy Bypass -File status/build-status.ps1
      ... -SkipProbe     rebuild the HTML from existing history
#>

[CmdletBinding()]
param(
    [switch]$SkipProbe,
    [string]$Now
)

$ErrorActionPreference = 'Stop'

$here        = $PSScriptRoot
$historyPath = Join-Path $here 'history.json'
$outPath     = Join-Path $here 'index.html'
$maxEntries  = 1500   # about 31 days at one probe every 30 minutes

# In Windows PowerShell `curl` is an alias for Invoke-WebRequest, which throws
# on 4xx. The real binary is needed so a 404 can be asserted as a pass.
$curlCmd = if (Get-Command curl.exe -ErrorAction SilentlyContinue) { 'curl.exe' } else { 'curl' }

$checks = @(
    [pscustomobject]@{ id = 'site';     name = 'Public website';  url = 'https://brooklinefire.org/';               expect = 200 }
    [pscustomobject]@{ id = 'www';      name = 'www redirect';    url = 'https://www.brooklinefire.org/';           expect = 200 }
    [pscustomobject]@{ id = 'assets';   name = 'Stylesheet';      url = 'https://brooklinefire.org/styles.css';     expect = 200 }
    [pscustomobject]@{ id = 'notfound'; name = 'Error handling';  url = 'https://brooklinefire.org/does-not-exist'; expect = 404 }
)

function ConvertTo-HtmlText {
    param([string]$Text)
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

# ------------------------------------------------------------------ history --

if (Test-Path $historyPath) {
    $data = Get-Content $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($data.entries)
} else {
    $entries = @()
}

# -------------------------------------------------------------------- probe --

if (-not $SkipProbe) {
    if ($Now) { $stamp = $Now } else { $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

    $result = [ordered]@{}
    foreach ($c in $checks) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $code = 0
        try {
            $raw = & $curlCmd -s -o /dev/null -w '%{http_code}' --max-time 20 $c.url 2>$null
            if ($raw) { $code = [int]("$raw".Trim()) }
        } catch {
            $code = 0
        }
        $sw.Stop()

        $result[$c.id] = [pscustomobject]@{
            ok   = ($code -eq $c.expect)
            code = $code
            ms   = [int]$sw.Elapsed.TotalMilliseconds
        }
    }

    $entries = @($entries) + @([pscustomobject]@{ t = $stamp; r = [pscustomobject]$result })
    if ($entries.Count -gt $maxEntries) {
        $entries = $entries[($entries.Count - $maxEntries)..($entries.Count - 1)]
    }

    $out = [pscustomobject]@{ updated = $stamp; entries = $entries }
    $json = $out | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($historyPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

if ($entries.Count -eq 0) {
    Write-Warning 'No history recorded yet; nothing to render.'
    return
}

# ---------------------------------------------------------------- aggregate --

$latest = $entries[$entries.Count - 1]

$allOk = $true
$anyOk = $false
foreach ($c in $checks) {
    $v = $latest.r.($c.id)
    if ($null -ne $v -and $v.ok) { $anyOk = $true } else { $allOk = $false }
}

if ($allOk) {
    $overall = 'operational'; $overallText = 'All systems operational'
} elseif ($anyOk) {
    $overall = 'degraded';    $overallText = 'Partial outage'
} else {
    $overall = 'down';        $overallText = 'Site unreachable'
}

$totalChecks = 0
$okChecks    = 0
foreach ($e in $entries) {
    foreach ($c in $checks) {
        $v = $e.r.($c.id)
        if ($null -ne $v) {
            $totalChecks++
            if ($v.ok) { $okChecks++ }
        }
    }
}
$uptime = 0
if ($totalChecks -gt 0) { $uptime = [math]::Round(100 * $okChecks / $totalChecks, 2) }

# Median rather than mean: one slow probe should not skew the headline figure.
$times = @($entries | ForEach-Object { $_.r.site.ms } | Where-Object { $_ -gt 0 } | Sort-Object)
$median = 0
if ($times.Count -gt 0) { $median = $times[[int]([math]::Floor($times.Count / 2))] }

$byDay = @{}
foreach ($e in $entries) {
    $day = ($e.t -split 'T')[0]
    if (-not $byDay.ContainsKey($day)) { $byDay[$day] = @{ ok = 0; bad = 0 } }
    foreach ($c in $checks) {
        $v = $e.r.($c.id)
        if ($null -ne $v) {
            if ($v.ok) { $byDay[$day].ok++ } else { $byDay[$day].bad++ }
        }
    }
}
$days = @($byDay.Keys | Sort-Object | Select-Object -Last 45)

# ------------------------------------------------------------------- render --

$rowParts = New-Object System.Collections.Generic.List[string]
foreach ($c in $checks) {
    $v = $latest.r.($c.id)
    if ($null -eq $v) { $v = [pscustomobject]@{ ok = $false; code = 0; ms = 0 } }

    if ($v.ok) {
        $cls = 'ok'; $label = 'Operational'
    } elseif ($v.code -eq 0) {
        $cls = 'bad'; $label = 'No response'
    } else {
        $cls = 'bad'; $label = "Unexpected $($v.code)"
    }

    $nameEsc = ConvertTo-HtmlText $c.name
    $rowParts.Add("        <li class=""check""><span class=""dot $cls"" aria-hidden=""true""></span><span class=""check-name"">$nameEsc</span><span class=""check-state $cls"">$label</span></li>")
}
$rowsHtml = $rowParts -join "`n"

$barParts = New-Object System.Collections.Generic.List[string]
foreach ($d in $days) {
    $v = $byDay[$d]
    $total = $v.ok + $v.bad
    $pct = 0
    if ($total -gt 0) { $pct = [math]::Round(100 * $v.ok / $total) }

    if ($v.bad -eq 0) { $cls = 'ok' } elseif ($v.ok -eq 0) { $cls = 'bad' } else { $cls = 'partial' }

    $title = "$d - ${pct}% of checks passed"
    $barParts.Add("        <span class=""bar $cls"" title=""$title""></span>")
}
$barsHtml = $barParts -join "`n"

$prettyTime = ([datetime]::Parse($latest.t)).ToUniversalTime().ToString('d MMMM yyyy, HH:mm') + ' UTC'
$probeCount = $entries.Count
$mdash = '&mdash;'

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="description" content="Live availability status for the Brookline Fire Protection District website." />
  <meta name="robots" content="noindex" />
  <title>System Status $mdash Brookline Fire Protection District</title>
  <link rel="icon" href="https://brooklinefire.org/images/logo.jpg" type="image/jpeg" />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Montserrat:wght@400..900&display=swap" rel="stylesheet" />
  <link rel="stylesheet" href="status.css" />
</head>
<body>
  <main class="wrap">

    <header class="head">
      <p class="eyebrow">Brookline Fire Protection District</p>
      <h1>System Status</h1>
    </header>

    <section class="banner $overall">
      <h2>$overallText</h2>
      <p>Last checked $prettyTime</p>
    </section>

    <section class="card">
      <h2>Current checks</h2>
      <ul class="checks">
$rowsHtml
      </ul>
    </section>

    <section class="card">
      <h2>Availability</h2>
      <div class="metrics">
        <div class="metric"><b>$uptime%</b><span>Checks passed</span></div>
        <div class="metric"><b>$median ms</b><span>Median response</span></div>
        <div class="metric"><b>$probeCount</b><span>Probes recorded</span></div>
      </div>
      <div class="bars" role="img" aria-label="Daily check results, oldest on the left. Overall $uptime percent of checks passed.">
$barsHtml
      </div>
      <p class="foot-note">Each column is one day. Green means every check passed that day.</p>
    </section>

    <section class="card note">
      <h2>In an emergency, call 911</h2>
      <p>This page reports only whether the district's website is reachable. It is not monitored, and it is never a way to report an emergency or to reach on-duty crews.</p>
      <p>Non-emergency: <a href="tel:4177717570">417-771-7570</a></p>
    </section>

    <footer class="foot">
      <p><a href="https://brooklinefire.org/">Back to brooklinefire.org</a></p>
      <p>Checks run automatically every 30 minutes.</p>
    </footer>

  </main>
</body>
</html>
"@

[System.IO.File]::WriteAllText($outPath, $html, (New-Object System.Text.UTF8Encoding $false))

Write-Host "status=$overall uptime=$uptime% median=${median}ms probes=$probeCount"
