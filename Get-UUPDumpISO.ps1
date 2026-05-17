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

# Latest = highest build number, English (avoid pre-release rings if possible)
$latest = $builds | Sort-Object @{Expression = { [int]($_.build -replace '\..*','') }; Descending = $true} |
                    Select-Object -First 1
$buildId   = $latest.uuid
$buildName = $latest.title
Write-Host "[UUP] Selected build: $buildName"
Write-Host "[UUP] Build UUID: $buildId"

# --- Verify language is available ---------------------------------------
$langResp = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listlangs.php' `
                              -Body @{ id = $buildId } -ErrorAction Stop
$availableLangs = @($langResp.response.langFancyNames.PSObject.Properties.Name)
if ($Language -notin $availableLangs) {
    throw "Language '$Language' not available. Available: $($availableLangs -join ', ')"
}

# --- Verify edition is available ----------------------------------------
$edResp = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listeditions.php' `
                            -Body @{ id = $buildId; lang = $Language } -ErrorAction Stop
$availableEditions = @($edResp.response.editionFancyNames.PSObject.Properties.Name)
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
