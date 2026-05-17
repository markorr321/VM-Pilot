@{
    # ----- Identity -----
    RootModule        = 'VMPilot.psm1'
    ModuleVersion     = '0.1.0'
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
        'VMPilot.psm1',
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
            ReleaseNotes = '0.1.0 - First module-shaped release. Wraps the existing WPF GUI behind Start-VMPilot.'
        }
    }
}
