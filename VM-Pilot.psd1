@{
    # ----- Identity -----
    RootModule        = 'VM-Pilot.psm1'
    ModuleVersion     = '0.1.4'
    GUID              = '5a7b4c3d-9e1f-4a2b-8c5d-1e2f3a4b5c6d'
    Author            = 'Mark Orr'
    CompanyName       = 'Mark Orr'
    Copyright         = '(c) Mark Orr. All rights reserved.'
    Description       = 'WPF GUI for spinning up disposable Hyper-V VMs and collecting AutoPilot hardware hashes. Offline mode writes a CSV; Online mode wraps Andrew Taylor''s community AutoPilot script for in-VM Intune import.'

    # ----- Compatibility -----
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop','Core')

    # ----- Exports -----
    FunctionsToExport = @('Start-VMPilot')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # ----- Required modules -----
    # HyperV.VMFactory is auto-installed by the GUI on first run if missing,
    # so it's intentionally NOT listed as RequiredModules (that would force
    # the dependency at Import-Module time even for users who never run a VM).

    # ----- Files shipped with the module -----
    FileList = @(
        'VM-Pilot.psm1',
        'VMPilot.GUI.ps1',
        'VMPilotCollect.ps1',
        'AutopilotEnroll.GUI.ps1',
        'Get-Win11VHDX.ps1',
        'Reset-VMPilot.ps1',
        'VMPilot.bat',
        'README.md'
    )

    # ----- PSGallery metadata -----
    PrivateData = @{
        PSData = @{
            Tags         = @('Hyper-V','AutoPilot','Intune','WPF','VM','Enrollment','HWID')
            LicenseUri   = 'https://github.com/markorr321/VM-Pilot/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/markorr321/VM-Pilot'
            ReleaseNotes = @'
0.1.4
- No console flash on Start-VMPilot or UAC elevation. Switched from
  Start-Process -WindowStyle Hidden (which hides the console after it
  paints, causing a brief flash) to WScript.Shell.Run / Shell.Application
  ShellExecute with show=0 (SW_HIDE from creation). Only the UAC prompt
  itself is visible now.
- Fix "Enable Failed: Class not registered" on IT-managed Enterprise
  machines by calling dism.exe directly instead of the PowerShell
  Enable-WindowsOptionalFeature cmdlet. The PS cmdlet uses DISM COM
  components that can be misregistered on locked-down boxes (HRESULT
  0x80040154); dism.exe is a native binary with no COM dependency.
- Hyper-V startup check is now sub-second on Pro/Enterprise/Education
  boxes. Previously ran up to three Get-WindowsOptionalFeature lookups
  against DISM (15-45s) before showing the enable dialog. Trust the OS
  SKU via Win32_OperatingSystem; any non-Home Pro/Enterprise/Education/
  Workstation/Server edition is treated as Disabled (offers to enable)
  without probing DISM.
- Drop the WIN RELEASE picker. Microsoft now publishes only the most-
  recent Windows 11 release on their public download page, and Fido's
  -Rel parameter rejects older tokens like '24H2' as 'Invalid Windows
  release provided.' Pull '-Rel Latest' from Fido and pass
  '-Ed Home/Pro/Edu' (the consolidated edition Microsoft now ships).
  The DISM step still picks Windows 11 Pro from the combined install.wim.
- Parent VHDX is now cached as C:\VMs\Win11.vhdx (release-agnostic).

0.1.1
- Real % progress bar during the Windows ISO download (BITS-Transfer).
- Hyper-V auto-enable flow on first run with reboot prompt for fresh installs.
- LICENSE file (MIT) so the gallery's License link resolves.
- Builder resolves from the module folder first, then falls back to the
  legacy C:\Tools\WinVHDX path.
- Fido cached outside the module folder so Publish-Module does not bundle it.
- Better error surfacing from Fido (e.g. the 715-123130 IP-block message is
  now shown verbatim instead of "no URL").

0.1.0
- First module-shaped release. Wraps the existing WPF GUI behind Start-VMPilot.
'@
        }
    }
}
