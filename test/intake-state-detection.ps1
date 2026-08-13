<#
Runs the real intake script over the production filename shape that includes a
form prefix, dotted date, state segment, and E-File suffix. No Pester module is
needed, so this works with Windows PowerShell 5.1 as well as PowerShell 7.
#>

#Requires -Version 3.0

$ErrorActionPreference = 'Stop'

$expected = [ordered]@{
    'CI6AIF_12.31.25_MA_Return_E-File.pdf'     = 'MA'
    'CI6AIF_12.31.25_MN_Return_E-file.pdf'     = 'MN'
    'CI6AIF_12.31.25_MT_Return_E-File.pdf'     = 'MT'
    'CI6AIF_12.31.25_NJ_Return_E-File.pdf'     = 'NJ'
    'CI6AIF_12.31.25_NJ-CBT_Return_E-file.pdf' = 'NJ'
    'CI6AIF_12.31.25_NY_Return_E-File.pdf'     = 'NY'
    'CI6AIF_12.31.25_OR_Return_E-File.pdf'     = 'OR'
    'CI6AIF_12.31.25_PA_Return_E-File.pdf'     = 'PA'
    'CI6AIF_12.31.25_SC_Return_E-File.pdf'     = 'SC'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$intakeScript = Join-Path $repoRoot 'intake.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('returns-intake-state-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    foreach ($filename in $expected.Keys) {
        New-Item -ItemType File -Path (Join-Path $testRoot $filename) | Out-Null
    }

    & $intakeScript -Path $testRoot -Force

    $manifestPath = Join-Path $testRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'intake.ps1 did not write manifest.json.'
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($manifest.returns).Count -ne $expected.Count) {
        throw ('Expected ' + $expected.Count + ' returns, got ' + @($manifest.returns).Count + '.')
    }
    if (@($manifest.flagged).Count -ne 0) {
        throw ('Expected no flagged returns, got ' + @($manifest.flagged).Count + '.')
    }

    foreach ($filename in $expected.Keys) {
        $matched = @($manifest.returns | Where-Object { $_.filename -eq $filename })
        if ($matched.Count -ne 1) {
            throw ('Expected exactly one manifest return for "' + $filename + '".')
        }
        if ($matched[0].state_code -ne $expected[$filename]) {
            throw ('Expected "' + $filename + '" to resolve to ' + $expected[$filename] +
                   ', got ' + [string]$matched[0].state_code + '.')
        }

        $filedPdf = Join-Path (Join-Path $testRoot ([System.IO.Path]::GetFileNameWithoutExtension($filename))) $filename
        if (-not (Test-Path -LiteralPath $filedPdf -PathType Leaf)) {
            throw ('Expected the filed PDF at "' + $filedPdf + '".')
        }
    }

    Write-Host ('PASS: all ' + $expected.Count + ' CI6AIF filenames were filed with the expected states.') -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
