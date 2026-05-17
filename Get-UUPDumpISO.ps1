<#
.SYNOPSIS
  Downloads a Windows 11 ISO via UUP Dump's API + conversion scripts.

.DESCRIPTION
  Queries https://api.uupdump.net for the latest build matching the requested
  release, downloads the conversion script pack, runs the conversion
  non-interactively (via AutoExit=1 in ConvertConfig.ini), and prints the
  path to the resulting ISO on stdout.

  This bypasses Microsoft's public software-download endpoints entirely.
  UUP Dump's scripts pull files from the Windows Update CDN
  (*.delivery.mp.microsoft.com) which corporate firewalls almost never
  block — Windows Update has to work for the machine.

.PARAMETER Release
  '24H2' or '25H2'. Searches for the latest published build matching
  the corresponding Windows 11 build number prefix.

.PARAMETER Language
  UUP Dump language code, e.g. 'en-us' (default).

.PARAMETER Edition
  UUP Dump edition slug, e.g. 'Professional' (default), 'Core', 'Education'.

.PARAMETER WorkDir
  Where to extract the pack and run the conversion. Needs ~30 GB free.

.EXAMPLE
  PS> .\Get-UUPDumpISO.ps1 -Release 25H2

  Downloads and converts the latest 25H2 Pro/en-us ISO. Prints the
  resulting .iso path to stdout when done (~30-60 min).

.LINK
  https://uupdump.net
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('24H2','25H2')]
    [string]$Release,

    [string]$Language = 'en-us',
    [string]$Edition  = 'Professional',
    [string]$WorkDir  = 'C:\Tools\WinVHDX\UUPDump'
)

$ErrorActionPreference = 'Stop'

# --- Admin check ---------------------------------------------------------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run from an elevated PowerShell — UUP conversion uses DISM and needs admin.'
}

# --- Disk space pre-flight ----------------------------------------------
# Conversion needs ~30 GB peak (raw UUP files + temp ISO + extracted content)
$workDriveLetter = (Split-Path $WorkDir -Qualifier).TrimEnd(':')
$freeGB = [int]((Get-PSDrive -Name $workDriveLetter -ErrorAction Stop).Free / 1GB)
if ($freeGB -lt 30) {
    throw "Not enough free space on ${workDriveLetter}: drive. Need ~30 GB, have ${freeGB} GB."
}

# --- Map release → UUP Dump search query --------------------------------
# Windows 11 build number prefixes: 24H2 = 26100, 25H2 = 26200
$searchMap = @{
    '24H2' = 'windows 11 26100'
    '25H2' = 'windows 11 26200'
}
$search = $searchMap[$Release]

# --- Query UUP Dump for the latest matching build -----------------------
Write-Host "[UUP] Querying UUP Dump for latest Windows 11 $Release..."
$listResp = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listid.php' `
                              -Body @{ search = $search } -ErrorAction Stop

# Response shape: $listResp.response.builds is either a hashtable keyed by uuid
# or an object whose properties are uuids. Normalize to a flat array.
$builds = @()
if ($listResp.response.builds) {
    foreach ($prop in $listResp.response.builds.PSObject.Properties) {
        $builds += $prop.Value
    }
}
if (-not $builds) {
    throw "UUP Dump API returned no builds matching '$search'."
}

# Search hits include lots of non-OS packages (cumulative updates,
# .NET Framework, Defender, Edge, Service Stack, etc.). Filter to actual
# OS feature-release builds — UUP Dump titles them
# "Windows 11, version 25H2 (26200.XXXX)". Arch is a separate field (when
# present), not in the title — prefer amd64 if the API exposes it, accept
# anything if it doesn't.
$titlePattern = "^Windows 11, version $Release\s*\("
$osBuilds = $builds | Where-Object {
    $_.title -match $titlePattern -and
    (-not ($_.PSObject.Properties.Name -contains 'arch') -or $_.arch -eq 'amd64')
}
if (-not $osBuilds) {
    throw ("Found $($builds.Count) builds for '$search' but none matched the OS title pattern '$titlePattern'.`n" +
           "Sample titles:`n  - " + (($builds | Select-Object -First 5).title -join "`n  - "))
}

# Highest build number wins
$latest = $osBuilds | Sort-Object @{Expression = { [int]($_.build -replace '\..*','') }; Descending = $true} |
                      Select-Object -First 1
$buildId   = $latest.uuid
$buildName = $latest.title
Write-Host "[UUP] Selected build: $buildName"
Write-Host "[UUP] Build UUID: $buildId"

# Extracts language/edition keys from a UUP Dump response. The API returns
# either a hashtable-like object (real data) or an empty array (no data,
# usually because we picked the wrong build). PSObject.Properties.Name on
# an empty array returns the array's own properties (Length, LongLength,
# etc.) — not useful. Filter to short token-like strings to drop that noise.
function Get-UUPKeys {
    param($Container)
    if (-not $Container) { return @() }
    @($Container.PSObject.Properties.Name) | Where-Object {
        # Language codes look like 'en-us', 'zh-tw'; edition slugs are
        # short identifiers like 'Professional', 'CoreSingleLanguage'.
        # The array-property noise (Length, IsReadOnly, ...) doesn't fit
        # either pattern.
        $_ -match '^[a-z]{2,3}(-[a-z]{2,4})?$' -or
        $_ -match '^[A-Z][A-Za-z]{2,}$'
    }
}

# --- Verify language is available ---------------------------------------
$langResp = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listlangs.php' `
                              -Body @{ id = $buildId } -ErrorAction Stop
$availableLangs = Get-UUPKeys $langResp.response.langFancyNames
if (-not $availableLangs) {
    throw "UUP Dump returned no language list for build $buildId — likely wrong build kind."
}
if ($Language -notin $availableLangs) {
    throw "Language '$Language' not available. Available: $($availableLangs -join ', ')"
}

# --- Verify edition is available ----------------------------------------
$edResp = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listeditions.php' `
                            -Body @{ id = $buildId; lang = $Language } -ErrorAction Stop
$availableEditions = Get-UUPKeys $edResp.response.editionFancyNames
if (-not $availableEditions) {
    throw "UUP Dump returned no edition list for build $buildId / $Language."
}
if ($Edition -notin $availableEditions) {
    throw "Edition '$Edition' not available for $Language. Available: $($availableEditions -join ', ')"
}

# --- Request the conversion script pack ---------------------------------
$packDir = Join-Path $WorkDir "Win11-$Release"
if (Test-Path $packDir) {
    Write-Host "[UUP] Cleaning prior pack directory: $packDir"
    Remove-Item $packDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $packDir -Force | Out-Null

Write-Host '[UUP] Downloading conversion script pack...'
$packZip = Join-Path $packDir 'pack.zip'
$packUrl = "https://uupdump.net/get.php?id=$buildId&pack=$Language&edition=$Edition"
Invoke-WebRequest -Method Post -Uri $packUrl `
                  -Body @{ autodl = 2; updates = 1; cleanup = 1 } `
                  -OutFile $packZip -UseBasicParsing -ErrorAction Stop

Write-Host '[UUP] Extracting pack...'
Expand-Archive -Path $packZip -DestinationPath $packDir -Force
Remove-Item $packZip -Force -ErrorAction SilentlyContinue

# --- Patch ConvertConfig.ini for non-interactive operation --------------
# AutoExit=1   → script exits without "press any key"
# ResetBase=1  → trims older component versions to shrink the ISO
# SkipWinRE=1  → faster build, smaller ISO; we don't need recovery env
$iniPath = Join-Path $packDir 'ConvertConfig.ini'
if (Test-Path $iniPath) {
    Write-Host '[UUP] Patching ConvertConfig.ini for non-interactive run...'
    (Get-Content $iniPath) `
        -replace '^(AutoExit\s*)=.*','$1=1' `
        -replace '^(ResetBase\s*)=.*','$1=1' `
        -replace '^(SkipWinRE\s*)=.*','$1=1' |
    Set-Content $iniPath
} else {
    Write-Warning "ConvertConfig.ini not found at $iniPath — conversion may prompt interactively."
}

# --- Patch get_aria2.ps1 for managed-PS environments --------------------
# UUP Dump's get_aria2.ps1 calls Get-FileHash to verify the aria2c download.
# On some Windows PowerShell 5.1 hosts (typically managed/locked-down boxes
# with module-autoloading suppressed) the cmdlet isn't resolvable in the
# context the cmd script invokes powershell in, even though it works fine
# from a normal PS prompt. Inject a .NET-based fallback at the top so the
# verify step works either way; the real cmdlet still wins when available.
$getAria = Join-Path $packDir 'files\get_aria2.ps1'
if (Test-Path $getAria) {
    Write-Host '[UUP] Patching get_aria2.ps1 with a Get-FileHash fallback...'
    $shim = @'
if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
    function Get-FileHash {
        param([string]$Path, [string]$Algorithm = 'SHA256')
        $h = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
        $s = [IO.File]::OpenRead($Path)
        try {
            $b = $h.ComputeHash($s)
            return [PSCustomObject]@{ Algorithm = $Algorithm; Hash = ([BitConverter]::ToString($b) -replace '-',''); Path = $Path }
        } finally { $s.Close() }
    }
}

'@
    $orig = Get-Content $getAria -Raw
    Set-Content -Path $getAria -Value ($shim + $orig) -Encoding UTF8 -NoNewline
}

# --- Run the conversion script ------------------------------------------
$convScript = Join-Path $packDir 'uup_download_windows.cmd'
if (-not (Test-Path $convScript)) {
    throw "uup_download_windows.cmd not found in extracted pack at $packDir"
}

Write-Host '[UUP] Running conversion (downloads ~5 GB from Windows Update CDN, 30-60 min)...'
Push-Location $packDir
try {
    # cmd /c executes the .cmd script. Output is line-streamed so the GUI's
    # status parser can update from key phases (e.g. aria2c download lines,
    # DISM apply progress, "Done." at the end).
    & cmd /c uup_download_windows.cmd 2>&1 | ForEach-Object { "$_" }
} finally {
    Pop-Location
}

# --- Locate the resulting ISO -------------------------------------------
$iso = Get-ChildItem $packDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
       Sort-Object Length -Descending |
       Select-Object -First 1
if (-not $iso) {
    throw "Conversion completed but no .iso file found in $packDir"
}

Write-Host "[UUP] ISO created: $($iso.FullName)"
Write-Host "[UUP] Size: $([math]::Round($iso.Length / 1MB, 0)) MB"
Write-Output $iso.FullName
