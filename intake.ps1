<#
.SYNOPSIS
    Returns Intake - Stage 1. Validates a folder of return PDFs, files each one
    into its own folder, and writes a manifest.json for the browser CRM.

.DESCRIPTION
    Run this from inside a freshly created assignment folder that contains the
    day's PDFs. Run the .ps1 file as a whole; do not paste it into the console
    or use "Run Selection", because that separates else blocks from their if
    statements and removes the advanced-script context required by ShouldProcess.
    It will:
      1. Validate the folder (PDFs plus known companion files at top level,
         recognizable state codes).
      2. Print a validation summary and ask for confirmation if anything is flagged.
      3. Create one folder per PDF (filename minus .pdf) and move the PDF into it.
      4. Write manifest.json describing every return.

    Safe to re-run: existing folders are not overwritten, and if a manifest.json
    is already present its status flags / remarks / CRM-assigned states are
    carried forward (the old file is backed up first).

.PARAMETER Path
    Assignment folder to process. Defaults to the current working directory.

.PARAMETER Force
    Skip the Y/N confirmation prompts (flagged returns, unrecognised top-level
    files) and just continue.

.PARAMETER StateMap
    Path to a JSON file of hand-assigned state codes, resolved relative to the
    current working directory. When omitted, a file named state-overrides.json
    in the assignment folder is picked up automatically if it exists.

    Format - keys are either a return id (the filename minus .pdf) or the exact
    filename, values are 2-letter state codes. Matching is case-insensitive:

        {
          "CTC-01_MD510": "MD",
          "weird file.pdf": "TX"
        }

    An override beats filename detection and beats a state carried forward from
    a previous manifest, and a return fixed by an override is not flagged.

.PARAMETER Log
    Write a transcript of the run to intake-log-<timestamp>.txt in the
    assignment folder. If the host does not support transcripts the run still
    continues, unlogged.

.EXAMPLE
    cd C:\Work\2026-08-11
    .\intake.ps1

.EXAMPLE
    C:\Tools\run-intake.cmd -Path 'C:\Work\2026-08-11'
    Windows launcher that checks the PowerShell version and invokes this entire
    script with the appropriate execution-policy bypass.

.EXAMPLE
    .\intake.ps1 -Path 'C:\Work\2026-08-11' -Force

.EXAMPLE
    .\intake.ps1 -WhatIf
    Full dry run: validates, reports what it would do, and touches nothing.

.EXAMPLE
    .\intake.ps1 -StateMap .\fixes.json -Log

.NOTES
    PowerShell 3.0+ / Windows PowerShell 5.1 compatible. No external modules,
    no admin rights required.

    Exit codes:
      0  Success (a completed -WhatIf dry run also exits 0).
      1  Unusable input or a failed write: folder missing, path is not a folder,
         no PDFs and no existing return folders, two PDFs mapping to the same
         folder name, an unusable filename, an explicit -StateMap that cannot be
         read or parsed, or manifest.json could not be built/written.
      2  Aborted at a Y/N prompt. Nothing was changed.
#>

#Requires -Version 3.0

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $Path = '.',
    [switch] $Force,
    [string] $StateMap = '',
    [switch] $Log
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
# Transcript (-Log)
#
# Start-Transcript is missing or unsupported in some hosts (ISE add-ons,
# embedded runspaces, constrained language mode), and losing a log file is
# never a reason to lose the intake run - so every call is best-effort.
# ---------------------------------------------------------------------------

$script:TranscriptRunning = $false

function Stop-IntakeTranscript {
    if (-not $script:TranscriptRunning) { return }
    $script:TranscriptRunning = $false
    try { Stop-Transcript | Out-Null } catch { }
}

# An unhandled terminating error would otherwise leave the transcript open for
# the rest of the session; close it, then let the error end the script as usual.
trap { Stop-IntakeTranscript; break }

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

# Top-level extensions that are tolerated (JSON = manifest/backups/overrides,
# PS1 = this script). The office formats are here because the CRM's own exports
# land next to the returns; hard-stopping on them punished normal use.
$AllowedExtensions = @(
    '.pdf', '.json', '.ps1',
    '.xlsx', '.xls', '.csv', '.txt', '.md', '.log'
)

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
                if ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) } else { [void]$sb.Append($ch) }
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
# whole run is exactly two letters, so "MD510" -> MD, the state segment in
# "CI6AIF_12.31.25_NJ-CBT_Return_E-file" -> NJ, and "MASTER" -> nothing.
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

    # Return the codes bare, with no wrapping comma. `,$array` returns an array
    # *containing* the array, so the caller's @(...) unwrapped to Count = 1 no
    # matter how many codes were found: a name with no state code and a name with
    # two both looked like exactly one match. That is why nothing was ever
    # flagged, and why every state_code was written as ["MD"] instead of "MD".
    # @(...) at the call site is what keeps a single code an array.
    return $found.ToArray()
}

# ---------------------------------------------------------------------------
# State overrides
#
# Detection is deliberately narrow, but a wrong guess is worse than a flag
# because nobody sees it happen. This is the escape hatch: an explicit map of
# return id (or exact filename) -> state code that always wins.
#
# Returns a case-insensitive hashtable, or $null if the file could not be used
# at all - the caller decides whether that is fatal.
# ---------------------------------------------------------------------------

# Ordinal (not culture) comparison: filenames are not language, and a plain
# @{} compares with CurrentCultureIgnoreCase, which mangles "I" in a Turkish
# locale. The fallback is only there so an odd host can never break the run.
function New-NameMap {
    try {
        return (New-Object -TypeName System.Collections.Hashtable `
                           -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase))
    } catch {
        return @{}
    }
}

function Import-StateOverrides {
    param([string] $MapPath)

    $map = New-NameMap

    try {
        $raw = Get-Content -LiteralPath $MapPath -Raw -Encoding UTF8
    } catch {
        Write-Flag ('  [warn] Could not read ' + $MapPath + ' (' + $_.Exception.Message + ').')
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($raw)) { return $map }

    try { $parsed = $raw | ConvertFrom-Json } catch {
        Write-Flag ('  [warn] ' + $MapPath + ' is not valid JSON (' + $_.Exception.Message + ').')
        return $null
    }

    # Anything that is not a JSON object would enumerate as junk "properties".
    if ($null -eq $parsed -or $parsed -is [System.Array] -or
        $parsed -is [string] -or $parsed -is [System.ValueType]) {
        Write-Flag ('  [warn] ' + $MapPath + ' must be a JSON object of "name": "STATE" pairs.')
        return $null
    }

    foreach ($prop in $parsed.PSObject.Properties) {
        $key = [string]$prop.Name
        if ([string]::IsNullOrWhiteSpace($key)) { continue }

        $code = ([string]$prop.Value).Trim().ToUpperInvariant()
        if (-not $States.Contains($code)) {
            Write-Flag ('  [warn] override "' + $key + '" -> "' + [string]$prop.Value +
                        '" is not a known state code; ignored.')
            continue
        }

        if ($map.ContainsKey($key)) {
            Write-Flag ('  [warn] override "' + $key + '" appears twice (case-insensitively); using ' + $code + '.')
        }
        $map[$key] = $code
    }

    return $map
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
    } catch {
        Write-Flag ('  [warn] Existing manifest.json could not be parsed (' + $_.Exception.Message + ').')
        Write-Flag '         It will be backed up and rebuilt from scratch; status flags in it are NOT carried over.'
        return $null
    }
}

# ---------------------------------------------------------------------------
# Column set (works with the CRM's custom and typed columns)
#
# The 8 steps above are what this script knows about, but the CRM can add columns
# of its own, and each one can hold yes/no/issue, a number, or text. Those live in
# the manifest's `flags` array, which this script carries forward untouched as an
# unknown top-level key.
#
# A brand-new PDF filed on a later run still needs an entry for every one of
# those columns, or the return would arrive in the app with holes in it. So the
# key set is read back out of the existing manifest rather than assumed, and each
# key gets the empty value its own type expects: "" for text, null for the other
# two. The app would heal a missing key on import anyway - this means it never has
# to, and the manifest on disk is complete on its own terms.
# ---------------------------------------------------------------------------

$script:FlagSpecs = $null   # ordered: key -> 'status' | 'number' | 'text'

function Get-FlagSpecs {
    param($ExistingManifest)

    $specs = [ordered]@{}
    foreach ($key in $FlagKeys) { $specs[$key] = 'status' }
    if ($null -eq $ExistingManifest) { return $specs }

    $flags = Get-PropertyValue $ExistingManifest 'flags'
    if ($null -eq $flags) { return $specs }

    $extra = New-Object System.Collections.ArrayList
    foreach ($flag in @($flags)) {
        if ($null -eq $flag) { continue }
        $key = [string](Get-PropertyValue $flag 'key')
        if ([string]::IsNullOrWhiteSpace($key)) { continue }

        $type = [string](Get-PropertyValue $flag 'type')
        if ($type -ne 'number' -and $type -ne 'text') { $type = 'status' }

        if (-not $specs.Contains($key)) { [void]$extra.Add($key) }
        $specs[$key] = $type
    }

    if ($extra.Count -gt 0) {
        Write-Note ('  ' + $extra.Count + ' custom column(s) from the app carried forward: ' +
                    (($extra | Select-Object -First 6) -join ', ') +
                    $(if ($extra.Count -gt 6) { ', ...' } else { '' }))
    }

    return $specs
}

function New-StatusFlagSet {
    $specs = $script:FlagSpecs
    if ($null -eq $specs) {
        $specs = [ordered]@{}
        foreach ($key in $FlagKeys) { $specs[$key] = 'status' }
    }

    $flags = [ordered]@{}
    foreach ($key in $specs.Keys) {
        if ($specs[$key] -eq 'text') { $flags[$key] = '' } else { $flags[$key] = $null }
    }
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
} catch {
    Write-Fail ('ERROR: folder not found: ' + $Path)
    exit 1
}

if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Fail ('ERROR: not a folder: ' + $root)
    exit 1
}

Write-Plain ('Folder: ' + $root)

if ($Log) {
    $logName = 'intake-log-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt'
    $logPath = Join-Path $root $logName
    if ($WhatIfPreference) {
        # A log file is still a file, so a dry run must not create one.
        Write-Note ('  [dry]  would log this run to ' + $logName)
    } else {
        try {
            # -LiteralPath only exists on newer hosts; -Path keeps PS 3.0 happy.
            Start-Transcript -Path $logPath -Confirm:$false | Out-Null
            $script:TranscriptRunning = $true
            Write-Note ('  Logging this run to ' + $logName)
        } catch {
            Write-Flag ('  [warn] Could not start a transcript (' + $_.Exception.Message +
                        '); continuing without a log.')
        }
    }
}

$manifestPath  = Join-Path $root 'manifest.json'
$scriptFile    = $MyInvocation.MyCommand.Path
$today         = (Get-Date).ToString('yyyy-MM-dd')
$generatedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

# ---------------------------------------------------------------------------
# State overrides: explicit -StateMap first, otherwise the conventional file
# in the assignment folder. A map the user asked for by name and that cannot be
# read is fatal - carrying on would silently ignore the fix they wanted.
# ---------------------------------------------------------------------------

$stateOverrides   = New-NameMap
$overrideSource   = ''
$overrideUsedKeys = New-Object System.Collections.ArrayList

if (-not [string]::IsNullOrWhiteSpace($StateMap)) {
    try {
        $overrideSource = (Resolve-Path -LiteralPath $StateMap -ErrorAction Stop).ProviderPath
    } catch {
        Write-Fail ('ERROR: -StateMap file not found: ' + $StateMap)
        Stop-IntakeTranscript
        exit 1
    }

    $loaded = Import-StateOverrides $overrideSource
    if ($null -eq $loaded) {
        Write-Fail ('ERROR: -StateMap file could not be used: ' + $overrideSource)
        Stop-IntakeTranscript
        exit 1
    }
    $stateOverrides = $loaded
} else {
    $defaultMap = Join-Path $root 'state-overrides.json'
    if (Test-Path -LiteralPath $defaultMap -PathType Leaf) {
        $overrideSource = $defaultMap
        $loaded = Import-StateOverrides $defaultMap
        if ($null -eq $loaded) {
            # Nobody asked for this file by name, so a broken one is a warning.
            Write-Flag '  [warn] state-overrides.json was ignored; detection is on its own.'
            $overrideSource = ''
        } else {
            $stateOverrides = $loaded
        }
    }
}

if ($stateOverrides.Count -gt 0) {
    Write-Note ('  ' + $stateOverrides.Count + ' state override(s) loaded from ' +
                (Split-Path -Leaf $overrideSource) + '.')
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

Write-Header 'Validation'

$topFiles = @(Get-ChildItem -LiteralPath $root -File | Where-Object {
    -not ($scriptFile -and $_.FullName -eq $scriptFile)
})

$unknownFiles = @($topFiles | Where-Object { $AllowedExtensions -notcontains $_.Extension.ToLowerInvariant() })

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
    Stop-IntakeTranscript
    exit 1
}

# Unrecognised top-level files are the main "you are in the wrong folder" tell,
# but they are not a reason to refuse the work - the returns are still there and
# nothing is ever done to these files. So: show them and let the operator judge.
if ($unknownFiles.Count -gt 0) {
    Write-Flag ('  [flag] ' + $unknownFiles.Count +
                ' file(s) at the top level are neither PDFs nor known companion files:')
    foreach ($file in $unknownFiles) { Write-Flag ('         - ' + $file.Name) }
    Write-Flag '         They will be left exactly where they are.'
    # Said out loud on every path, because a -Force run has nobody reading a prompt.
    Write-Flag ('         If you did not expect them, you are probably in the wrong folder: ' + $root)
    Write-Flag ('         Found ' + $pdfFiles.Count + ' PDF(s), ' + $existingReturnDirs.Count +
                ' existing return folder(s) and ' + $unknownFiles.Count + ' unrecognised file(s).')

    if ($Force) {
        Write-Note '  -Force: continuing without asking.'
    } elseif ($WhatIfPreference) {
        Write-Note '  [dry]  continuing without asking (nothing can be changed anyway).'
    } else {
        $answer = Read-Host 'Continue with this folder? (Y/N)'
        if ($answer -notmatch '^[Yy]') {
            Write-Fail 'Aborted by user. Nothing was changed.'
            Stop-IntakeTranscript
            exit 2
        }
    }
}

# Build the work list: one entry per return, from loose PDFs + existing folders.
$workItems = New-Object System.Collections.ArrayList
$seenIds   = New-Object System.Collections.ArrayList

foreach ($pdf in $pdfFiles) {
    $id = $pdf.BaseName.TrimEnd(' ', '.')
    if ([string]::IsNullOrWhiteSpace($id)) {
        Write-Fail ('ERROR: cannot derive a folder name from "' + $pdf.Name + '".')
        Stop-IntakeTranscript
        exit 1
    }
    if ($id -ne $pdf.BaseName) {
        Write-Flag ('  [warn] "' + $pdf.BaseName + '" has trailing spaces/dots; using folder name "' + $id + '".')
    }
    if ($seenIds -contains $id) {
        Write-Fail ('ERROR: two PDFs map to the same folder name "' + $id + '". Rename one and re-run.')
        Stop-IntakeTranscript
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
# ($stateHits, not $matches: $Matches is PowerShell's automatic variable and the
#  next -match anywhere in the script would silently overwrite it.)
$flaggedItems  = New-Object System.Collections.ArrayList
$overrideCount = 0

foreach ($item in $workItems) {
    # Override first, and it is not second-guessed: the id (filename minus .pdf)
    # is the normal key, the exact filename is the fallback for odd names.
    $overrideCode = $null
    if ($stateOverrides.Count -gt 0) {
        if ($stateOverrides.ContainsKey($item['Id'])) {
            $overrideCode = $stateOverrides[$item['Id']]
            $key = $item['Id']
        } elseif ($stateOverrides.ContainsKey($item['FileName'])) {
            $overrideCode = $stateOverrides[$item['FileName']]
            $key = $item['FileName']
        }
    }

    if ($null -ne $overrideCode) {
        $item['StateCode']  = $overrideCode
        $item['StateName']  = $States[$overrideCode]
        $item['FlagReason'] = $null
        if ($overrideUsedKeys -notcontains $key) { [void]$overrideUsedKeys.Add($key) }
        $overrideCount++
        Write-Note ('  [ovr]  ' + $item['FileName'] + ' -> ' + $overrideCode + ' (override)')
        continue
    }

    $stateHits = @(Get-StateCodeMatches $item['Id'])
    if ($stateHits.Count -eq 1) {
        $item['StateCode'] = $stateHits[0]
        $item['StateName'] = $States[$stateHits[0]]
    } else {
        $item['StateCode'] = $null
        $item['StateName'] = $null
        if ($stateHits.Count -eq 0) {
            $item['FlagReason'] = 'no state code detected'
        } else {
            $item['FlagReason'] = 'multiple state codes detected: ' + ($stateHits -join ', ')
        }
        [void]$flaggedItems.Add($item)
    }
}

foreach ($item in $flaggedItems) {
    Write-Flag ('  [flag] ' + $item['FileName'] + ' -> ' + $item['FlagReason'])
}

# An override key that matched nothing is usually a typo in the map, and a typo
# there looks exactly like "the override did not work".
if ($stateOverrides.Count -gt 0) {
    foreach ($key in @($stateOverrides.Keys)) {
        if ($overrideUsedKeys -notcontains $key) {
            Write-Flag ('  [warn] override "' + $key + '" matched no return in this folder.')
        }
    }
}

$cleanCount = $workItems.Count - $flaggedItems.Count
Write-Plain ''
Write-Plain ('Summary: ' + $workItems.Count + ' return(s) total | ' +
             $cleanCount + ' clean | ' + $flaggedItems.Count + ' flagged | ' +
             $overrideCount + ' override(s) applied')

if ($flaggedItems.Count -gt 0) {
    Write-Flag 'Flagged returns still get a folder and a manifest entry, with no state assigned.'
    Write-Flag 'You can assign their state by hand in index.html, or in the override file.'
    if ($Force) {
        Write-Note '  -Force: continuing without asking.'
    } elseif ($WhatIfPreference) {
        Write-Note '  [dry]  continuing without asking (nothing can be changed anyway).'
    } else {
        $answer = Read-Host 'Proceed anyway? (Y/N)'
        if ($answer -notmatch '^[Yy]') {
            Write-Fail 'Aborted by user. Nothing was changed.'
            Stop-IntakeTranscript
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
$wouldCount   = 0

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
        if ($PSCmdlet.ShouldProcess($targetDir, 'Create return folder')) {
            # -Confirm:$false - permission was just granted above; asking twice
            # under -Confirm would only train people to hit Y blindly.
            try {
                New-Item -ItemType Directory -Path $targetDir -Confirm:$false | Out-Null
            } catch {
                Write-Fail ('  [fail] ' + $item['Id'] + ' -> could not create folder: ' + $_.Exception.Message)
                $skippedCount++
                continue
            }
        } elseif (-not $WhatIfPreference) {
            # Declined at a -Confirm prompt: there is nowhere to move the PDF to,
            # so stop here rather than let Move-Item fail confusingly.
            Write-Note ('  [skip] ' + $item['Id'] + ' -> folder not created (declined at the prompt)')
            $skippedCount++
            continue
        }
    }

    $destination = Join-Path $targetDir $item['FileName']

    if (Test-Path -LiteralPath $destination) {
        Write-Flag ('  [skip] ' + $item['Id'] + ' -> ' + $item['FileName'] +
                    ' already exists in the folder; left the top-level copy alone')
        $skippedCount++
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($destination, 'Move PDF into its return folder')) {
        # -WhatIf, or declined at a -Confirm prompt. The folder above was not
        # created either, so the folder stays exactly as it was.
        if ($WhatIfPreference) {
            Write-Note ('  [dry]  ' + $item['Id'] + ' -> would move ' + $item['FileName'])
            $wouldCount++
        } else {
            Write-Note ('  [skip] ' + $item['Id'] + ' -> declined at the prompt')
            $skippedCount++
        }
        continue
    }

    try {
        Move-Item -LiteralPath $item['Source'].FullName -Destination $destination -Confirm:$false
        Write-Ok ('  [ok]   ' + $item['Id'] + ' -> moved ' + $item['FileName'])
        $createdCount++
    } catch {
        Write-Fail ('  [fail] ' + $item['Id'] + ' -> could not move file: ' + $_.Exception.Message)
        $skippedCount++
    }
}

if ($createdCount -eq 0 -and $wouldCount -eq 0 -and $skippedCount -gt 0) {
    Write-Note '  Nothing to move - all returns were already filed.'
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

Write-Header 'Manifest'

$existingManifest = Read-ExistingManifest $manifestPath
$existingById     = @{}

# Learn the full column set (including any the app added, and what each holds)
# before building a single return, so every new entry is complete.
$script:FlagSpecs = Get-FlagSpecs $existingManifest

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

# The CRM stamps the same number on anything it exports, so writing it here is
# what lets a script-written manifest survive an import/export round trip
# unchanged. Never write a number lower than one we have already seen, or a
# newer app's file would be quietly downgraded.
$schemaVersion = 1
if ($null -ne $existingManifest) {
    $oldSchema = 0
    if ([int]::TryParse([string](Get-PropertyValue $existingManifest 'schema_version'), [ref]$oldSchema)) {
        if ($oldSchema -gt $schemaVersion) {
            $schemaVersion = $oldSchema
            Write-Note ('  Keeping the existing manifest schema_version of ' + $schemaVersion + '.')
        }
    }
}

$manifest = [ordered]@{
    schema_version    = $schemaVersion
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
    $backupPath = Join-Path $root $backupName
    if ($PSCmdlet.ShouldProcess($backupPath, 'Back up the previous manifest.json')) {
        Copy-Item -LiteralPath $manifestPath -Destination $backupPath -Confirm:$false
        Write-Note ('  Backed up previous manifest.json -> ' + $backupName)
    }
}

# Render before asking permission: a dry run should prove the manifest can
# actually be built, not just claim it would be.
try {
    $json = ConvertTo-JsonManual $manifest 0
} catch {
    Write-Fail ('ERROR: could not build the manifest JSON: ' + $_.Exception.Message)
    Stop-IntakeTranscript
    exit 1
}

$manifestWritten = $false

if ($PSCmdlet.ShouldProcess($manifestPath, 'Write manifest.json')) {
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)   # no BOM: keeps JSON.parse happy
        [System.IO.File]::WriteAllText($manifestPath, $json, $encoding)
        Write-Ok ('  Wrote ' + $manifestPath)
        $manifestWritten = $true
    } catch {
        Write-Fail ('ERROR: could not write manifest.json: ' + $_.Exception.Message)
        Stop-IntakeTranscript
        exit 1
    }
} else {
    Write-Note ('  [dry]  manifest.json NOT written; ' + $json.Length +
                ' characters were rendered without error.')
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ''
if ($manifestWritten) {
    Write-Ok ('Processed ' + $returns.Count + ' returns, ' + $flagged.Count +
              ' flagged, manifest.json written.')
    Write-Plain 'Next: open index.html in a browser and import manifest.json.'
} elseif ($WhatIfPreference) {
    Write-Note ('Dry run (-WhatIf): nothing was changed. ' + $wouldCount + ' PDF(s) would be filed, ' +
                $returns.Count + ' return(s) would be in manifest.json, ' + $flagged.Count + ' flagged.')
} else {
    Write-Flag ('manifest.json was NOT written (declined at the prompt). ' + $createdCount +
                ' PDF(s) were filed, so the folder and the manifest are now out of step.')
}
Write-Host ''

Stop-IntakeTranscript
exit 0
