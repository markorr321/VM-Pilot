# VMPilotCollect.ps1 -- runs INSIDE the VM at SetupComplete.cmd (specialize pass).
# Offline collection: writes AutoPilot HWID CSV to C:\HWID then exits so the
# wrapping SetupComplete.cmd can call shutdown.
#
# Adds a "Group Tag" column only when -GroupTag is supplied non-empty.

[CmdletBinding()]
param(
    [string]$GroupTag = ''
)

try {
    if (-not (Test-Path 'C:\HWID')) { New-Item 'C:\HWID' -ItemType Directory -Force | Out-Null }

    $session = New-CimSession
    $serial  = (Get-CimInstance -CimSession $session -ClassName Win32_BIOS).SerialNumber

    $safeSerial = ($serial -replace '[\\/:*?"<>|\s]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safeSerial)) { $safeSerial = $env:COMPUTERNAME }
    $csv = 'C:\HWID\AutoPilotHWID-' + $safeSerial + '.csv'

    $devDetail = Get-CimInstance -CimSession $session -Namespace root/cimv2/mdm/dmmap `
                                 -ClassName MDM_DevDetail_Ext01 `
                                 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
    $hash = $devDetail.DeviceHardwareData

    $row = [ordered]@{
        'Device Serial Number' = $serial
        'Windows Product ID'   = ''
        'Hardware Hash'        = $hash
    }
    if (-not [string]::IsNullOrWhiteSpace($GroupTag)) {
        $row['Group Tag'] = $GroupTag.Trim()
    }

    [PSCustomObject]$row | Export-Csv -Path $csv -NoTypeInformation -Encoding ASCII
    Write-Host "Saved: $csv"
} catch {
    Write-Host "ERROR: $_"
    exit 1
}
