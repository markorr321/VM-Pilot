# VMPilot.psm1 -- module entry. For now this just exposes Start-VMPilot, which
# spawns the existing VMPilot.GUI.ps1 in a new (hidden) PowerShell process so
# the GUI's auto-elevation and hidden-console behavior continue to work as
# they do when the user double-clicks VMPilot.bat.
#
# Future work will refactor VMPilot.GUI.ps1 into proper exported functions
# (Get-VMPilotHWID, Remove-VMPilotVM, etc.) for scriptable use without the GUI.

$script:ModuleRoot = $PSScriptRoot

function Start-VMPilot {
<#
.SYNOPSIS
    Launch the VM-Pilot host GUI.

.DESCRIPTION
    Opens the dark-themed WPF window for creating a fresh Hyper-V VM and
    collecting its AutoPilot hardware hash. Choose Offline (CSV on disk) or
    Online (Intune AutoPilot import via the community script) mode in the GUI.

    The GUI auto-elevates to Administrator via UAC if needed. The PowerShell
    session that invoked Start-VMPilot is NOT affected -- the GUI runs in a
    separate hidden PowerShell process. This cmdlet returns immediately once
    the GUI has been launched.

.EXAMPLE
    PS> Start-VMPilot

    Opens the host GUI. From there pick a mode + VM name and click the button.

.LINK
    https://github.com/markorr321/VM-Pilot
#>
    [CmdletBinding()]
    param()

    # ===== Pre-req check #1: Hyper-V =====
    # Fires before the GUI process spawns so the user sees console feedback
    # immediately on `Start-VMPilot` (before any UAC popup). The GUI itself
    # repeats this check with a full graphical enable + reboot flow once
    # elevated, but this preview lets the user know what to expect.
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host '[VM-Pilot] Pre-req check: Hyper-V is not enabled on this machine.' -ForegroundColor Yellow
        Write-Host '[VM-Pilot] Launching the GUI — it will request elevation and offer to' -ForegroundColor Yellow
        Write-Host '[VM-Pilot] enable Hyper-V (reboot required) before opening the main window.' -ForegroundColor Yellow
        Write-Host ''
    }

    $guiPath = Join-Path $script:ModuleRoot 'VMPilot.GUI.ps1'
    if (-not (Test-Path $guiPath -PathType Leaf)) {
        throw "VMPilot.GUI.ps1 not found at $guiPath. Reinstall the VMPilot module."
    }

    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    Start-Process -FilePath $psExe -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy','Bypass',
        '-WindowStyle','Hidden',
        '-File',"`"$guiPath`""
    ) | Out-Null
}

Export-ModuleMember -Function Start-VMPilot
