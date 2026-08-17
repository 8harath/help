<#
End-to-end fixture for batch-status.ps1. Run on Windows PowerShell 5.1+.
No Pester module is required.
#>

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-TestZip {
    param([string]$Path, [System.Collections.IDictionary]$Entries)

    $stream = [System.IO.FileStream]::new(
        $Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write
    )
    $archive = [System.IO.Compression.ZipArchive]::new(
        $stream, [System.IO.Compression.ZipArchiveMode]::Create, $false
    )
    try {
        foreach ($name in $Entries.Keys) {
            $entry = $archive.CreateEntry($name)
            $writer = [System.IO.StreamWriter]::new($entry.Open())
            try { $writer.Write([string]$Entries[$name]) } finally { $writer.Dispose() }
        }
    } finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'batch-status.ps1'
$powerShellHost = (Get-Process -Id $PID).Path
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'batch-status-test-' + [guid]::NewGuid().ToString('N')
)
$assignment = Join-Path $testRoot 'Assignment'
$batch = Join-Path $testRoot 'Downloads'

try {
    New-Item -ItemType Directory -Path $assignment | Out-Null
    New-Item -ItemType Directory -Path $batch | Out-Null
    $alFolder = New-Item -ItemType Directory -Path (Join-Path $assignment 'RETURN_2026_AL_01')
    $caFolder = New-Item -ItemType Directory -Path (Join-Path $assignment 'RETURN_2026_CA_01')
    $fedFolder = New-Item -ItemType Directory -Path (Join-Path $assignment 'RETURN_2026_FED_01')
    $nyFolder = New-Item -ItemType Directory -Path (Join-Path $assignment 'RETURN_2026_NY_01')
    $waFolder = New-Item -ItemType Directory -Path (Join-Path $assignment 'RETURN_2026_WA_01')

    New-TestZip (Join-Path $batch '64099419.zip') ([ordered]@{
        'P0376VY5.XAL' = '<alabama />'
        'P0376VY5.X75' = 'ignored'
        'P0376VY5ALEPattachments.zip' = 'left untouched as an entry'
    })
    New-TestZip (Join-Path $batch '64104145.zip') ([ordered]@{
        'P0001FED.xml' = '<federal />'
        'P0001FED.X8Y' = 'ignored'
    })
    New-TestZip (Join-Path $batch '64104146.zip') ([ordered]@{
        'P0002CA.XCA' = '<california />'
        'P0002CA.X7L' = 'ignored'
    })

    $alHashBefore = (Get-FileHash -LiteralPath (Join-Path $batch '64099419.zip') -Algorithm SHA256).Hash

    & $powerShellHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        -Path $assignment -BatchPath $batch
    if ($LASTEXITCODE -ne 0) { throw ('Script exited ' + $LASTEXITCODE) }

    $expected = @(
        (Join-Path $alFolder.FullName 'AL.zip'),
        (Join-Path $alFolder.FullName 'P0376VY5.xml'),
        (Join-Path $caFolder.FullName 'CA.zip'),
        (Join-Path $caFolder.FullName 'P0002CA.xml'),
        (Join-Path $fedFolder.FullName 'FED.zip'),
        (Join-Path $fedFolder.FullName 'P0001FED.xml')
    )
    foreach ($file in $expected) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw ('Expected output missing: ' + $file)
        }
    }
    foreach ($sourceName in @('64099419.zip', '64104145.zip', '64104146.zip')) {
        if (Test-Path -LiteralPath (Join-Path $batch $sourceName)) {
            throw ('Processed source was not moved: ' + $sourceName)
        }
    }

    $alHashAfter = (Get-FileHash -LiteralPath (Join-Path $alFolder.FullName 'AL.zip') -Algorithm SHA256).Hash
    if ($alHashBefore -ne $alHashAfter) { throw 'AL.zip bytes changed while it was filed.' }

    $alZip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $alFolder.FullName 'AL.zip'))
    try {
        $entryNames = @($alZip.Entries | ForEach-Object { $_.FullName })
        foreach ($name in @('P0376VY5.XAL', 'P0376VY5.X75', 'P0376VY5ALEPattachments.zip')) {
            if ($entryNames -notcontains $name) {
                throw ('Moved AL.zip lost original entry: ' + $name)
            }
        }
    } finally { $alZip.Dispose() }

    $alXml = Get-Content -LiteralPath (Join-Path $alFolder.FullName 'P0376VY5.xml') -Raw
    if ($alXml -ne '<alabama />') { throw 'Alabama XML content was not extracted correctly.' }

    # Re-running against a fresh archive for AL must flag both existing outputs
    # and leave the numeric source untouched.
    New-TestZip (Join-Path $batch '70000000.zip') ([ordered]@{
        'P0376VY5.XAL' = '<replacement must not overwrite />'
    })
    & $powerShellHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        -Path $assignment -BatchPath $batch
    if ($LASTEXITCODE -ne 2) { throw ('Collision run should exit 2, got ' + $LASTEXITCODE) }
    if (-not (Test-Path -LiteralPath (Join-Path $batch '70000000.zip') -PathType Leaf)) {
        throw 'Flagged collision source should remain in the batch folder.'
    }
    $alXmlAfter = Get-Content -LiteralPath (Join-Path $alFolder.FullName 'P0376VY5.xml') -Raw
    if ($alXmlAfter -ne '<alabama />') { throw 'Existing XML was overwritten.' }

    # Exercise the manual-attention paths together. None of these sources may
    # move, and the two NY archives must both lose rather than processing order
    # deciding which one gets NY.zip.
    New-TestZip (Join-Path $batch '70000001.zip') ([ordered]@{
        'ONLYDIGITS.X7L' = 'ignored, therefore no classification'
    })
    New-TestZip (Join-Path $batch '70000002.zip') ([ordered]@{
        'ONE.XAL' = '<al />'
        'TWO.XCA' = '<ca />'
    })
    New-TestZip (Join-Path $batch '70000003.zip') ([ordered]@{
        'UNKNOWN.XZZ' = '<unknown />'
    })
    New-TestZip (Join-Path $batch '70000004.zip') ([ordered]@{
        'COLORADO.XCO' = '<co />'
    })
    New-TestZip (Join-Path $batch '70000005.zip') ([ordered]@{
        'NEWYORKA.XNY' = '<ny-a />'
    })
    New-TestZip (Join-Path $batch '70000006.zip') ([ordered]@{
        'NEWYORKB.XNY' = '<ny-b />'
    })
    New-TestZip (Join-Path $batch 'notnumeric.zip') ([ordered]@{
        'WASHINGTON.XWA' = '<wa />'
    })
    [System.IO.File]::WriteAllText((Join-Path $batch '70000007.zip'), 'not a zip')

    & $powerShellHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        -Path $assignment -BatchPath $batch
    if ($LASTEXITCODE -ne 2) { throw ('Flag matrix run should exit 2, got ' + $LASTEXITCODE) }

    $flaggedSources = @(
        '70000000.zip', '70000001.zip', '70000002.zip', '70000003.zip',
        '70000004.zip', '70000005.zip', '70000006.zip', '70000007.zip',
        'notnumeric.zip'
    )
    foreach ($sourceName in $flaggedSources) {
        if (-not (Test-Path -LiteralPath (Join-Path $batch $sourceName) -PathType Leaf)) {
            throw ('Flagged source was moved: ' + $sourceName)
        }
    }
    if (Test-Path -LiteralPath (Join-Path $nyFolder.FullName 'NY.zip')) {
        throw 'One same-run NY collision was allowed to win.'
    }

    $latestReport = Get-ChildItem -LiteralPath $batch -Filter 'batch-status-report-*.csv' |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $reportRows = @(Import-Csv -LiteralPath $latestReport.FullName)
    if ($reportRows.Count -ne $flaggedSources.Count) {
        throw ('Expected ' + $flaggedSources.Count + ' flagged report rows, got ' + $reportRows.Count)
    }
    if (@($reportRows | Where-Object { $_.status -ne 'Flagged' }).Count -ne 0) {
        throw 'The manual-attention report contains a non-Flagged status.'
    }

    # A dry run validates a ready archive but writes no ZIP, XML, or report.
    $dryBatch = New-Item -ItemType Directory -Path (Join-Path $testRoot 'DryRun')
    New-TestZip (Join-Path $dryBatch.FullName '80000000.zip') ([ordered]@{
        'WASHINGTON.XWA' = '<wa />'
    })
    & $powerShellHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        -Path $assignment -BatchPath $dryBatch.FullName -WhatIf
    if ($LASTEXITCODE -ne 0) { throw ('Clean dry run should exit 0, got ' + $LASTEXITCODE) }
    if (-not (Test-Path -LiteralPath (Join-Path $dryBatch.FullName '80000000.zip'))) {
        throw 'Dry run moved its source ZIP.'
    }
    if (Test-Path -LiteralPath (Join-Path $waFolder.FullName 'WA.zip')) {
        throw 'Dry run created WA.zip.'
    }
    if (@(Get-ChildItem -LiteralPath $dryBatch.FullName -Filter '*.csv').Count -ne 0) {
        throw 'Dry run wrote a report.'
    }

    Write-Host 'PASS: filing, archive preservation, error recognition, collision safety, and dry-run safety.' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
