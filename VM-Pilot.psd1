@{
    # ----- Identity -----
    RootModule        = 'VM-Pilot.psm1'
    ModuleVersion     = '0.6.0'
    GUID              = '5a7b4c3d-9e1f-4a2b-8c5d-1e2f3a4b5c6d'
    Author            = 'Mark Orr'
    CompanyName       = 'Mark Orr'
    Copyright         = '(c) Mark Orr. All rights reserved.'
    Description       = 'WPF GUI for spinning up disposable Hyper-V VMs and collecting AutoPilot hardware hashes. Offline mode writes a CSV; Online mode drops a single C:\import.bat that installs Get-WindowsAutopilotImportGUICommunity for in-VM Intune import (AutoPilot v1 and v2).'

    # ----- Compatibility -----
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')

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
        'Get-Win11VHDX.ps1',
        'Invoke-VMPilotCloudCleanup.ps1',
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
0.6.0
- Every window now draws from one shared dark ResourceDictionary, ported from
  Get-WindowsAutopilotImportGUICommunity's Dark.xaml so the two tools match.
  The seven [System.Windows.MessageBox] prompts - light-grey system boxes in a
  dark app - are replaced by a themed Show-VMPilotDialog with an optional
  selectable monospaced detail block, so a VM list, a path or a dism error can
  be copied out of the prompt instead of retyped. Destructive confirms get an
  outlined red button, Esc cancels, Enter confirms. The VM Cleanup dialog, the
  ISO wizard and the Hyper-V enable prompts pick up the same buttons, check
  boxes, list rows and scrollbars.
- Online mode now injects ONE entry point: C:\import.bat. It replaces
  C:\importv1.bat and C:\importv2.bat. Run it from the OOBE Shift+F10 prompt;
  it primes NuGet, trusts PSGallery, installs the
  Get-WindowsAutopilotImportGUICommunity script from the PowerShell Gallery,
  and launches it. That single self-contained GUI covers both Autopilot v1
  (hardware hash, Group Tag, Assigned User, profile-assignment poll, reboot
  into enrollment) and v2 (Device preparation identifier), so you pick the
  version in the VM instead of picking a .bat.
- Because the import GUI ships from the Gallery, VM-Pilot no longer downloads
  Andrew Taylor's community script on the host, no longer caches it at
  C:\Tools\VMPilot, and no longer injects it (or the bundled
  AutopilotEnroll.GUI.ps1 / AutopilotV2Import.ps1, both removed) into each
  VHDX. VM builds are faster and the host needs no internet for Online mode.
  The VM does: C:\import.bat installs from the Gallery on first run.
- Offline mode is unchanged.

0.5.0
- VM-Pilot now requires PowerShell 7. The manifest declares PowerShellVersion
  7.0 / CompatiblePSEditions Core, so importing under Windows PowerShell 5.1
  fails immediately with a clear message instead of misbehaving later.
  VMPilot.bat no longer falls back to powershell.exe - it reports that pwsh is
  missing and how to install it. The in-VM scripts still target the 5.1 that
  ships in the Windows image, since VMs have no pwsh.
- Start-VMPilot checks PowerShell Gallery for a newer version on each run and
  offers to install it, matching the Entra-PIM behaviour. It reads the version
  from the Gallery page's redirect (~350 ms) rather than Find-Module, updates
  with Update-PSResource or Update-Module to match however the module was
  installed, and asks before doing anything. Every failure path is silent, so
  an offline host or Gallery outage never blocks the GUI. Set
  $env:VMPILOT_DISABLE_UPDATE_CHECK = 'true' to skip the check. The prompt runs
  before the GUI process spawns, because Start-VMPilot detaches the GUI and
  returns immediately - there is no console to prompt on afterwards.
- The offline output folder is renamed C:\Autopilot HWID Collection ->
  C:\Autopilot CSV Collection, since it now holds identifier CSVs as well as
  hash CSVs. Existing files in the old folder are left where they are.
- Offline mode gains an AUTOPILOT VERSION toggle: "v1 Hash" (unchanged) or
  "v2 Identifier", which collects Manufacturer,Model,Serial to
  C:\HWID\AutoPilotID-<serial>.csv inside the VM and copies it back to the same
  host folder. The file is headerless, matching the format Intune's Device
  preparation "Import device identifiers" upload expects. Group Tag hides for
  v2 since it does not apply, and the button reads COLLECT IDENTIFIER. Both
  formats are WMI-only, so v2 needs no network in the VM.
- Online mode now also injects C:\importv2.bat for Autopilot v2 (Device
  preparation). It runs the bundled AutopilotV2Import.ps1, which calls the
  community script with -identifier -Online to import the device identifier
  (Manufacturer,Model,Serial) instead of a hardware hash. Group Tag and
  Assigned User do not apply to v2 - add the device to the Entra security
  group targeted by your Device preparation policy after importing.
- The v1 entry point is renamed C:\import.bat -> C:\importv1.bat so the two
  flows read as a pair. Its behaviour (hash upload, Group Tag / Assigned User,
  profile-assignment poll, reboot into enrollment) is unchanged. VMs built by
  earlier versions still have the old C:\import.bat name.
- CLEANUP VMs can now offboard tenant records. A new "Also remove records
  from Intune / Autopilot / Entra ID (by serial)" checkbox in the VM Cleanup
  dialog deletes each removed VM's cloud identity at the same time as the
  local VM (or the local VM alone if left unchecked). It reads each VM's BIOS
  serial before deletion - the same serial Autopilot registered.
- New bundled Invoke-VMPilotCloudCleanup.ps1 runner. It hands the serial(s) to
  Mark Orr's AutopilotCleanup module (PSGallery) via its Invoke-AutopilotCleanup
  orchestrator, which resolves each serial across all three services (Autopilot
  -> Intune by serial -> Entra ID by the Autopilot record's Azure AD Device ID),
  deletes in the dependency-safe order, and then MONITORS removal live in the
  terminal until each service confirms the record is gone. Choose [1] Remove
  records only at the module's menu - the VM is destroyed locally, so there is
  nothing to wipe. A device missing from a service is a benign no-op (e.g. an
  Offline VM whose CSV was never imported).
- Because AutopilotCleanup requires PowerShell 7, the GUI launches the runner in
  a pwsh window that signs in to Microsoft Graph (Intune admin required). The
  checkbox is disabled with a note if pwsh 7 is not installed.

0.4.2
- Fix VHDX apply progress bar stuck at 0%. The previous approach read
  ImageSize from Get-WindowsImage to calculate a denominator for volume-
  usage polling, but ImageSize returns 0 for ESD files (all modern Windows
  11 ISOs), so the GUI bar never moved. Replaced Expand-WindowsImage and
  the DispatcherTimer volume-poller with a direct dism.exe /Apply-Image
  call that streams its own CR-delimited progress output. The builder now
  emits real 0-100% progress lines that the GUI pipeline consumes directly,
  with no dependency on image metadata or disk polling.

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

Older releases (0.1.x) are listed at
https://github.com/markorr321/VM-Pilot/releases
'@
        }
    }
}
