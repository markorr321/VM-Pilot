# VM-Pilot

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/VM-Pilot?label=PowerShell%20Gallery&labelColor=555&color=0078D4)](https://www.powershellgallery.com/packages/VM-Pilot)
[![downloads](https://img.shields.io/powershellgallery/dt/VM-Pilot?label=downloads&labelColor=555&color=blue)](https://www.powershellgallery.com/packages/VM-Pilot)
[![PowerShell](https://img.shields.io/badge/PowerShell-7%2B-5391FE?labelColor=555)](https://aka.ms/powershell)
[![License](https://img.shields.io/badge/License-MIT-brightgreen?labelColor=555)](LICENSE)

> Published on the [PowerShell Gallery](https://www.powershellgallery.com/packages/VM-Pilot).
> Install with `Install-Module -Name VM-Pilot`.

WPF GUI for spinning up disposable Hyper-V VMs and collecting AutoPilot hardware
hashes — either as a CSV on disk (Offline) or imported directly into Intune
AutoPilot from inside the VM via the `Get-WindowsAutopilotImportGUICommunity`
GUI, which fronts Andrew Taylor's community script (Online).

## What it does

On first launch, VM-Pilot checks Hyper-V is enabled (and offers to enable
it + reboot if not). Then a single button-click in the host GUI:

1. **Builds** a Windows 11 **25H2** parent VHDX (one-time, cached) via
   the bundled `Get-Win11VHDX.ps1` so you don't supply or maintain a template.
2. **Creates** a differencing-disk child VM in Hyper-V via the
   `HyperV.VMFactory` PowerShell module — Gen 2, Secure Boot, vTPM, Default Switch.
3. **Injects** mode-specific payload into the child VHDX *before* first boot.
4. **Boots** the VM and opens vmconnect.

What happens next depends on mode:

### Offline mode (CSV)

An **AUTOPILOT VERSION** toggle picks what gets collected. Both formats come
from WMI only, so neither needs network access inside the VM.

| Toggle | File written in the VM | Contents |
| ------ | ---------------------- | -------- |
| **v1 Hash** (default) | `C:\HWID\AutoPilotHWID-<serial>.csv` | `Device Serial Number,Windows Product ID,Hardware Hash`, plus a **`Group Tag`** column when you fill the host field in |
| **v2 Identifier** | `C:\HWID\AutoPilotID-<serial>.csv` | One headerless line: `Manufacturer,Model,Serial` |

- `VMPilotCollect.ps1` runs as `SetupComplete.cmd` (specialize pass, SYSTEM
  context, before OOBE) — with `-Identifier` appended for v2.
- v1 queries `Win32_BIOS` + `MDM_DevDetail_Ext01` (the hash class needs the
  SYSTEM context this pass provides). v2 queries `Win32_BIOS` +
  `Win32_ComputerSystem`, stripping `.` and `,` from make/model the same way
  the community script does.
- The v2 file is headerless on purpose: that's the format Intune's Device
  preparation **Import device identifiers** upload expects, and it matches
  `Get-WindowsAutopilotInfoCommunity.ps1 -identifier -OutputFile`. **Group Tag
  does not apply to v2** — the field hides when you select it, since device
  preparation targets an Entra security group on the policy instead.
- VM self-shuts-down via `shutdown /s /f /t 5`.
- Host polls for VM `Off`, mounts the child VHDX read-only via a folder
  access path (avoids Windows auto-opening Explorer), copies the newest
  matching CSV to `C:\Autopilot CSV Collection\`, dismounts, restarts the VM.

### Online mode (Intune AutoPilot import)

- VM lands at the **OOBE region screen** and **never leaves OOBE state**.
- VM-Pilot injects a **single** entry point: **`C:\import.bat`**.
- You press **`Shift+F10`** in vmconnect and run **`C:\import.bat`**. It primes
  the NuGet provider, trusts PSGallery, then installs and launches
  [`Get-WindowsAutopilotImportGUICommunity`](https://www.powershellgallery.com/packages/Get-WindowsAutopilotImportGUICommunity)
  from the PowerShell Gallery (first run only — the VM needs internet).
- That script is a single self-contained dark WPF window fronting Andrew
  Taylor's community AutoPilot engine, and it covers **both** registration
  modes, so you pick v1 or v2 *in the VM* rather than picking a `.bat`:

| Mode in the GUI | Flow | What gets imported |
| --- | ---- | ------------------ |
| **v1** | AutoPilot v1 (profile-based) | Hardware hash, + optional Group Tag / Assigned User, waits for profile assignment, reboots into enrollment |
| **v2** | AutoPilot v2 (Device preparation) | Device identifier `Manufacturer,Model,Serial` |

- A Microsoft sign-in browser opens *inside the VM*. Sign in with an
  Intune admin account (the script will request the right Graph scopes
  on first use).
- **v1:** uploads the hash, polls `state.deviceImportStatus` until `complete`,
  triggers AutoPilot sync, polls `deploymentProfileAssignmentStatus` until
  `assigned`, then reboots. Because OOBE was never completed, the reboot
  returns to OOBE → AutoPilot detects the now-assigned profile and self-enrolls
  the device.
- **v2:** posts the identifier to `deviceManagement/importedDeviceIdentities`.
  **Group Tag / Assigned User do not apply** — device preparation targets an
  Entra security group on the policy, so add the VM's device object to that
  group after the import, then reboot the VM to restart OOBE.

## Repo contents

| File                          | Purpose                                                                       |
| ----------------------------- | ----------------------------------------------------------------------------- |
| `VM-Pilot.psd1`               | PowerShell module manifest. Identity, exports, PSGallery metadata. |
| `VM-Pilot.psm1`               | Module entry. Exposes the `Start-VMPilot` cmdlet. |
| `VMPilot.GUI.ps1`             | The host WPF GUI. Dark theme, segmented controls, status + progress + completion. Every window (main, prompts, VM Cleanup, ISO wizard) is built from one shared ResourceDictionary — see [Theme](#theme). |
| `VMPilot.bat`                 | Thin launcher for double-click use. Auto-elevates and starts the GUI hidden. |
| `Get-Win11VHDX.ps1`           | Builder. Downloads Windows 11 media from Microsoft (via the [OSD](https://github.com/OSDeploy/OSD) module's Feature Update catalog), SHA256-verifies it, and DISM-applies it to a GPT/UEFI VHDX. Accepts `-IsoPath` / `-PickIso` to use your own media instead. Auto-names the VHDX after the release detected inside the image when `-OutVhdx` isn't pinned, and refuses to overwrite a parent any VM still depends on. |
| `VMPilotCollect.ps1`          | Offline: runs inside the VM at specialize. Writes the v1 hash CSV (optional Group Tag column) or, with `-Identifier`, the v2 `Manufacturer,Model,Serial` CSV. |
| `Invoke-VMPilotCloudCleanup.ps1` | Runner behind the VM Cleanup dialog's **Also remove tenant records** option. Hands the VMs' BIOS serials to the `AutopilotCleanup` module's `Invoke-AutopilotCleanup` in a PowerShell 7 window — see [Removing tenant records](#removing-tenant-records-cleanup-vms). `-Preview` resolves and reports without deleting. |
| `Reset-VMPilot.ps1`           | Standalone cleanup utility. Wipes test VMs, parent VHDX, and any cached community script for a clean re-run. |
| `LICENSE`                     | MIT.                                                                          |
| `README.md`                   | This file.                                                                    |

## Prerequisites

- **Windows 10/11 host** with the Hyper-V role and Hyper-V Manager installed.
- **Administrator** rights (the launcher auto-elevates via UAC).
- **PowerShell 7+** (`pwsh.exe`) preferred; **Windows PowerShell 5.1**
  (`powershell.exe`) also supported. See the [PowerShell 5.1 vs 7](#powershell-51-vs-7)
  note below.
- **`HyperV.VMFactory`** PowerShell module — auto-installed from PSGallery on
  first run (`Install-Module -Scope CurrentUser`).
- **[`OSD`](https://github.com/OSDeploy/OSD)** PowerShell module by **David
  Segura** (the module behind **OSDCloud**) — auto-installed from PSGallery the
  first time media is downloaded (`Install-Module -Scope CurrentUser`). Supplies
  Microsoft's Feature Update catalog, which is how VM-Pilot resolves an official
  download URL + SHA256 without scraping anything. GPL-3.0.
- **Parent VHDX** — built automatically on first use, one per Windows release.
  When no cached `C:\VMs\Win11-<release>.vhdx` exists for the release selected
  under **WIN RELEASE**, the GUI opens the **Get Windows 11 Install Media**
  wizard:
  - Click **DOWNLOAD & BUILD**. VM-Pilot resolves the official media for that
    release from Microsoft's Feature Update catalog, downloads it from
    `dl.delivery.mp.microsoft.com` (~4–6 GB, live percentage), verifies it
    against Microsoft's published SHA256 where one is available (see
    [Release support](#release-support)), and DISM-applies it to
    `C:\VMs\Win11-<release>.vhdx`.
  - Already have media? **USE EXISTING ISO** opens a file picker and skips
    the download. Media from a different release than the one selected is
    rejected rather than silently building the wrong parent.
  - Once the wizard finishes, the pending VM build continues automatically.
  You can also open this wizard any time with the green **SETUP** button to
  pre-build a parent VHDX. Each release's VHDX is built once and reused, and
  25H2 and 24H2 parents coexist — switching **WIN RELEASE** never rebuilds
  the other.
- **Internet** — once at first build to download the Windows 11 media,
  and from inside the VM during Online enrollment so it can
  reach Microsoft Graph.
- **Intune admin account** (Online mode only) with consent for
  `Device.ReadWrite.All`, `DeviceManagementManagedDevices.ReadWrite.All`,
  `DeviceManagementServiceConfig.ReadWrite.All`, and
  `DeviceManagementScripts.ReadWrite.All`.

## Licensing & redistribution

VM-Pilot is MIT-licensed code that **does not include or redistribute any
Microsoft software**. The install media is fetched on your machine, over your
connection, directly from Microsoft's own delivery CDN
(`dl.delivery.mp.microsoft.com`) — the URL comes from Microsoft's Feature
Update catalog, surfaced by David Segura's [OSD](https://github.com/OSDeploy/OSD)
module (GPL-3.0), which VM-Pilot installs from PSGallery at runtime rather than
bundling. `Get-Win11VHDX.ps1` then DISM-applies that image to a local VHDX.
Microsoft sees you as the downloader, not VM-Pilot or this repo. Nothing is
mirrored, re-hosted, or bundled. (On download integrity, see
[Release support](#release-support) — the CDN is HTTP-only, so the SHA256 check
is what makes 25H2 the safer default.)

You are responsible for ensuring your Windows licensing covers the VMs you
create. For short-lived test/eval VMs that exist only long enough to grab a
hardware hash, unactivated Windows is what Microsoft offers for exactly this
kind of usage. For longer-lived VMs or production deployments, apply a key
per your normal licensing agreement (retail, OEM, volume, MSDN, etc.).

**Do not** publish or share the cached `Win11-*.vhdx` files this tool
generates — they contain a Microsoft Windows installation and redistributing
them is a EULA violation. They are gitignored for that reason.

## Install + launch

### From PSGallery (recommended)

```powershell
Install-Module VM-Pilot -Scope CurrentUser
Start-VMPilot
```

`Start-VMPilot` runs a fast Hyper-V pre-req check, then spawns the WPF GUI
in a hidden, auto-elevated process. If Hyper-V isn't enabled, the GUI
shows a dark dialog offering to enable it (admin + reboot required) before
opening the main window.

### From source (for development)

```powershell
git clone https://github.com/markorr321/VM-Pilot.git
cd VM-Pilot
.\VMPilot.bat
```

`VMPilot.bat` triggers a UAC prompt, launches the GUI hidden of any
console window, then the host workflow takes over. Equivalent to
`Start-VMPilot` for users who prefer double-click.

## Host GUI controls

| Field                                  | Notes                                                                  |
| -------------------------------------- | ---------------------------------------------------------------------- |
| **MODE** — Offline / Online            | Selects which payload to inject into the VM.                            |
| **WIN RELEASE** — 25H2 / 24H2          | Windows 11 release the VM is built from. Each has its own cached parent VHDX (`C:\VMs\Win11-<release>.vhdx`) and they coexist, so switching is free once both are built. Defaults to 25H2. |
| **VM NAME**                            | Hyper-V VM name. Must not collide with an existing VM.                   |
| **CPU CORES** — 1 / 2 / 4              | Defaults to 2. Bump to 4 for faster boot.                                 |
| **RAM (GB)** — 4 / 8 / 16              | Defaults to 4. Bump to 8 for faster boot.                                 |
| **GROUP TAG** *(Offline only)*         | Optional. Adds a `Group Tag` column to the CSV. Leave blank to omit.   |
| **COLLECT HWID** / **COLLECT & UPLOAD** | Label changes with mode. Kicks off the run.                            |
| **OPEN AUTOPILOT** *(bottom-left)*     | Launches the Intune AutoPilot Devices page in your default browser.    |
| **SETUP** *(bottom, green)*            | Opens the **Get Windows 11 Install Media** wizard: **DOWNLOAD & BUILD** pulls official 25H2 media from Microsoft and builds the parent VHDX end to end (live download + apply percentages, auto-named by the release inside the image); **USE EXISTING ISO** does the same from media you already have. Warns first if a parent VHDX already exists or a VM depends on it. |
| **CLEANUP VMs** *(bottom-right, red)*  | Opens a dialog listing every Hyper-V VM with per-row checkboxes plus Remove Selected / Remove All buttons. Each removal stops the VM, deletes it, and wipes its `C:\VMs\<name>` folder. An optional **Also remove records from Intune / Autopilot / Entra ID** checkbox additionally offboards each removed VM's cloud identity (records-only, keyed on BIOS serial) — see [Removing tenant records](#removing-tenant-records-cleanup-vms). |
| **EXIT** *(bottom-right, gray)*        | Closes the GUI.                                                         |

Status text and an indeterminate progress bar show what stage you're at.
On success, the run renders a centered **Complete** in green plus a
**DEVICE SERIAL** block — the serial is auto-copied to your clipboard
ready to paste. In Offline mode it also shows a **HARDWARE HASH SAVED TO**
block with the full CSV path and an **Open folder** link that opens
Explorer with the file selected. Errors render in red in the same slot.

## First-run behavior

- **Hyper-V not enabled** — `Start-VMPilot` prints a yellow console notice,
  then the GUI shows a dialog: **Hyper-V Required — Enable it now?** Clicking
  **ENABLE HYPER-V** runs `dism.exe` in the background (1–3 minutes with an
  animated progress bar), then a **Reboot Required** dialog. After reboot,
  run `Start-VMPilot` again and the check passes silently.
- **First click of COLLECT HWID** — if no cached parent VHDX exists for the
  selected **WIN RELEASE** (`C:\VMs\Win11-<release>.vhdx`), the **Get Windows
  11 Install Media** wizard opens. **DOWNLOAD & BUILD** handles it end to end:
  ~10-30 min for the media download (live percentage) plus ~5-10 min for the
  apply. When it finishes, the VM build continues automatically. Each
  release's parent VHDX is built once and cached, and the downloaded media is
  kept under `C:\Tools\WinVHDX` so a rebuild never re-downloads.
- **First Online run** — the host downloads nothing extra; the import GUI is
  installed from the PowerShell Gallery *inside the VM* the first time you run
  `C:\import.bat`.
- **Every subsequent run** — the parent VHDX is reused. VM creation + boot is
  the only time spent (~5-10 min total per VM).

## Building media manually (SETUP)

The green **SETUP** button is an on-demand alternative to the auto-triggered
build dialog — useful for pre-building a parent VHDX ahead of time.

1. Click **SETUP** → the **Get Windows 11 Install Media** wizard opens.
2. Click **DOWNLOAD & BUILD** and watch the live status: *Resolving media
   from Microsoft… → Downloading… NN% (n / n MB) → Verifying download
   (SHA256)… → Detected Windows 11 25H2 → Applying Windows image… NN% →
   Writing UEFI… → Finalizing*.
3. The VHDX is named for the release inside the image
   (`C:\VMs\Win11-25H2.vhdx`). On success the wizard shows **Build your first
   VM!** and closes itself.

The wizard builds whichever release is selected under **WIN RELEASE** in the
main window — its title and steps name that release, and its "already exists"
warning is scoped to that release's parent only.

Prefer to supply your own media — because you already have an ISO, or because
your network blocks the download — click **USE EXISTING ISO** instead, pick
the file, and the wizard skips straight to the apply. `.iso` is mounted;
a `.esd`/`.wim` is applied directly. Media whose release doesn't match the
selected one is rejected, so you can't accidentally build a 24H2 parent while
25H2 is selected.

From the CLI the same paths are:

```powershell
.\Get-Win11VHDX.ps1                          # download 25H2 + build
.\Get-Win11VHDX.ps1 -Release 24H2            # download 24H2 + build
.\Get-Win11VHDX.ps1 -PickIso                 # file picker, then build
.\Get-Win11VHDX.ps1 -IsoPath D:\Win11.iso    # explicit media, then build
```

`-OSActivation Retail|Volume` (default `Retail`) and `-OSLanguage en-us`
select which catalog entry to download.

### Release support

| Release | Build | Catalog SHA256 | Parent VHDX |
| ------- | ----- | -------------- | ----------- |
| 25H2 *(default)* | 26200 | ✅ published — download is hash-verified | `C:\VMs\Win11-25H2.vhdx` |
| 24H2 | 26100 | ❌ not published — download **cannot** be hash-verified | `C:\VMs\Win11-24H2.vhdx` |

Microsoft's Feature Update catalog currently carries a SHA256 for 25H2 but not
for 24H2. When no hash is available the builder says so explicitly rather than
letting silence imply a passed check.

**This is worth understanding before picking 24H2.** The catalog hands out
`http://dl.delivery.mp.microsoft.com/...` URLs — plain HTTP, and that host does
not answer on HTTPS, so the URL cannot simply be upgraded. For 25H2 that's
fine: the SHA256 is fetched over HTTPS from the catalog and checked against the
downloaded bytes, so a tampered transfer is caught. For **24H2 there is no such
check** — the builder verifies only that the byte count matches what the server
promised, which catches a truncated download but nothing malicious.

If that matters to you, prefer 25H2, or supply your own 24H2 media via
**USE EXISTING ISO** / `-IsoPath`.

If a parent VHDX already exists, SETUP warns before doing anything and names
any VMs that depend on it (which must be removed via **CLEANUP VMs** before a
rebuild can replace the parent).

## In-VM enrollment GUI (Online only)

Once the VM is booted and at OOBE region screen:

1. Press **`Shift+F10`** to open a command prompt.
2. Run **`C:\import.bat`**. On first run it installs
   `Get-WindowsAutopilotImportGUICommunity` from the PowerShell Gallery
   (needs internet in the VM), then launches it.
3. A dark **Autopilot import** window appears with the device serial, the
   **v1 / v2** mode picker, and (v1 only) optional Group Tag and Assigned
   User UPN fields.
4. Pick the mode and start the registration. Live staged progress runs in the
   window; a Microsoft sign-in browser will open — sign in with your Intune
   admin.
5. **v1:** watch the upload + assignment poll. When the script reboots the VM,
   AutoPilot picks up the assigned profile on the next OOBE boot and enrolls
   the device end-to-end without further interaction.
   **v2:** the device identifier is imported; add the device to the Entra
   security group targeted by your Device preparation policy, then reboot the
   VM to restart OOBE.

## Removing tenant records (CLEANUP VMs)

A VM you enrolled in **Online** mode leaves records behind in your tenant —
an Intune managed device, a Windows Autopilot device identity, and an Entra ID
device object — all keyed on the device **serial number**. The **CLEANUP VMs**
dialog can delete those at the same time it removes the local VM:

1. Check the VMs to remove (or use **REMOVE ALL**).
2. Tick **Also remove records from Intune / Autopilot / Entra ID (by serial)**.
   Leave it unchecked to remove the VM locally only.
3. Confirm. VM-Pilot reads each VM's BIOS serial *before* deleting it (the same
   serial Autopilot registered), removes the VM locally, then opens a
   **PowerShell 7** window running `Invoke-VMPilotCloudCleanup.ps1`, which calls
   the `AutopilotCleanup` module's `Invoke-AutopilotCleanup` against those
   serials. At its action menu, choose **[1] Remove records only**.
4. The module signs you in to Microsoft Graph, resolves each serial across all
   three services (Autopilot → Intune → Entra ID), deletes in order, then
   **monitors** removal live in the terminal (*Waiting for 1 of 1 to be removed
   from Intune… ✓ removed…*) until each service confirms the record is gone.

Notes:

- **Records-only, never a wipe.** The VM is being destroyed locally, so there's
  nothing to wipe — pick **[1]** at the menu, not the WIPE options.
- **Why the module's own flow?** Entra ID devices aren't queryable by hardware
  serial (the serial lives in `physicalIds`), so the record is resolved via the
  Autopilot device's Azure AD Device ID. `Invoke-AutopilotCleanup` does that
  resolution and the monitoring; driving the low-level `Remove-*` verbs by
  serial alone would not delete the Entra object.
- **Missing records are a no-op.** An Offline VM whose CSV you never imported
  has no cloud records, so its serial simply reports *not found* per service.
- **Requires PowerShell 7 (`pwsh`)** and the `AutopilotCleanup` module
  (auto-installed from PSGallery on first use). If `pwsh` isn't installed, the
  checkbox is disabled with a note. The Graph sign-in needs an **Intune admin**
  with the same scopes Online enrollment uses.
- **Replication lag:** immediately after an Online enrollment, a just-imported
  device may not yet be deletable from every service; the runner treats a
  not-found as benign, so re-run if a service lags.

## Resetting state

For rapid test cycles, the bundled `Reset-VMPilot.ps1` wipes every VM-Pilot
artifact in one shot:

```powershell
.\Reset-VMPilot.ps1            # Inventory first, confirms before deleting
.\Reset-VMPilot.ps1 -Force     # Skip confirmation
.\Reset-VMPilot.ps1 -ResetISO  # Also nukes the cached Windows media (~5 GB)
```

It self-elevates, removes every VM not on its keep list, deletes their
`C:\VMs\<name>\` folders, removes the cached parent VHDX, and removes the
cached community AutoPilot script. Override the keep list with
`-Keep @('VM1','VM2',...)`.

## Theme

Every window VM-Pilot shows — the main window, the Hyper-V prompts, the ISO
wizard, the VM Cleanup dialog and every confirm in between — is built from one
ResourceDictionary held in `$script:ThemeXaml` and spliced into each window's
`<Window.Resources>` at the `<!-- @THEME@ -->` token by `Get-ThemedXaml`. Load
windows with `New-ThemedWindow` rather than `XamlReader::Load` so they pick it
up. Splicing before parse is deliberate: `StaticResource` only resolves against
resources that already exist when the tree is built, so merging a dictionary
afterwards is too late, and a loose script has no `pack://` URI to reference.

The dictionary is ported from
[`Get-WindowsAutopilotImportGUICommunity`](https://github.com/markorr321/Get-WindowsAutopilotImportCommunity)'s
`src\Themes\Dark.xaml`, so the two tools read as one family on a technician's
bench. Everything is hand-templated because WPF's stock templates are
light-themed — a plain `Background` setter still leaves CheckBoxes, ListBox
rows and ScrollBars grey-on-white.

Two rules worth keeping:

- **No implicit `<Style TargetType="TextBlock">`.** An implicit TextBlock style
  also applies to the TextBlock a `ContentPresenter` generates for string
  content, so a `Foreground` or `FontSize` setter there silently overrides
  every button and segmented-control template — an unchecked `Segment` would
  render white instead of `#A8A8A8`. Text styling is keyed only; windows
  inherit `Foreground` and `FontFamily` from the `Window` element.
- **Don't set `Foreground` locally on a themed control.** A local value
  outranks the style's trigger setters, which freezes hover and checked states
  (this is why `Update-VmList` builds its CheckBoxes without one).

`Show-VMPilotDialog` replaces `[System.Windows.MessageBox]` everywhere. It
takes `-Title`, `-Message`, an optional selectable monospaced `-Detail` block,
`-PrimaryText` / `-SecondaryText`, `-Danger` for destructive confirms, and
`-Owner`; it returns `'Primary'`, `'Secondary'` or `'Closed'`. Enter confirms,
Esc cancels when a secondary button is present.

## Output locations

| Mode    | Location                                                                  |
| ------- | ------------------------------------------------------------------------- |
| Offline | `C:\Autopilot CSV Collection\` on the host — `AutoPilotHWID-<serial>.csv` (v1) or `AutoPilotID-<serial>.csv` (v2). |
| Online  | Imported directly into your Intune tenant; the CSV exists only inside the VM at `C:\HWID\` and is discarded with the VM. |

## PowerShell 7 only

VM-Pilot requires **PowerShell 7** (`pwsh.exe`). The manifest declares
`PowerShellVersion = '7.0'` and `CompatiblePSEditions = @('Core')`, so
importing it under Windows PowerShell 5.1 fails up front with a clear error
rather than misbehaving later. `VMPilot.bat` checks for `pwsh` and tells you
how to install it instead of silently falling back to 5.1, and
`Start-VMPilot` always launches the GUI with `pwsh.exe`.

Install PowerShell 7 with `winget install --id Microsoft.PowerShell`, or from
<https://aka.ms/powershell>.

**The in-VM scripts are the exception.** `VMPilotCollect.ps1` runs inside the
VM under the Windows PowerShell 5.1 that ships in the image — there is no
`pwsh` there, and installing one into a throwaway VM isn't worth it (the
Gallery import GUI that `C:\import.bat` fetches targets 5.1 for the same
reason). Keep it 5.1-compatible, and keep its **UTF-8 BOM**: 5.1 reads a
BOM-less file as Windows-1252 and chokes on the non-ASCII characters. Some
editors silently re-save without a BOM, so save as "UTF-8 with BOM" when you
edit it.

## Troubleshooting

- **VM doesn't boot to OOBE / never auto-shuts-down (Offline)** — mount the
  child VHDX manually and check `C:\HWID\collection.log` for the script's
  output. Usually a hash-collection error.
- **A bundled `.ps1` shows a parser error ("missing `}`", "Try is missing
  its Catch")** — almost always a Windows PowerShell 5.1 encoding problem.
  The scripts are UTF-8 **with a BOM** so 5.1 reads them correctly; if you
  edit one and your editor strips the BOM, 5.1 re-reads it as Windows-1252
  and mis-tokenizes non-ASCII characters (em-dashes, etc.). Fix: re-save the
  file as **"UTF-8 with BOM"**, or run it under `pwsh` (PowerShell 7). See
  the PowerShell note below.
- **Sign-in succeeds but upload returns 403** — your account doesn't have
  the `DeviceManagementServiceConfig.ReadWrite.All` scope granted in your
  tenant. Have an admin grant consent.
- **Script imports + syncs but doesn't reboot** — you're missing the
  `-Assign` flag in the community script invocation. The community script
  needs all three: `-Online -Assign -Reboot`. VM-Pilot ships this combo by
  default; if you've forked the in-VM GUI, double-check.
- **Rebuild blocked / cached VHDX is locked** — a test VM is still using
  the parent as its differencing disk. The builder now refuses to delete a
  parent any VM depends on (and names the VM in the error) rather than
  corrupting that VM; remove those VMs via **CLEANUP VMs** first, then
  rebuild. If it's just attached/mounted in Explorer or Disk Management,
  close that and rebuild — the builder dismounts and retries on its own.

## Credits

- **AutoPilot upload + assignment polling** — Andrew Taylor's community
  fork of Get-WindowsAutopilotInfo:
  https://github.com/andrew-s-taylor/WindowsAutopilotInfo
- **VM provisioning** — `HyperV.VMFactory` by Sascha Stumpler:
  https://github.com/SasStu/HyperV.VMFactory
- **Tenant record cleanup (Intune / Autopilot / Entra ID)** — `AutopilotCleanup`
  by Mark Orr: https://github.com/markorr321/Autopilot-Cleanup
- **Windows media catalog + download URLs** — [`OSD`](https://github.com/OSDeploy/OSD)
  by **David Segura** ([@OSDeploy](https://github.com/OSDeploy)) — the module
  behind **OSDCloud**. VM-Pilot's entire "get Windows media" story is his work:
  `Get-FeatureUpdate` resolves the official Microsoft download URL, filename and
  SHA256 for a given release/channel/language, which is what let VM-Pilot drop
  its old page-scraping resolver. Licensed **GPL-3.0**; installed from
  PowerShell Gallery at runtime, never bundled or redistributed here.
  Please star and support the project: https://github.com/OSDeploy/OSD
- **Original CLI workflow that this replaced** —
  https://github.com/markorr321/HyperPilot-Offline-HWID-Collection-Workflow
