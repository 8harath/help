<#
.SYNOPSIS
    Returns Intake - Stage 1. Validates a folder of return PDFs, files each one
    into its own folder, and writes a manifest.json for the browser CRM.

.DESCRIPTION
    Run this from inside a freshly created assignment folder that contains the
    day's PDFs. It will:
      1. Validate the folder (only PDFs at top level, recognizable state codes).
      2. Print a validation summary and ask for confirmation if anything is flagged.
      3. Create one folder per PDF (filename minus .pdf) and move the PDF into it.
      4. Write manifest.json describing every return.

    Safe to re-run: existing folders are not overwritten, and if a manifest.json
    is already present its status flags / remarks / CRM-assigned states are
    carried forward (the old file is backed up first).

.PARAMETER Path
    Assignment folder to process. Defaults to the current working directory.

.PARAMETER Force
    Skip the Y/N confirmation prompt when files are flagged.

.EXAMPLE
    cd C:\Work\2026-08-11
    .\intake.ps1

.EXAMPLE
    .\intake.ps1 -Path 'C:\Work\2026-08-11' -Force

.NOTES
    PowerShell 3.0+ / Windows PowerShell 5.1 compatible. No external modules,
    no admin rights required.
#>

#Requires -Version 3.0

[CmdletBinding()]
param(
    [string] $Path = '.',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------

function Write-Ok    { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-Flag  { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Fail  { param([string]$Message) Write-Host $Message -ForegroundColor Red }
function Write-Note  { param([string]$Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Plain { param([string]$Message) Write-Host $Message }

function Write-Header {
    param([string]$Title)
    Write-Host ''
    Write-Host ('--- ' + $Title + ' ---') -ForegroundColor White
}

# ---------------------------------------------------------------------------
# State lookup: 50 states + District of Columbia
# ---------------------------------------------------------------------------

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

# The 8 qualifying steps tracked by the CRM, in display order.
$FlagKeys = @(
    'attachments_present',
    'data_accurate',
    'qualifying',
    'xml_flowing',
    'xml_downloaded',
    'batch_downloaded',
    'recon_checked',
    'tfr_checked'
)

# Top-level extensions that are tolerated (JSON = manifest/backups, PS1 = this script).
$AllowedExtensions = @('.pdf', '.json', '.ps1')

# ---------------------------------------------------------------------------
# Minimal JSON writer
#
# Hand-rolled instead of ConvertTo-Json so that single-element and empty arrays
# always serialize as arrays, key order is stable, and the file is written as
# UTF-8 *without* a BOM (a BOM makes JSON.parse() fail in the browser).
# ---------------------------------------------------------------------------

function ConvertTo-JsonString {
    param([string] $Value)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        switch ([string]$ch) {
            '"'     { [void]$sb.Append('\"');   break }
            '\'     { [void]$sb.Append('\\');   break }
            "`b"    { [void]$sb.Append('\b');   break }
            "`f"    { [void]$sb.Append('\f');   break }
            "`n"    { [void]$sb.Append('\n');   break }
            "`r"    { [void]$sb.Append('\r');   break }
            "`t"    { [void]$sb.Append('\t');   break }
            default {
                if ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
                else              { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-JsonManual {
    param(
        $Value,
        [int] $Indent = 0
    )

    $pad     = ' ' * ($Indent * 2)
    $padItem = ' ' * (($Indent + 1) * 2)

    if ($null -eq $Value) { return 'null' }

    if ($Value -is [bool])   { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return (ConvertTo-JsonString $Value) }
    if ($Value -is [char])   { return (ConvertTo-JsonString ([string]$Value)) }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or
        $Value -is [decimal] -or $Value -is [single]) {
        return [string][System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [datetime]) {
        return (ConvertTo-JsonString ($Value.ToString('yyyy-MM-ddTHH:mm:sszzz')))
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys)
        if ($keys.Count -eq 0) { return '{}' }
        $parts = New-Object System.Collections.ArrayList
        foreach ($key in $keys) {
            $rendered = ConvertTo-JsonManual $Value[$key] ($Indent + 1)
            [void]$parts.Add($padItem + (ConvertTo-JsonString ([string]$key)) + ': ' + $rendered)
        }
        return "{`r`n" + ($parts -join ",`r`n") + "`r`n" + $pad + '}'
    }

    if ($Value -is [System.Management.Automation.PSCustomObject] -or
        $Value -is [System.Management.Automation.PSObject]) {
        $props = @($Value.PSObject.Properties)
        if ($props.Count -eq 0) { return '{}' }
        $parts = New-Object System.Collections.ArrayList
        foreach ($prop in $props) {
            $rendered = ConvertTo-JsonManual $prop.Value ($Indent + 1)
            [void]$parts.Add($padItem + (ConvertTo-JsonString ([string]$prop.Name)) + ': ' + $rendered)
        }
        return "{`r`n" + ($parts -join ",`r`n") + "`r`n" + $pad + '}'
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = New-Object System.Collections.ArrayList
        foreach ($item in $items) {
            [void]$parts.Add($padItem + (ConvertTo-JsonManual $item ($Indent + 1)))
        }
        return "[`r`n" + ($parts -join ",`r`n") + "`r`n" + $pad + ']'
    }

    return (ConvertTo-JsonString ([string]$Value))
}

# ---------------------------------------------------------------------------
# State detection
#
# Split the name on spaces / hyphens / underscores, then look at each maximal
# run of letters inside those tokens. A run counts as a state code only if the
# whole run is exactly two letters, so "MD510" -> MD but "MASTER" -> nothing.
# ---------------------------------------------------------------------------

function Get-StateCodeMatches {
    param([string] $Name)

    $found = New-Object System.Collections.ArrayList
    $tokens = $Name -split '[\s\-_]+'

    foreach ($token in $tokens) {
        if ([string]::IsNullOrEmpty($token)) { continue }
        foreach ($match in [regex]::Matches($token, '[A-Za-z]+')) {
            if ($match.Value.Length -ne 2) { continue }
            $code = $match.Value.ToUpperInvariant()
            if ($States.Contains($code) -and -not $found.Contains($code)) {
                [void]$found.Add($code)
            }
        }
    }

    return ,($found.ToArray())
}

# ---------------------------------------------------------------------------
# Existing-manifest helpers (re-run support)
# ---------------------------------------------------------------------------

function Get-PropertyValue {
    param($Object, [string] $Name)

    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Read-ExistingManifest {
    param([string] $ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $null }

    try {
        $raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        Write-Flag ('  [warn] Existing manifest.json could not be parsed (' + $_.Exception.Message + ').')
        Write-Flag '         It will be backed up and rebuilt from scratch; status flags in it are NOT carried over.'
        return $null
    }
}

function New-StatusFlagSet {
    $flags = [ordered]@{}
    foreach ($key in $FlagKeys) { $flags[$key] = $null }
    return $flags
}

function Merge-ExistingReturn {
    param(
        [System.Collections.Specialized.OrderedDictionary] $Return,
        $Existing
    )

    if ($null -eq $Existing) { return $Return }

    # Carry over any keys we do not manage (forward compatibility).
    foreach ($prop in $Existing.PSObject.Properties) {
        if (-not $Return.Contains($prop.Name)) { $Return[$prop.Name] = $prop.Value }
    }

    $oldDate = Get-PropertyValue $Existing 'date_received'
    if (-not [string]::IsNullOrWhiteSpace([string]$oldDate)) { $Return['date_received'] = [string]$oldDate }

    $oldRemarks = Get-PropertyValue $Existing 'remarks'
    if ($null -ne $oldRemarks) { $Return['remarks'] = [string]$oldRemarks }

    # A state assigned by hand in the CRM wins over "not detected".
    if ($null -eq $Return['state_code']) {
        $oldCode = [string](Get-PropertyValue $Existing 'state_code')
        if (-not [string]::IsNullOrWhiteSpace($oldCode)) {
            $oldCode = $oldCode.ToUpperInvariant()
            if ($States.Contains($oldCode)) {
                $Return['state_code'] = $oldCode
                $Return['state_name'] = $States[$oldCode]
            }
        }
    }

    $oldFlags = Get-PropertyValue $Existing 'status_flags'
    if ($null -ne $oldFlags) {
        foreach ($prop in $oldFlags.PSObject.Properties) {
            $Return['status_flags'][$prop.Name] = $prop.Value
        }
    }

    return $Return
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '=== Returns Intake - Stage 1 ===' -ForegroundColor White

try {
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
}
catch {
    Write-Fail ('ERROR: folder not found: ' + $Path)
    exit 1
}

if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Fail ('ERROR: not a folder: ' + $root)
    exit 1
}

Write-Plain ('Folder: ' + $root)

$manifestPath  = Join-Path $root 'manifest.json'
$scriptFile    = $MyInvocation.MyCommand.Path
$today         = (Get-Date).ToString('yyyy-MM-dd')
$generatedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

Write-Header 'Validation'

$topFiles = @(Get-ChildItem -LiteralPath $root -File | Where-Object {
    -not ($scriptFile -and $_.FullName -eq $scriptFile)
})

$badFiles = @($topFiles | Where-Object { $AllowedExtensions -notcontains $_.Extension.ToLowerInvariant() })

if ($badFiles.Count -gt 0) {
    Write-Fail ('ERROR: ' + $badFiles.Count + ' file(s) at the top level are not PDFs:')
    foreach ($file in $badFiles) { Write-Fail ('  - ' + $file.Name) }
    Write-Fail 'Remove or move these files out of the assignment folder, then re-run.'
    exit 1
}

$pdfFiles = @($topFiles | Where-Object { $_.Extension.ToLowerInvariant() -eq '.pdf' })

# Folders that already hold a PDF are returns from a previous run.
$existingReturnDirs = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object {
    @(Get-ChildItem -LiteralPath $_.FullName -Filter '*.pdf' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1).Count -gt 0
})

Write-Ok ('  ' + $pdfFiles.Count + ' PDF(s) to file at the top level.')
if ($existingReturnDirs.Count -gt 0) {
    Write-Note ('  ' + $existingReturnDirs.Count + ' return folder(s) already exist (previous run).')
}

if ($pdfFiles.Count -eq 0 -and $existingReturnDirs.Count -eq 0) {
    Write-Fail 'ERROR: no PDFs and no existing return folders found - nothing to do.'
    exit 1
}

# Build the work list: one entry per return, from loose PDFs + existing folders.
$workItems = New-Object System.Collections.ArrayList
$seenIds   = New-Object System.Collections.ArrayList

foreach ($pdf in $pdfFiles) {
    $id = $pdf.BaseName.TrimEnd(' ', '.')
    if ([string]::IsNullOrWhiteSpace($id)) {
        Write-Fail ('ERROR: cannot derive a folder name from "' + $pdf.Name + '".')
        exit 1
    }
    if ($id -ne $pdf.BaseName) {
        Write-Flag ('  [warn] "' + $pdf.BaseName + '" has trailing spaces/dots; using folder name "' + $id + '".')
    }
    if ($seenIds -contains $id) {
        Write-Fail ('ERROR: two PDFs map to the same folder name "' + $id + '". Rename one and re-run.')
        exit 1
    }
    [void]$seenIds.Add($id)
    [void]$workItems.Add([ordered]@{
        Id       = $id
        FileName = $pdf.Name
        Source   = $pdf
        IsNew    = $true
    })
}

foreach ($dir in $existingReturnDirs) {
    if ($seenIds -contains $dir.Name) { continue }   # loose PDF for this folder handled above
    [void]$seenIds.Add($dir.Name)
    $inner = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.pdf' -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1)
    [void]$workItems.Add([ordered]@{
        Id       = $dir.Name
        FileName = $inner[0].Name
        Source   = $null
        IsNew    = $false
    })
}

# Detect states before touching the filesystem.
$flaggedItems = New-Object System.Collections.ArrayList

foreach ($item in $workItems) {
    $matches = @(Get-StateCodeMatches $item['Id'])
    if ($matches.Count -eq 1) {
        $item['StateCode'] = $matches[0]
        $item['StateName'] = $States[$matches[0]]
    }
    else {
        $item['StateCode'] = $null
        $item['StateName'] = $null
        if ($matches.Count -eq 0) {
            $item['FlagReason'] = 'no state code detected'
        }
        else {
            $item['FlagReason'] = 'multiple state codes detected: ' + ($matches -join ', ')
        }
        [void]$flaggedItems.Add($item)
    }
}

foreach ($item in $flaggedItems) {
    Write-Flag ('  [flag] ' + $item['FileName'] + ' -> ' + $item['FlagReason'])
}

$cleanCount = $workItems.Count - $flaggedItems.Count
Write-Plain ''
Write-Plain ('Summary: ' + $workItems.Count + ' return(s) total | ' +
             $cleanCount + ' clean | ' + $flaggedItems.Count + ' flagged')

if ($flaggedItems.Count -gt 0) {
    Write-Flag 'Flagged returns still get a folder and a manifest entry, with no state assigned.'
    Write-Flag 'You can assign their state by hand in crm.html.'
    if (-not $Force) {
        $answer = Read-Host 'Proceed anyway? (Y/N)'
        if ($answer -notmatch '^[Yy]') {
            Write-Fail 'Aborted by user. Nothing was changed.'
            exit 2
        }
    }
}

# ---------------------------------------------------------------------------
# Processing
# ---------------------------------------------------------------------------

Write-Header 'Processing'

$createdCount = 0
$skippedCount = 0

foreach ($item in $workItems) {
    $targetDir = Join-Path $root $item['Id']

    if (-not $item['IsNew']) {
        Write-Note ('  [skip] ' + $item['Id'] + ' -> already processed')
        $skippedCount++
        continue
    }

    if (Test-Path -LiteralPath $targetDir -PathType Leaf) {
        Write-Flag ('  [skip] ' + $item['Id'] + ' -> a FILE with that name exists; left the PDF in place')
        $skippedCount++
        continue
    }

    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        New-Item -ItemType Directory -Path $targetDir | Out-Null
    }

    $destination = Join-Path $targetDir $item['FileName']

    if (Test-Path -LiteralPath $destination) {
        Write-Flag ('  [skip] ' + $item['Id'] + ' -> ' + $item['FileName'] +
                    ' already exists in the folder; left the top-level copy alone')
        $skippedCount++
        continue
    }

    try {
        Move-Item -LiteralPath $item['Source'].FullName -Destination $destination
        Write-Ok ('  [ok]   ' + $item['Id'] + ' -> moved ' + $item['FileName'])
        $createdCount++
    }
    catch {
        Write-Fail ('  [fail] ' + $item['Id'] + ' -> could not move file: ' + $_.Exception.Message)
        $skippedCount++
    }
}

if ($createdCount -eq 0 -and $skippedCount -gt 0) {
    Write-Note '  Nothing to move - all returns were already filed.'
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

Write-Header 'Manifest'

$existingManifest = Read-ExistingManifest $manifestPath
$existingById     = @{}

if ($null -ne $existingManifest) {
    foreach ($old in @(Get-PropertyValue $existingManifest 'returns')) {
        if ($null -eq $old) { continue }
        $oldId = [string](Get-PropertyValue $old 'id')
        if (-not [string]::IsNullOrWhiteSpace($oldId)) { $existingById[$oldId] = $old }
    }
    if ($existingById.Count -gt 0) {
        Write-Note ('  Carrying forward status flags / remarks for ' + $existingById.Count + ' existing return(s).')
    }
}

$returns = New-Object System.Collections.ArrayList
$flagged = New-Object System.Collections.ArrayList

foreach ($item in $workItems) {
    $entry = [ordered]@{
        id            = $item['Id']
        filename      = $item['FileName']
        folder        = $item['Id']
        state_code    = $item['StateCode']
        state_name    = $item['StateName']
        date_received = $today
        status_flags  = New-StatusFlagSet
        remarks       = ''
    }

    if ($existingById.ContainsKey($item['Id'])) {
        $entry = Merge-ExistingReturn $entry $existingById[$item['Id']]
    }

    [void]$returns.Add($entry)

    # Only report as flagged if it still has no state after the merge.
    if ($null -eq $entry['state_code']) {
        $reason = $item['FlagReason']
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'no state code detected' }
        [void]$flagged.Add([ordered]@{
            filename = $item['FileName']
            reason   = $reason
        })
    }
}

# Returns that exist in the old manifest but have no folder/PDF any more are kept
# so no tracked work is silently dropped.
$currentIds = @($returns | ForEach-Object { $_['id'] })
$orphans    = @($existingById.Keys | Where-Object { $currentIds -notcontains $_ })

foreach ($orphanId in $orphans) {
    $old   = $existingById[$orphanId]
    $entry = [ordered]@{
        id            = $orphanId
        filename      = [string](Get-PropertyValue $old 'filename')
        folder        = [string](Get-PropertyValue $old 'folder')
        state_code    = $null
        state_name    = $null
        date_received = $today
        status_flags  = New-StatusFlagSet
        remarks       = ''
    }
    $entry = Merge-ExistingReturn $entry $old
    [void]$returns.Add($entry)
    Write-Flag ('  [warn] "' + $orphanId + '" is in manifest.json but has no folder here; kept its tracked status.')
}

$manifest = [ordered]@{
    generated_at      = $generatedAt
    assignment_folder = $root
    returns           = $returns.ToArray()
    flagged           = $flagged.ToArray()
}

# Preserve unknown top-level keys from a previous manifest.
if ($null -ne $existingManifest) {
    foreach ($prop in $existingManifest.PSObject.Properties) {
        if (-not $manifest.Contains($prop.Name)) { $manifest[$prop.Name] = $prop.Value }
    }
}

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $backupName = 'manifest.backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.json'
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $root $backupName)
    Write-Note ('  Backed up previous manifest.json -> ' + $backupName)
}

try {
    $json     = ConvertTo-JsonManual $manifest 0
    $encoding = New-Object System.Text.UTF8Encoding($false)   # no BOM: keeps JSON.parse happy
    [System.IO.File]::WriteAllText($manifestPath, $json, $encoding)
    Write-Ok ('  Wrote ' + $manifestPath)
}
catch {
    Write-Fail ('ERROR: could not write manifest.json: ' + $_.Exception.Message)
    exit 1
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ''
Write-Ok ('Processed ' + $returns.Count + ' returns, ' + $flagged.Count +
          ' flagged, manifest.json written.')
Write-Plain 'Next: open crm.html in a browser and import manifest.json.'
Write-Host ''

exit 0
