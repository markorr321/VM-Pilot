@{
    # ----- Identity -----
    RootModule        = 'VM-Pilot.psm1'
    ModuleVersion     = '0.1.5'
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
0.1.5
- Fix "Enable Failed: Class not registered" on IT-managed Enterprise
  machines. Switching to a child PowerShell process in 0.1.1 wasn't
  enough — the DISM COM components themselves can be misregistered
  on locked-down boxes, so even the child process hit HRESULT
  0x80040154. Now calls dism.exe directly (native binary, no COM
  dependency) which works regardless of the broken registration.

0.1.4
- Hyper-V startup check is now sub-second on Pro/Enterprise/Education boxes.
  Previously we ran up to three Get-WindowsOptionalFeature lookups against
  DISM (15-45s) before showing the enable dialog. We now trust the OS SKU:
  any non-Home Pro/Enterprise/Education/Workstation/Server edition is
  treated as Disabled (offers to enable) without probing DISM. The actual
  Enable-WindowsOptionalFeature call surfaces any real failure.

0.1.3
- Fix false "Hyper-V Not Available" on Windows 11 Enterprise / Pro / Education
  / Workstation when Get-WindowsOptionalFeature returns empty for the feature
  names we probe. Now also checks the OS SKU via Win32_OperatingSystem and
  trusts that any non-Home Pro/Enterprise/Education/Workstation/Server edition
  can install Hyper-V, even if the DISM feature lookup is inconclusive.

0.1.2
- Drop the WIN RELEASE picker. Microsoft now publishes only the most-recent
  Windows 11 release on their public download page, and Fido's -Rel parameter
  rejects older tokens like '24H2' as 'Invalid Windows release provided.'
- Pull '-Rel Latest' from Fido and pass '-Ed Home/Pro/Edu' (the consolidated
  edition Microsoft now ships). The DISM step still picks Windows 11 Pro
  from the combined install.wim.
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
