@{
    # ----- Identity -----
    RootModule        = 'VM-Pilot.psm1'
    ModuleVersion     = '0.4.0'
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
0.4.0
- 25H2 only. Dropped 24H2 as a selectable Windows 11 release. The WIN
  RELEASE segment is fixed at 25H2, the -Release parameter on the builder
  accepts only 25H2, and Get-Win11VHDX.ps1 rejects a 24H2 (build 26100)
  ISO instead of building a VHDX the GUI would never load.
- Removed the UUP Dump download path and the bundled Get-UUPDumpISO.ps1
  helper. When no cached parent VHDX exists, the GUI now sends you straight
  to the "Get Windows 11 Install Media" wizard: download the official ISO
  from https://www.microsoft.com/en-us/software-download/windows11, then
  build the parent VHDX from it. Once the wizard finishes, the pending VM
  build continues automatically.

0.3.0
- New SETUP wizard (green SETUP button in the host GUI): guided steps to
  download an official Windows 11 multi-edition ISO from Microsoft, then
  builds the parent VHDX from the ISO you pick. Shows live phase status plus
  a real apply percentage (from Expand-WindowsImage's progress stream), then
  prompts "Build your first VM!" and auto-closes on success.
- Get-Win11VHDX.ps1 auto-detects the Windows release from the ISO image
  build (26100 -> 24H2, 26200 -> 25H2) and names the VHDX accordingly
  (C:\VMs\Win11-<release>.vhdx) when -OutVhdx is not pinned. New -PickIso
  switch opens a native file picker.
- Safer rebuilds: the builder refuses to delete a parent VHDX any VM depends
  on (and names the VM) instead of corrupting that VM's differencing disk;
  otherwise it dismounts and retries. The SETUP wizard also warns up front
  if a parent VHDX already exists or has dependent VMs.
- Offline completion now shows where the hardware-hash CSV was saved on the
  host, with an "Open folder" link that selects the file in Explorer.
- Windows PowerShell 5.1 compatibility: all bundled scripts are now UTF-8
  with a BOM, so 5.1 reads them as UTF-8 (no-BOM files were parsed as the
  legacy Windows-1252 codepage, which broke parsing on non-ASCII characters
  like em-dashes). Launch via powershell.exe or pwsh.
- Fix builder-phase progress not advancing: the builder reports phases via
  Write-Host (information stream), so the in-runspace capture was changed
  from 2>&1 (errors only) to *>&1 (all streams).

0.2.0
- New first-time setup dialog. When no cached parent VHDX exists for the
  selected release, the GUI prompts for the ISO source: Download via UUP
  Dump (recommended), or Browse for an existing ISO. UUP Dump uses the
  Windows Update CDN (*.delivery.mp.microsoft.com), which corporate
  firewalls almost never block — solves the "Microsoft software-download
  endpoint is blocked" failure mode hit on locked-down Enterprise networks.
- New bundled Get-UUPDumpISO.ps1 helper. Queries the UUP Dump API,
  downloads the conversion script pack, patches ConvertConfig.ini with
  AutoExit=1 / AddUpdates=0 / ResetBase=0 / SkipWinRE=1 for a fast
  non-interactive build (~15-20 min). Pass -IncludeUpdates if you want
  the full ~60-90 min build with all cumulative updates integrated.
  VM-Pilot's HWID flow doesn't need integrated updates — the hardware
  hash is derived from BIOS/vTPM, not OS state.
- Builder Get-Win11VHDX.ps1 now accepts -IsoPath. If supplied, skips the
  Fido + download flow entirely and DISM-applies the supplied ISO.
- WIN RELEASE picker is back. Per-release VHDX cache
  (C:\VMs\Win11-24H2.vhdx, C:\VMs\Win11-25H2.vhdx) since UUP Dump
  reliably serves both 24H2 and 25H2 (where Fido only offered Latest).
- Real % progress meter during UUP file download (aria2c) and
  install.wim compression (LZX) — no more guessing at 99%.
- In-VM enrollment GUI rebranded as "VM-Pilot" with "AutoPilot Import"
  subtitle, matching the host GUI.
- Hardening: verify DISM apply produced a complete Windows install,
  verify bcdboot wrote real UEFI boot files, suppress Windows automount
  around every Mount-VHD (kills the "format disk in drive X:" popup),
  robust VHDX dismount with retry, kill orphan wimserv/wimlib-imagex
  handles before VM creation, force Drive-first boot order on new VMs.

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
