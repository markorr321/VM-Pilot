<#
.SYNOPSIS
  Removes a device's Intune, Windows Autopilot, and Entra ID records, keyed on
  BIOS serial number, using Mark Orr's AutopilotCleanup module (PSGallery).

.DESCRIPTION
  Called by VM-Pilot's VM Cleanup dialog when "Also remove tenant records" is
  ticked, so deleting a local Hyper-V VM also offboards the cloud identity it
  enrolled.

  It hands the serial(s) straight to the module's own orchestrator,
  Invoke-AutopilotCleanup, rather than calling the low-level Remove-* functions
  itself. That matters: the orchestrator resolves each serial across all three
  services (Autopilot -> Intune by serial -> Entra ID by the Autopilot record's
  Azure AD Device ID), deletes them in the dependency-safe order, and then runs
  its monitoring loop in the terminal ("Waiting for 1 of 1 to be removed from
  Intune... removed... Autopilot... Entra ID..."). Driving the Remove-* verbs
  directly does NOT delete from Entra (that function needs the resolved device
  object, not a serial) and skips the monitoring, which is why this defers to
  Invoke-AutopilotCleanup.

  Requires PowerShell 7+ (the AutopilotCleanup manifest pins PowerShellVersion
  7.0), so the GUI launches this in a pwsh child window.

  At the module's action menu, choose [1] Remove records only - the VM is being
  destroyed locally, so there is nothing to wipe.

.EXAMPLE
  pwsh -File .\Invoke-VMPilotCloudCleanup.ps1 -SerialNumber '1234-5678-...'

.EXAMPLE
  # Preview (WhatIf): resolves and reports what would be deleted, deletes nothing.
  pwsh -File .\Invoke-VMPilotCloudCleanup.ps1 -SerialNumber 'A','B' -Preview
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$SerialNumber,
    # Preview only: forwards -WhatIf to Invoke-AutopilotCleanup so nothing is deleted.
    [switch]$Preview
)

$ErrorActionPreference = 'Stop'

# --- PowerShell 7 gate --------------------------------------------------
# The AutopilotCleanup module manifest requires PowerShellVersion 7.0. The GUI
# resolves pwsh before enabling the cloud-cleanup option, but guard here too so
# a manual run under 5.1 fails clearly instead of on an obscure import error.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "This cleanup requires PowerShell 7+ (pwsh). Current: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 2
}

# Normalize: trim, drop blanks, de-dupe.
$serials = $SerialNumber | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique
if (-not $serials) {
    Write-Host "No serial numbers supplied - nothing to remove." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit 0
}

Write-Host ""
Write-Host "VM-Pilot - Tenant record cleanup (Intune / Autopilot / Entra ID)" -ForegroundColor Cyan
Write-Host ("Devices ({0}): {1}" -f $serials.Count, ($serials -join ', '))
if ($Preview) { Write-Host "PREVIEW MODE - nothing will be deleted." -ForegroundColor Yellow }
Write-Host ""
Write-Host "At the action menu below, choose [1] Remove records only." -ForegroundColor Yellow
Write-Host "(The VM is being deleted locally, so there is no need to wipe.)" -ForegroundColor DarkGray
Write-Host ""

# --- Ensure the AutopilotCleanup module ---------------------------------
if (-not (Get-Module -ListAvailable -Name AutopilotCleanup)) {
    Write-Host "Installing AutopilotCleanup module from PSGallery (first run)..." -ForegroundColor Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        Install-Module AutopilotCleanup -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    } catch {
        Write-Host "Failed to install AutopilotCleanup: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Press Enter to close"
        exit 3
    }
}
Import-Module AutopilotCleanup -Force -ErrorAction Stop

# --- Hand off to the module's monitored flow ----------------------------
# Invoke-AutopilotCleanup connects to Graph (interactive sign-in, Intune admin
# required), enriches each serial across all three services, deletes, and then
# monitors removal in this terminal until each service confirms the record is
# gone. -WhatIf drives its preview path.
try {
    if ($Preview) {
        Invoke-AutopilotCleanup -SerialNumber $serials -WhatIf
    } else {
        Invoke-AutopilotCleanup -SerialNumber $serials
    }
} catch {
    Write-Host ""
    Write-Host "Cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 4
}

Write-Host ""
Read-Host "Press Enter to close"
