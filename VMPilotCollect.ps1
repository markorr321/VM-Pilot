# VMPilotCollect.ps1 -- runs INSIDE the VM at SetupComplete.cmd (specialize pass).
# Offline collection: writes the AutoPilot CSV to C:\HWID then exits so the
# wrapping SetupComplete.cmd can call shutdown.
#
# Two formats, chosen by the host GUI's AUTOPILOT VERSION toggle:
#
#   v1 (default)  AutoPilotHWID-<serial>.csv
#                 "Device Serial Number","Windows Product ID","Hardware Hash"
#                 plus a "Group Tag" column only when -GroupTag is non-empty.
#
#   v2 -Identifier  AutoPilotID-<serial>.csv
#                 One headerless line: Manufacturer,Model,Serial
#                 This is what Intune's Device preparation "Import device
#                 identifiers" upload expects, and it matches what the community
#                 script produces with -identifier -OutputFile (which strips the
#                 header row). Group Tag does not apply to v2 -- device
#                 preparation targets an Entra security group on the policy.
#
# Both formats come from WMI only, so neither needs network access.

[CmdletBinding()]
param(
    [string]$GroupTag = '',
    [switch]$Identifier
)

try {
    if (-not (Test-Path 'C:\HWID')) { New-Item 'C:\HWID' -ItemType Directory -Force | Out-Null }

    $session = New-CimSession
    $serial  = (Get-CimInstance -CimSession $session -ClassName Win32_BIOS).SerialNumber

    $safeSerial = ($serial -replace '[\\/:*?"<>|\s]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safeSerial)) { $safeSerial = $env:COMPUTERNAME }

    if ($Identifier) {
        $csv = 'C:\HWID\AutoPilotID-' + $safeSerial + '.csv'

        if (-not [string]::IsNullOrWhiteSpace($GroupTag)) {
            Write-Host "NOTE: -GroupTag is ignored for v2 identifier collection."
        }

        # Same normalisation the community script applies before building the
        # triple: '.' and ',' stripped so the CSV can't be split incorrectly.
        $cs    = Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem
        $make  = $cs.Manufacturer.Trim().Replace('.', '').Replace(',', '')
        $model = $cs.Model.Trim().Replace('.', '').Replace(',', '')

        Set-Content -Path $csv -Value "$make,$model,$serial" -Encoding ASCII
        Write-Host "Saved: $csv"
        Write-Host "Identifier: $make,$model,$serial"
    } else {
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
    }
} catch {
    Write-Host "ERROR: $_"
    exit 1
}
