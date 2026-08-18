@{
    # ----- Identity -----
    RootModule        = 'VM-Pilot.psm1'
    ModuleVersion     = '0.7.1'
    GUID              = '5a7b4c3d-9e1f-4a2b-8c5d-1e2f3a4b5c6d'
    Author            = 'Mark Orr'
    CompanyName       = 'Mark Orr'
    Copyright         = '(c) Mark Orr. All rights reserved.'
    Description       = 'WPF GUI for spinning up disposable Hyper-V VMs and collecting AutoPilot hardware hashes. Downloads Windows 11 install media (25H2 or 24H2) straight from Microsoft via the OSD module and builds the parent VHDX for you. Offline mode writes a CSV; Online mode drops a single C:\import.bat that installs Get-WindowsAutopilotImportGUICommunity for in-VM Intune import (AutoPilot v1 and v2).'

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
    # and OSD is auto-installed by Get-Win11VHDX.ps1 the first time it has to
    # download install media. Both are intentionally NOT listed as
    # RequiredModules -- that would force the dependency at Import-Module time
    # even for users who never run a VM or who supply their own ISO.

    # ----- Files shipped with the module -----
    FileList = @(
        'VM-Pilot.psm1',
        'VMPilot.GUI.ps1',
        'VMPilotCollect.ps1',
        'Get-Win11VHDX.ps1',
        'Invoke-VMPilotCloudCleanup.ps1',
        'Reset-VMPilot.ps1',
        'VMPilot.bat',
        'README.md',
        'LICENSE'
    )

    # ----- PSGallery metadata -----
    PrivateData = @{
        PSData = @{
            Tags         = @('Hyper-V','AutoPilot','Intune','WPF','VM','Enrollment','HWID','Windows11','OSD','OSDCloud','VHDX','DevicePreparation')
            LicenseUri   = 'https://github.com/markorr321/VM-Pilot/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/markorr321/VM-Pilot'
            ReleaseNotes = @'
0.7.1
- Fix "Build failed: The handle is invalid." on hosts where the BITS service
  is broken or disabled. Start-BitsTransfer now runs inside the try block, so
  any BITS failure (E_HANDLE, service error, failed transfer) falls back to a
  direct download instead of ending the build. Previously the fallback only
  fired when Import-Module BitsTransfer itself failed, which almost never
  happens - so a BITS problem was fatal.
- That fallback is now a streaming HttpClient download that emits the same
  "Download progress: X% (X / X MB)" lines BITS does, so the wizard's progress
  bar keeps working on that path instead of sitting frozen.
- Fix 0x80070006 (E_HANDLE) from Get-Disk during VHDX creation on busy hosts.
  Mount-VHD and Get-Disk are no longer pipelined; a short pause between them
  gives VDS time to publish the disk handle to WMI before it is queried.

0.7.0
- Windows install media is now downloaded for you. VM-Pilot resolves it through
  David Segura's OSD module - the module behind OSDCloud - whose
  Get-FeatureUpdate returns Microsoft's official download URL, filename and
  SHA256 for a given release, channel and language. The SETUP wizard's five
  manual steps (open Microsoft's download page, pick the edition, pick the
  language, save the ISO, come back and browse to it) collapse into a single
  DOWNLOAD & BUILD button. USE EXISTING ISO stays for bring-your-own media, or
  for networks that block the download. OSD is GPL-3.0, installed from the
  PowerShell Gallery on demand, and never bundled here - see LICENSE.
- This retires the Fido resolver, which scraped Microsoft's public download
  page and failed with error 715-123130 whenever that page IP-blocked the
  caller.
- Microsoft's catalog serves an .esd, which is already a Windows image
  container, so the download path hands the file straight to DISM and skips the
  ISO mount entirely. Supplied .iso media still mounts as before, and .esd/.wim
  can now be supplied directly as well.
- Downloads are verified against the catalog's published SHA256 before the
  ~10-minute apply starts, and the file is deleted on mismatch so a re-run
  begins clean. A cached download is reused only while its hash still matches.
  Note: Microsoft publishes a SHA256 for 25H2 but not for 24H2, and the
  delivery CDN is HTTP-only (that host refuses TLS), so a 24H2 download is
  checked for completeness by byte count but cannot be cryptographically
  verified. The builder says so out loud rather than letting silence imply a
  passed check. Prefer 25H2, or supply your own 24H2 media, if that matters.
- 24H2 is selectable again. WIN RELEASE offers 25H2 (default) and 24H2, each
  with its own parent VHDX (C:\VMs\Win11-<release>.vhdx), so the two coexist
  and switching never rebuilds the other. Media from a different release than
  the one selected is rejected instead of quietly building a VHDX the GUI would
  never look for.
- A status dot under the selected release shows whether that release's parent
  VHDX exists, and the SETUP button names the release it will build (SETUP
  25H2 / SETUP 24H2). The "already exists" rebuild warning is scoped to the
  selected release instead of every Win11-*.vhdx.
- Get-Win11VHDX.ps1 gains -OSActivation (Retail by default, or Volume) and
  -OSLanguage to choose which catalog entry to download. The Fido-only
  -Language parameter is gone.
- Fixes: the SETUP wizard left CLOSE disabled after a successful build, so a
  finished wizard could sit stuck open; a BITS transfer reporting
  BG_SIZE_UNKNOWN on its first poll overflowed an [int] and aborted the build
  before any progress appeared; the bottom button row measured 530px inside a
  520px content area, pushing EXIT past the window margin.
- LICENSE now carries a THIRD-PARTY COMPONENTS section spelling out that the
  MIT grant covers VM-Pilot's own code only, and that OSD, HyperV.VMFactory,
  the in-VM import GUI and Microsoft's media are each obtained at runtime,
  under their own licenses, and never redistributed here.

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

Older releases (0.4.x and earlier) are listed at
https://github.com/markorr321/VM-Pilot/releases
'@
        }
    }
}
