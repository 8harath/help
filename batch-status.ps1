<#
.SYNOPSIS
    Files downloaded batch-status ZIPs into the return folders created by
    intake.ps1 and extracts the jurisdiction XML beside each ZIP.

.DESCRIPTION
    Every source archive must have a numeric filename, for example
    64099419.zip. The archive itself is never rewritten or unpacked wholesale.

    A single file whose extension is .x plus a two-letter US state code is a
    state XML: P0376VY5.XAL is Alabama. A direct .xml file is federal. Files
    with digits in the extension (.x75, .x7l, .x8y), attachment ZIPs, folders,
    and all other entries are ignored and remain inside the original archive.

    For a valid state archive, the script finds exactly one immediate child
    return folder whose name contains that state code, moves the unchanged
    archive there as AL.zip, and writes the selected entry beside it as
    P0376VY5.xml. Federal archives are moved as FED.zip to a folder whose name
    contains FED or Federal (or to -FederalFolder when supplied).

    Nothing is overwritten. Missing/ambiguous classification, missing or
    ambiguous destination folders, corrupt ZIPs, duplicate destinations, and
    existing destination files are flagged and left in the batch folder. A
    timestamped CSV report records every archive.

.PARAMETER Path
    Assignment folder containing the return folders created by intake.ps1.
    Defaults to the current directory.

.PARAMETER BatchPath
    Folder containing the downloaded numeric ZIP files. Required.

.PARAMETER FederalFolder
    Optional exact path (or child-folder name under -Path) for federal files.
    When omitted, a unique folder containing FED or Federal is used.

.EXAMPLE
    .\batch-status.ps1 -Path 'C:\Work\Assignments\2026-08-11' `
        -BatchPath 'C:\Work\Batch Status'

.EXAMPLE
    .\batch-status.ps1 -Path 'C:\Work\Assignments\2026-08-11' `
        -BatchPath 'C:\Work\Batch Status' -WhatIf

.NOTES
    Windows PowerShell 5.1 compatible. No modules or administrator rights.

    Exit codes:
      0  Every archive was processed (or a clean -WhatIf completed).
      1  The command could not start or a filesystem failure needs attention.
      2  One or more archives were flagged/skipped; valid archives may still
         have been processed. Read the CSV report for details.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string] $Path = '.',
    [Parameter(Mandatory = $true)]
    [string] $BatchPath,
    [string] $FederalFolder = ''
)

$ErrorActionPreference = 'Stop'

function Write-Ok   { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-Flag { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host $Message -ForegroundColor Red }
function Write-Note { param([string]$Message) Write-Host $Message -ForegroundColor Cyan }

$States = [ordered]@{
    'AL' = 'Alabama';              'AK' = 'Alaska';         'AZ' = 'Arizona'
    'AR' = 'Arkansas';             'CA' = 'California';     'CO' = 'Colorado'
    'CT' = 'Connecticut';          'DE' = 'Delaware';       'DC' = 'District of Columbia'
    'FL' = 'Florida';              'GA' = 'Georgia';        'HI' = 'Hawaii'
    'ID' = 'Idaho';                'IL' = 'Illinois';       'IN' = 'Indiana'
    'IA' = 'Iowa';                 'KS' = 'Kansas';         'KY' = 'Kentucky'
    'LA' = 'Louisiana';            'ME' = 'Maine';          'MD' = 'Maryland'
    'MA' = 'Massachusetts';        'MI' = 'Michigan';       'MN' = 'Minnesota'
    'MS' = 'Mississippi';          'MO' = 'Missouri';       'MT' = 'Montana'
    'NE' = 'Nebraska';             'NV' = 'Nevada';         'NH' = 'New Hampshire'
    'NJ' = 'New Jersey';           'NM' = 'New Mexico';     'NY' = 'New York'
    'NC' = 'North Carolina';       'ND' = 'North Dakota';   'OH' = 'Ohio'
    'OK' = 'Oklahoma';             'OR' = 'Oregon';         'PA' = 'Pennsylvania'
    'RI' = 'Rhode Island';         'SC' = 'South Carolina'; 'SD' = 'South Dakota'
    'TN' = 'Tennessee';            'TX' = 'Texas';          'UT' = 'Utah'
    'VT' = 'Vermont';              'VA' = 'Virginia';       'WA' = 'Washington'
    'WV' = 'West Virginia';        'WI' = 'Wisconsin';      'WY' = 'Wyoming'
}

function New-IgnoreCaseMap {
    return (New-Object -TypeName System.Collections.Hashtable `
                       -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase))
}

function Get-StateCodeMatches {
    param([string] $Name)

    $found = New-Object System.Collections.ArrayList
    foreach ($token in @($Name -split '[\s\-_]+')) {
        if ([string]::IsNullOrEmpty($token)) { continue }
        foreach ($match in [regex]::Matches($token, '[A-Za-z]+')) {
            if ($match.Value.Length -ne 2) { continue }
            $code = $match.Value.ToUpperInvariant()
            if ($States.Contains($code) -and -not $found.Contains($code)) {
                [void]$found.Add($code)
            }
        }
    }
    return $found.ToArray()
}

function Test-FederalFolderName {
    param([string] $Name)

    foreach ($token in @($Name -split '[^A-Za-z]+')) {
        if ($token -ieq 'FED' -or $token -ieq 'FEDERAL') { return $true }
    }
    return $false
}

function Open-ZipReadOnly {
    param([string] $ZipPath)

    $stream = [System.IO.FileStream]::new(
        $ZipPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Read,
            $false
        )
        return [pscustomobject]@{ Stream = $stream; Archive = $archive }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Get-ArchiveClassification {
    param([string] $ZipPath)

    $opened = $null
    try {
        $opened = Open-ZipReadOnly $ZipPath
        $candidates = New-Object System.Collections.ArrayList
        $unknownJurisdictions = New-Object System.Collections.ArrayList

        foreach ($entry in $opened.Archive.Entries) {
            # A directory has an empty Name. Nested attachment ZIPs are ordinary
            # .zip entries here and are deliberately never opened.
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }

            $extension = [System.IO.Path]::GetExtension($entry.Name)
            if ($extension -ieq '.xml') {
                [void]$candidates.Add([pscustomobject]@{
                    Jurisdiction = 'FED'
                    EntryName    = $entry.Name
                    EntryPath    = $entry.FullName
                    EntryLength  = $entry.Length
                })
                continue
            }

            $extensionMatch = [regex]::Match($extension, '^\.x([A-Za-z]{2})$',
                                              [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $extensionMatch.Success) {
                # Includes .x75, .x7l and .x8y: ignored because a digit is
                # present and the extension is not exactly x + two letters.
                continue
            }

            $code = $extensionMatch.Groups[1].Value.ToUpperInvariant()
            if (-not $States.Contains($code)) {
                [void]$unknownJurisdictions.Add($entry.Name + ' (' + $extension + ')')
                continue
            }

            [void]$candidates.Add([pscustomobject]@{
                Jurisdiction = $code
                EntryName    = $entry.Name
                EntryPath    = $entry.FullName
                EntryLength  = $entry.Length
            })
        }

        if ($unknownJurisdictions.Count -gt 0) {
            return [pscustomobject]@{
                IsValid = $false
                Reason  = 'Unknown alphabetic jurisdiction extension: ' +
                          ($unknownJurisdictions -join ', ')
            }
        }
        if ($candidates.Count -eq 0) {
            return [pscustomobject]@{
                IsValid = $false
                Reason  = 'No direct .xml or recognized .xAA state file found.'
            }
        }
        if ($candidates.Count -gt 1) {
            $descriptions = @($candidates | ForEach-Object {
                $_.EntryName + ' -> ' + $_.Jurisdiction
            })
            return [pscustomobject]@{
                IsValid = $false
                Reason  = 'Multiple jurisdiction files found: ' + ($descriptions -join ', ')
            }
        }

        $candidate = $candidates[0]
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($candidate.EntryName)
        if ($baseName -notmatch '^[A-Za-z0-9]+$') {
            return [pscustomobject]@{
                IsValid = $false
                Reason  = 'Jurisdiction filename is not purely alphanumeric: ' + $candidate.EntryName
            }
        }

        return [pscustomobject]@{
            IsValid     = $true
            Jurisdiction = $candidate.Jurisdiction
            EntryName   = $candidate.EntryName
            EntryPath   = $candidate.EntryPath
            EntryLength = $candidate.EntryLength
            XmlName     = $baseName + '.xml'
            Reason      = ''
        }
    } finally {
        if ($null -ne $opened) {
            $opened.Archive.Dispose()
            $opened.Stream.Dispose()
        }
    }
}

function Copy-ZipEntryToFile {
    param(
        [string] $ZipPath,
        [string] $EntryPath,
        [long] $ExpectedLength,
        [string] $OutputPath
    )

    $opened = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $opened = Open-ZipReadOnly $ZipPath
        $matched = @($opened.Archive.Entries | Where-Object {
            [string]::Equals($_.FullName, $EntryPath, [System.StringComparison]::Ordinal)
        })
        if ($matched.Count -ne 1) {
            throw ('Expected exactly one ZIP entry named "' + $EntryPath +
                   '" but found ' + $matched.Count + '.')
        }

        $inputStream = $matched[0].Open()
        $outputStream = [System.IO.FileStream]::new(
            $OutputPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $inputStream.CopyTo($outputStream)
        $outputStream.Flush()
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream)  { $inputStream.Dispose() }
        if ($null -ne $opened) {
            $opened.Archive.Dispose()
            $opened.Stream.Dispose()
        }
    }

    # Direct FileInfo avoids PowerShell's platform-specific treatment of a
    # dot-prefixed temporary file as hidden during an explicit lookup.
    $actualLength = [System.IO.FileInfo]::new($OutputPath).Length
    if ($actualLength -ne $ExpectedLength) {
        throw ('Extracted XML length mismatch: expected ' + $ExpectedLength +
               ' bytes, wrote ' + $actualLength + ' bytes.')
    }
}

function New-ReportRow {
    param(
        [string] $Archive,
        [string] $Status,
        [string] $Jurisdiction,
        [string] $DestinationFolder,
        [string] $XmlFile,
        [string] $Reason
    )
    return [pscustomobject][ordered]@{
        archive           = $Archive
        status            = $Status
        jurisdiction      = $Jurisdiction
        destination_folder = $DestinationFolder
        xml_file          = $XmlFile
        reason            = $Reason
    }
}

Write-Host ''
Write-Host '=== Batch Status Filing - Stage 3 ===' -ForegroundColor White

try {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
} catch {
    Write-Fail ('ERROR: ZIP support is unavailable in this PowerShell/.NET installation: ' +
                $_.Exception.Message)
    exit 1
}

try {
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
} catch {
    Write-Fail ('ERROR: assignment folder not found: ' + $Path)
    exit 1
}
try {
    $batchRoot = (Resolve-Path -LiteralPath $BatchPath -ErrorAction Stop).ProviderPath
} catch {
    Write-Fail ('ERROR: batch folder not found: ' + $BatchPath)
    exit 1
}
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Fail ('ERROR: assignment path is not a folder: ' + $root)
    exit 1
}
if (-not (Test-Path -LiteralPath $batchRoot -PathType Container)) {
    Write-Fail ('ERROR: batch path is not a folder: ' + $batchRoot)
    exit 1
}

Write-Host ('Assignment: ' + $root)
Write-Host ('Batch folder: ' + $batchRoot)

$returnDirs = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object {
    -not [string]::Equals($_.FullName, $batchRoot, [System.StringComparison]::OrdinalIgnoreCase)
})
if ($returnDirs.Count -eq 0) {
    Write-Fail 'ERROR: no return folders were found directly inside the assignment folder.'
    exit 1
}

$destinations = New-IgnoreCaseMap
$folderDiagnostics = New-Object System.Collections.ArrayList
foreach ($dir in $returnDirs) {
    $stateHits = @(Get-StateCodeMatches $dir.Name)
    $isFederal = Test-FederalFolderName $dir.Name

    if ($stateHits.Count -eq 1 -and -not $isFederal) {
        $code = $stateHits[0]
        if (-not $destinations.ContainsKey($code)) {
            $destinations[$code] = New-Object System.Collections.ArrayList
        }
        [void]$destinations[$code].Add($dir.FullName)
    } elseif ($stateHits.Count -eq 0 -and $isFederal) {
        if (-not $destinations.ContainsKey('FED')) {
            $destinations['FED'] = New-Object System.Collections.ArrayList
        }
        [void]$destinations['FED'].Add($dir.FullName)
    } elseif ($stateHits.Count -gt 1 -or ($stateHits.Count -gt 0 -and $isFederal)) {
        [void]$folderDiagnostics.Add($dir.Name + ' (ambiguous jurisdiction markers)')
    }
}

if (-not [string]::IsNullOrWhiteSpace($FederalFolder)) {
    $federalCandidate = $FederalFolder
    if (-not [System.IO.Path]::IsPathRooted($federalCandidate)) {
        $federalCandidate = Join-Path $root $federalCandidate
    }
    try {
        $federalResolved = (Resolve-Path -LiteralPath $federalCandidate -ErrorAction Stop).ProviderPath
    } catch {
        Write-Fail ('ERROR: -FederalFolder not found: ' + $FederalFolder)
        exit 1
    }
    if (-not (Test-Path -LiteralPath $federalResolved -PathType Container)) {
        Write-Fail ('ERROR: -FederalFolder is not a folder: ' + $federalResolved)
        exit 1
    }
    $explicitFederal = New-Object System.Collections.ArrayList
    [void]$explicitFederal.Add($federalResolved)
    $destinations['FED'] = $explicitFederal
}

Write-Host ''
Write-Host '--- Validation ---' -ForegroundColor White

if ($folderDiagnostics.Count -gt 0) {
    Write-Flag '  Return folders with ambiguous jurisdiction names will not be used:'
    foreach ($diagnostic in $folderDiagnostics) { Write-Flag ('    - ' + $diagnostic) }
}

$zipFiles = @(Get-ChildItem -LiteralPath $batchRoot -Filter '*.zip' -File | Sort-Object Name)
if ($zipFiles.Count -eq 0) {
    Write-Fail 'ERROR: no ZIP files were found at the top level of the batch folder.'
    exit 1
}

$workItems = New-Object System.Collections.ArrayList
$reportRows = New-Object System.Collections.ArrayList

foreach ($zip in $zipFiles) {
    $item = [ordered]@{
        Source       = $zip.FullName
        Archive      = $zip.Name
        Ready        = $false
        Jurisdiction = ''
        Destination  = ''
        DestinationZip = ''
        DestinationXml = ''
        EntryPath    = ''
        EntryLength  = 0L
        XmlName      = ''
        Reason       = ''
    }

    if ($zip.BaseName -notmatch '^\d+$') {
        $item['Reason'] = 'Archive filename is not numeric.'
        [void]$workItems.Add($item)
        continue
    }

    try {
        $classification = Get-ArchiveClassification $zip.FullName
    } catch {
        $item['Reason'] = 'Could not read ZIP: ' + $_.Exception.Message
        [void]$workItems.Add($item)
        continue
    }

    if (-not $classification.IsValid) {
        $item['Reason'] = $classification.Reason
        [void]$workItems.Add($item)
        continue
    }

    $code = $classification.Jurisdiction
    $item['Jurisdiction'] = $code
    $item['XmlName'] = $classification.XmlName
    $item['EntryPath'] = $classification.EntryPath
    $item['EntryLength'] = $classification.EntryLength

    if (-not $destinations.ContainsKey($code) -or $destinations[$code].Count -eq 0) {
        $item['Reason'] = 'No return folder uniquely marked ' + $code + ' was found.'
        [void]$workItems.Add($item)
        continue
    }
    if ($destinations[$code].Count -gt 1) {
        $folderNames = @($destinations[$code] | ForEach-Object { Split-Path -Leaf $_ })
        $item['Reason'] = 'Multiple return folders are marked ' + $code + ': ' +
                          ($folderNames -join ', ')
        [void]$workItems.Add($item)
        continue
    }

    $destination = [string]$destinations[$code][0]
    $destinationZip = Join-Path $destination ($code + '.zip')
    $destinationXml = Join-Path $destination $classification.XmlName

    $collisions = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $destinationZip) {
        [void]$collisions.Add((Split-Path -Leaf $destinationZip))
    }
    if (Test-Path -LiteralPath $destinationXml) {
        [void]$collisions.Add((Split-Path -Leaf $destinationXml))
    }
    if ($collisions.Count -gt 0) {
        $item['Destination'] = $destination
        $item['Reason'] = 'Destination already exists; nothing overwritten: ' +
                          ($collisions -join ', ')
        [void]$workItems.Add($item)
        continue
    }

    $item['Ready'] = $true
    $item['Destination'] = $destination
    $item['DestinationZip'] = $destinationZip
    $item['DestinationXml'] = $destinationXml
    [void]$workItems.Add($item)
}

# Detect conflicts between archives in this same run before moving the first
# one. This prevents processing order from deciding which archive "wins".
$targetOwners = New-IgnoreCaseMap
foreach ($item in @($workItems | Where-Object { $_['Ready'] })) {
    foreach ($target in @($item['DestinationZip'], $item['DestinationXml'])) {
        if (-not $targetOwners.ContainsKey($target)) {
            $targetOwners[$target] = New-Object System.Collections.ArrayList
        }
        [void]$targetOwners[$target].Add($item)
    }
}
foreach ($target in @($targetOwners.Keys)) {
    if ($targetOwners[$target].Count -le 1) { continue }
    $archives = @($targetOwners[$target] | ForEach-Object { $_['Archive'] })
    foreach ($item in $targetOwners[$target]) {
        $item['Ready'] = $false
        $item['Reason'] = 'Same-run destination collision at ' + (Split-Path -Leaf $target) +
                          ' from: ' + ($archives -join ', ')
    }
}

$readyCount = @($workItems | Where-Object { $_['Ready'] }).Count
$flagCount = $workItems.Count - $readyCount
foreach ($item in @($workItems | Where-Object { -not $_['Ready'] })) {
    Write-Flag ('  [flag] ' + $item['Archive'] + ' -> ' + $item['Reason'])
    [void]$reportRows.Add((New-ReportRow $item['Archive'] 'Flagged' `
        $item['Jurisdiction'] $item['Destination'] $item['XmlName'] $item['Reason']))
}
Write-Host ''
Write-Host ('Summary: ' + $workItems.Count + ' archive(s) | ' + $readyCount +
            ' ready | ' + $flagCount + ' flagged')

Write-Host ''
Write-Host '--- Processing ---' -ForegroundColor White

$movedCount = 0
$runtimeFailureCount = 0
$declinedCount = 0

foreach ($item in @($workItems | Where-Object { $_['Ready'] })) {
    $source = $item['Source']
    $description = 'Move unchanged archive to ' + $item['DestinationZip'] +
                   ' and extract ' + $item['XmlName']

    if (-not $PSCmdlet.ShouldProcess($source, $description)) {
        $status = $(if ($WhatIfPreference) { 'WouldMove' } else { 'Skipped' })
        $reason = $(if ($WhatIfPreference) { 'Dry run; nothing changed.' } else { 'Declined by user.' })
        Write-Note ('  [' + $status.ToLowerInvariant() + '] ' + $item['Archive'] +
                    ' -> ' + $item['Jurisdiction'])
        [void]$reportRows.Add((New-ReportRow $item['Archive'] $status `
            $item['Jurisdiction'] $item['Destination'] $item['XmlName'] $reason))
        if (-not $WhatIfPreference) { $declinedCount++ }
        continue
    }

    $tempXml = Join-Path $item['Destination'] (
        '.batch-status-' + [guid]::NewGuid().ToString('N') + '.tmp'
    )
    $zipMoved = $false
    $rollbackProblem = ''
    try {
        # Extract to a unique temporary file first. The visible final names are
        # created only after the entry has been read and length-checked.
        Copy-ZipEntryToFile $source $item['EntryPath'] $item['EntryLength'] $tempXml

        # Re-check immediately before mutation in case another process created
        # a target after validation.
        if (Test-Path -LiteralPath $item['DestinationZip']) {
            throw ('Destination appeared during processing: ' + $item['DestinationZip'])
        }
        if (Test-Path -LiteralPath $item['DestinationXml']) {
            throw ('Destination appeared during processing: ' + $item['DestinationXml'])
        }

        Move-Item -LiteralPath $source -Destination $item['DestinationZip'] -Confirm:$false
        $zipMoved = $true
        Move-Item -LiteralPath $tempXml -Destination $item['DestinationXml'] -Confirm:$false

        Write-Ok ('  [ok]   ' + $item['Archive'] + ' -> ' + $item['Jurisdiction'] +
                  '.zip + ' + $item['XmlName'])
        [void]$reportRows.Add((New-ReportRow $item['Archive'] 'Moved' `
            $item['Jurisdiction'] $item['Destination'] $item['XmlName'] ''))
        $movedCount++
    } catch {
        $failure = $_.Exception.Message

        # If the ZIP moved but the XML finalization failed, put the ZIP back so
        # the archive is not silently stranded in a half-complete destination.
        if ($zipMoved -and -not (Test-Path -LiteralPath $source) -and
            (Test-Path -LiteralPath $item['DestinationZip'] -PathType Leaf)) {
            try {
                Move-Item -LiteralPath $item['DestinationZip'] -Destination $source -Confirm:$false
                $zipMoved = $false
            } catch {
                $rollbackProblem = ' Rollback also failed; inspect ' +
                                   $item['DestinationZip'] + ' manually: ' + $_.Exception.Message
            }
        }

        if (Test-Path -LiteralPath $tempXml -PathType Leaf) {
            try { Remove-Item -LiteralPath $tempXml -Force -Confirm:$false } catch {
                $rollbackProblem += ' Temporary file could not be removed: ' + $tempXml
            }
        }

        $reason = 'Processing failed: ' + $failure + $rollbackProblem
        Write-Fail ('  [fail] ' + $item['Archive'] + ' -> ' + $reason)
        [void]$reportRows.Add((New-ReportRow $item['Archive'] 'Failed' `
            $item['Jurisdiction'] $item['Destination'] $item['XmlName'] $reason))
        $runtimeFailureCount++
    }
}

$reportPath = Join-Path $batchRoot (
    'batch-status-report-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.csv'
)
if ($WhatIfPreference) {
    Write-Note ('  [dry]  CSV report not written. It would be written under ' + $batchRoot)
} else {
    try {
        @($reportRows) | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
        Write-Note ('  Report: ' + $reportPath)
    } catch {
        Write-Fail ('ERROR: processing finished, but the CSV report could not be written: ' +
                    $_.Exception.Message)
        exit 1
    }
}

Write-Host ''
if ($WhatIfPreference) {
    Write-Note ('Dry run complete: ' + $readyCount + ' archive(s) would move; ' +
                $flagCount + ' flagged; nothing changed.')
    if ($flagCount -gt 0) { exit 2 }
    exit 0
}

$totalProblems = $flagCount + $runtimeFailureCount + $declinedCount
if ($totalProblems -gt 0) {
    Write-Flag ('Finished with attention required: ' + $movedCount + ' moved, ' +
                $totalProblems + ' flagged/failed/skipped. See the CSV report.')
    exit 2
}

Write-Ok ('Finished: all ' + $movedCount + ' archive(s) filed successfully.')
exit 0
