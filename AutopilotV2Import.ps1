# AutopilotV2Import.ps1 -- runs INSIDE the VM at OOBE.
# Autopilot v2 (Device preparation) import.
#
# Launched by C:\importv2.bat from the OOBE Shift+F10 cmd prompt.
#
# Autopilot v2 does NOT use a hardware hash. It imports a *device identifier*
# -- the "Manufacturer,Model,Serial" triple -- into
# Intune > Devices > Enrollment > Device preparation policies (Graph:
# deviceManagement/importedDeviceIdentities). The community script does this
# with:  Get-WindowsAutopilotInfoCommunity.ps1 -identifier -Online
#
# Group Tag / Assigned User do NOT apply to identifier imports -- v2 assigns
# devices via an Entra security group on the Device preparation policy, not via
# a per-device profile. Add this VM's device object to that group after import.
#
# Prefers the copy of the community script VM-Pilot pre-injected at C:\ so the
# import works even if PSGallery is unreachable; falls back to Install-Script.

[CmdletBinding()]
param(
    [string]$ScriptPath = 'C:\Get-WindowsAutopilotInfoCommunity.ps1'
)

$Host.UI.RawUI.WindowTitle = 'VM-Pilot - AutoPilot v2 (Device Preparation) Import'

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }

try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Show what will be imported -- this is exactly the triple the community
    # script sends, with '.' and ',' stripped from make/model the same way.
    $cs     = Get-CimInstance -ClassName Win32_ComputerSystem
    $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
    $make   = $cs.Manufacturer.Trim().Replace('.', '').Replace(',', '')
    $model  = $cs.Model.Trim().Replace('.', '').Replace(',', '')

    Write-Host ''
    Write-Host ' VM-Pilot - AutoPilot v2 / Device Preparation import' -ForegroundColor White
    Write-Host " Device identifier: $make,$model,$serial" -ForegroundColor Gray
    Write-Host ''

    if (-not (Test-Path $ScriptPath -PathType Leaf)) {
        Write-Step 'Community script not pre-injected - installing from PSGallery…'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Script -Name Get-WindowsAutopilotInfoCommunity -Force -Scope AllUsers -Confirm:$false

        $installed = Get-InstalledScript -Name Get-WindowsAutopilotInfoCommunity -ErrorAction SilentlyContinue
        if ($installed) {
            $ScriptPath = Join-Path $installed.InstalledLocation 'Get-WindowsAutopilotInfoCommunity.ps1'
        }
        if (-not (Test-Path $ScriptPath -PathType Leaf)) {
            throw "Could not locate Get-WindowsAutopilotInfoCommunity.ps1 after install."
        }
    }

    Write-Step 'Importing device identifier into your tenant…'
    Write-Host '    A Microsoft sign-in prompt will appear. Sign in with an account that can' -ForegroundColor Gray
    Write-Host '    manage Autopilot / Intune enrollment.' -ForegroundColor Gray
    Write-Host ''

    # -identifier = import Manufacturer,Model,Serial (v2) instead of the hash (v1)
    # -Online     = push it straight to the tenant
    & $ScriptPath -identifier -Online

    Write-Host ''
    Write-Host ' Import finished.' -ForegroundColor Green
    Write-Host ' Next: add this device to the Entra security group targeted by your' -ForegroundColor Gray
    Write-Host ' Device preparation policy, then reboot the VM to restart OOBE.' -ForegroundColor Gray
} catch {
    Write-Host ''
    Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ''
Read-Host 'Press Enter to close'
