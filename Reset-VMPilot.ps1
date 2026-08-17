<#
.SYNOPSIS
    Wipes VM-Pilot state so the next run exercises the full pipeline from zero.

.DESCRIPTION
    Removes:
      - All Hyper-V VMs except a known "keep" list (your pre-existing VMs).
      - Their C:\VMs\<name>\ folders.
      - Every cached parent VHDX (C:\VMs\Win11-*.vhdx -- one per release).
      - The cached community AutoPilot script (C:\Tools\VMPilot\...), left
        behind by VM-Pilot 0.5.0 and earlier. Current versions install the
        import GUI from PSGallery inside the VM and cache nothing on the host.

    Optionally also removes the cached Windows install media (forces a fresh
    ~5 GB download on the next run -- omit -ResetISO unless you specifically
    want to test that path).

    Self-elevates to Administrator. Prompts for confirmation before destroying
    anything (skip with -Force).

.PARAMETER ResetISO
    Also delete the cached Windows install media under C:\Tools\WinVHDX so the
    next run re-downloads it. Adds ~10-30 min depending on connection. The
    builder names its download after Microsoft's catalog entry (a long
    .esd filename), so this matches on extension rather than a fixed name --
    which also catches ISOs cached by older VM-Pilot versions.

.PARAMETER Force
    Skip the interactive confirmation prompt. Useful for scripted CI.

.PARAMETER Keep
    Array of VM names to preserve. Default keeps the pre-existing VMs from the
    original test environment. Pass your own list to override.

.EXAMPLE
    PS> .\Reset-VMPilot.ps1
    Wipes all session VMs + parent VHDX + cached community script. Asks first.

.EXAMPLE
    PS> .\Reset-VMPilot.ps1 -ResetISO -Force
    Full nuke including the ISO. No confirmation. Next launch downloads
    everything from scratch.

.EXAMPLE
    PS> .\Reset-VMPilot.ps1 -Keep @('APT','MORR','MyImportantVM')
    Override the preserve list.

.LINK
    https://github.com/markorr321/VM-Pilot
#>
[CmdletBinding()]
param(
    [Alias('ResetMedia')]
    [switch]$ResetISO,
    [switch]$Force,
    [string[]]$Keep = @(
        'APT','AutopilotTest','AutopilotTest-01','AutopilotTest-02',
        'MHO','MHO-24H2-0502-6368','MORR'
    )
)

# ----- Self-elevate -----
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Elevating to Administrator...' -ForegroundColor Yellow
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $argList = @('-NoExit','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($ResetISO) { $argList += '-ResetISO' }
    if ($Force)    { $argList += '-Force' }
    Start-Process $psExe -ArgumentList $argList -Verb RunAs
    return
}

$separator = '=' * 70

# ----- Known paths -----
# One parent VHDX per Windows release (Win11-25H2.vhdx, Win11-24H2.vhdx, ...),
# so glob rather than naming a single file.
$parentVhdx     = @(Get-ChildItem -Path 'C:\VMs\Win11-*.vhdx' -File -ErrorAction SilentlyContinue)
$communityCache = 'C:\Tools\VMPilot\Get-WindowsAutopilotInfoCommunity.ps1'
$mediaDir       = 'C:\Tools\WinVHDX'
# The builder's download is named by Microsoft's catalog (e.g.
# 26200.8653.<...>_CLIENTCONSUMER_RET_x64FRE_en-us.esd), so glob by extension.
# *.iso also sweeps up media cached by VM-Pilot's older Fido-based builder.
$mediaCache     = @(Get-ChildItem -Path $mediaDir -File -Include '*.esd','*.iso' -Recurse -ErrorAction SilentlyContinue)

# ----- Inventory -----
Write-Host "`n$separator" -ForegroundColor Cyan
Write-Host '  VM-Pilot Reset - inventory'        -ForegroundColor Cyan
Write-Host "$separator" -ForegroundColor Cyan

$victims = @(Get-VM | Where-Object { $_.Name -notin $Keep })

Write-Host "`nVMs to REMOVE:" -ForegroundColor Yellow
if ($victims.Count -eq 0) {
    Write-Host '  (none)' -ForegroundColor DarkGray
} else {
    $victims | ForEach-Object { "  - {0,-30} {1}" -f $_.Name, $_.State }
}

Write-Host "`nVMs to KEEP:" -ForegroundColor Green
$kept = @(Get-VM | Where-Object { $_.Name -in $Keep })
if ($kept.Count -eq 0) {
    Write-Host '  (none in keep list exist)' -ForegroundColor DarkGray
} else {
    $kept | ForEach-Object { "  - {0,-30} {1}" -f $_.Name, $_.State }
}

Write-Host "`nFiles to delete:" -ForegroundColor Yellow
$fileActions = @()
foreach ($v in $parentVhdx)    { $fileActions += $v.FullName;     Write-Host "  - $($v.FullName)" }
if (Test-Path $communityCache) { $fileActions += $communityCache; Write-Host "  - $communityCache" }
if ($ResetISO) {
    foreach ($m in $mediaCache) {
        $fileActions += $m.FullName
        Write-Host ("  - {0}   (~{1:N1} GB)" -f $m.FullName, ($m.Length / 1GB)) -ForegroundColor Red
    }
}
if ($fileActions.Count -eq 0) { Write-Host '  (none)' -ForegroundColor DarkGray }

# ----- Confirm -----
if (-not $Force) {
    Write-Host "`nThis cannot be undone." -ForegroundColor Red
    $ans = Read-Host 'Type YES to proceed'
    if ($ans -ne 'YES') {
        Write-Host 'Aborted.' -ForegroundColor Yellow
        return
    }
}

# ----- Remove VMs -----
foreach ($vm in $victims) {
    $n = $vm.Name
    Write-Host "Removing VM '$n'..." -ForegroundColor Yellow
    Stop-VM   -Name $n -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $n -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "C:\VMs\$n" -Recurse -Force -ErrorAction SilentlyContinue
}

# ----- Remove cached files -----
foreach ($f in $fileActions) {
    Write-Host "Deleting $f..." -ForegroundColor Yellow
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
}

# ----- Verify -----
Write-Host "`n$separator" -ForegroundColor Cyan
Write-Host '  Done. Current state:'              -ForegroundColor Cyan
Write-Host "$separator" -ForegroundColor Cyan

Write-Host "`nVMs remaining:" -ForegroundColor Green
Get-VM | Sort-Object Name | Format-Table Name, State, Uptime -AutoSize

Write-Host 'Cache file presence:' -ForegroundColor Green
$vhdxLeft = @(Get-ChildItem -Path 'C:\VMs\Win11-*.vhdx' -File -ErrorAction SilentlyContinue)
"  parent VHDX  : $(if ($vhdxLeft.Count) { ($vhdxLeft.Name -join ', ') } else { 'False' })"
"  community PS : $(Test-Path $communityCache)"
$remaining = @(Get-ChildItem -Path $mediaDir -File -Include '*.esd','*.iso' -Recurse -ErrorAction SilentlyContinue)
"  Windows media: $(if ($remaining.Count) { "$($remaining.Count) file(s) in $mediaDir" } else { 'False' })"

Write-Host "`nReady for a clean VM-Pilot run." -ForegroundColor Green
