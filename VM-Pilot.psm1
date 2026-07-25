# VM-Pilot.psm1 -- module entry. For now this just exposes Start-VMPilot, which
# spawns the existing VMPilot.GUI.ps1 in a new (hidden) PowerShell process so
# the GUI's auto-elevation and hidden-console behavior continue to work as
# they do when the user double-clicks VMPilot.bat.
#
# Future work will refactor VMPilot.GUI.ps1 into proper exported functions
# (Get-VMPilotHWID, Remove-VMPilotVM, etc.) for scriptable use without the GUI.

$script:ModuleRoot = $PSScriptRoot

function Get-VMPilotLatestVersion {
    <#
    .SYNOPSIS
        Returns the newest VM-Pilot version published to PowerShell Gallery.
    .DESCRIPTION
        The Gallery's package page 302-redirects to the versioned URL, so the
        Location header carries the latest version -- much faster than
        Find-Module, which pulls a full package record. Returns $null on any
        failure; callers treat that as "don't know, carry on".
    #>
    [CmdletBinding()]
    param([int]$TimeoutSec = 5)

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $url      = 'https://www.powershellgallery.com/packages/VM-Pilot'
    $location = $null
    try {
        # With redirects capped at 0, PowerShell 7 treats the 302 as an error and
        # throws HttpResponseException -- so the Location header has to come off
        # the exception's response, and the normal-return read below is only a
        # guard in case a future build stops throwing. (Windows PowerShell 5.1
        # throws with no .Response at all; this module is PS7-only by manifest.)
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -MaximumRedirection 0 `
                                  -TimeoutSec $TimeoutSec -ErrorAction Stop
        $location = $resp.Headers['Location']
    } catch {
        $r = $_.Exception.Response
        if ($r -and $r.Headers) {
            try { $location = $r.Headers.GetValues('Location') } catch { }
        }
    }

    if ($location -is [array]) { $location = $location | Select-Object -First 1 }
    if ([string]::IsNullOrWhiteSpace($location)) { return $null }

    try { return [version](($location -split '/')[-1]) } catch { return $null }
}

function Show-VMPilotUpdateNotification {
    <#
    .SYNOPSIS
        Prompts to update VM-Pilot, and performs the update when accepted.
    .OUTPUTS
        [bool] $true when the module was updated and the caller should stop
        (the copy on disk is now newer than the one loaded in this session).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][version]$CurrentVersion,
        [Parameter(Mandatory)][version]$LatestVersion
    )

    Write-Host ''
    Write-Host "[!] VM-Pilot update available: $CurrentVersion -> $LatestVersion" -ForegroundColor Red
    Write-Host ''

    $response = Read-Host 'Update now? (Y/N) [Press Enter to skip]'
    if ($response -notmatch '^(y|Y)$') {
        if ($response -match '^(n|N)$') { Write-Host 'Skipping update.' -ForegroundColor Yellow }
        Write-Host ''
        return $false
    }

    Write-Host ''
    Write-Host 'Updating VM-Pilot...' -ForegroundColor Cyan
    try {
        # Update with whichever package manager actually installed the module --
        # mixing them leaves duplicate side-by-side copies.
        $viaPSResource = $null
        if (Get-Command Get-InstalledPSResource -ErrorAction SilentlyContinue) {
            $viaPSResource = Get-InstalledPSResource -Name VM-Pilot -ErrorAction SilentlyContinue
        }
        $viaPowerShellGet = $null
        if (Get-Command Get-InstalledModule -ErrorAction SilentlyContinue) {
            $viaPowerShellGet = Get-InstalledModule -Name VM-Pilot -ErrorAction SilentlyContinue
        }

        if ($viaPSResource) {
            $installPath = ($viaPSResource | Select-Object -First 1).InstalledLocation
            $scope = if ($installPath -match 'Program Files') { 'AllUsers' } else { 'CurrentUser' }
            Update-PSResource -Name VM-Pilot -Scope $scope -Confirm:$false
        }
        elseif ($viaPowerShellGet -or (Get-Command Update-Module -ErrorAction SilentlyContinue)) {
            Update-Module -Name VM-Pilot -Force
        }
        else {
            Write-Host 'No update command available. Install manually with:' -ForegroundColor Yellow
            Write-Host '  Install-Module -Name VM-Pilot -Force' -ForegroundColor Yellow
            Write-Host ''
            return $false
        }
    } catch {
        Write-Host ''
        Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Update manually with:' -ForegroundColor Yellow
        Write-Host '  Update-Module -Name VM-Pilot -Force        (installed via Install-Module)' -ForegroundColor Yellow
        Write-Host '  Update-PSResource -Name VM-Pilot           (installed via Install-PSResource)' -ForegroundColor Yellow
        Write-Host ''
        return $false
    }

    Write-Host ''
    Write-Host 'Update complete!' -ForegroundColor Green
    Write-Host 'Restart PowerShell, then run Start-VMPilot again.' -ForegroundColor Green
    Write-Host ''
    return $true
}

function Test-VMPilotUpdate {
    <#
    .SYNOPSIS
        Checks PowerShell Gallery for a newer VM-Pilot and offers to install it.
    .DESCRIPTION
        Runs on each Start-VMPilot. Every failure path is silent -- a Gallery
        outage or offline host must never block launching the GUI. Set
        $env:VMPILOT_DISABLE_UPDATE_CHECK = 'true' to skip the check entirely.
    .OUTPUTS
        [bool] $true when an update was installed and the caller should stop.
    #>
    [CmdletBinding()]
    param()

    try {
        if ($env:VMPILOT_DISABLE_UPDATE_CHECK -eq 'true') { return $false }

        $current = Get-Module -Name VM-Pilot | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $current) {
            $current = Get-Module -Name VM-Pilot -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        }
        # Running straight from a clone rather than an installed module: nothing
        # to compare against, and Update-Module couldn't service it anyway.
        if (-not $current) { return $false }

        $latest = Get-VMPilotLatestVersion
        if (-not $latest) { return $false }

        if ($current.Version -lt $latest) {
            return (Show-VMPilotUpdateNotification -CurrentVersion $current.Version -LatestVersion $latest)
        }
    } catch { }

    return $false
}

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

    # ===== Update check =====
    # Must run before the GUI spawns: WScript.Shell.Run detaches the GUI and
    # this function returns immediately, so the console prompt has to happen
    # while this session still owns the terminal. Returns $true only when an
    # update was installed -- the module on disk is then newer than the one
    # loaded here, so launching the stale in-memory GUI would be wrong.
    if (Test-VMPilotUpdate) { return }

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
        throw "VMPilot.GUI.ps1 not found at $guiPath. Reinstall the VM-Pilot module."
    }

    # PS7-only module (enforced by the manifest), so the GUI always gets pwsh.
    $psExe = 'pwsh.exe'

    # Use WScript.Shell.Run rather than Start-Process so the console host
    # never paints. Start-Process -WindowStyle Hidden hides the window AFTER
    # it appears, producing a brief flash; .Run(..., 0, ...) tells the shell
    # to create the window in SW_HIDE from the start, so nothing flashes.
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $guiPath
    $wshell  = New-Object -ComObject WScript.Shell
    try {
        [void]$wshell.Run(('"{0}" {1}' -f $psExe, $argLine), 0, $false)
    } finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wshell)
    }
}

Export-ModuleMember -Function Start-VMPilot
