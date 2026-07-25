# VM-Pilot

WPF GUI for spinning up disposable Hyper-V VMs and collecting AutoPilot hardware
hashes — either as a CSV on disk (Offline) or imported directly into Intune
AutoPilot from inside the VM via Andrew Taylor's community script (Online).

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
- You press **`Shift+F10`** in vmconnect and run **`C:\importv1.bat`**.
- The bat pre-installs the NuGet provider + trusts PSGallery silently,
  then launches a small dark WPF window (`AutopilotEnroll.GUI.ps1`) with
  optional Group Tag and Assigned User UPN inputs.
- Click **ENROLL DEVICE** → the community script
  (`Get-WindowsAutopilotInfoCommunity.ps1`) runs in a visible PowerShell
  window with `-Online -Assign -Reboot`.
- A Microsoft sign-in browser opens *inside the VM*. Sign in with an
  Intune admin account (the script will request the right Graph scopes
  on first use).
- Script uploads the hash, polls `state.deviceImportStatus` until
  `complete`, triggers AutoPilot sync, polls
  `deploymentProfileAssignmentStatus` until `assigned`, then
  `Restart-Computer -Force`. Because OOBE was never completed, the reboot
  returns to OOBE → AutoPilot detects the now-assigned profile and
  self-enrolls the device.

### AutoPilot v2 / Device preparation (Online mode)

Online mode also injects a second entry point, **`C:\importv2.bat`**, for
**Autopilot device preparation (v2)**. v2 does not use a hardware hash — it
imports the device **identifier** (`Manufacturer,Model,Serial`) instead:

- `Shift+F10` → **`C:\importv2.bat`**.
- The bat primes NuGet + PSGallery, then runs `AutopilotV2Import.ps1`, which
  calls `Get-WindowsAutopilotInfoCommunity.ps1 -identifier -Online` against the
  pre-injected copy at `C:\` (falling back to `Install-Script` from PSGallery
  if that copy is missing).
- Sign in when the Microsoft prompt appears; the identifier is posted to
  `deviceManagement/importedDeviceIdentities`.
- **Group Tag / Assigned User do not apply to v2.** Device preparation targets
  an Entra security group on the policy, so add the VM's device object to that
  group after the import, then reboot the VM to restart OOBE.

Both entry points ship on every Online-mode VM, so you can test **v1 and v2**
from the same image — pick per VM at the Shift+F10 prompt:

| Run | Flow | What gets imported |
| --- | ---- | ------------------ |
| `C:\importv1.bat` | AutoPilot v1 (profile-based) | Hardware hash, + optional Group Tag / Assigned User, waits for profile assignment, reboots into enrollment |
| `C:\importv2.bat` | AutoPilot v2 (Device preparation) | Device identifier `Manufacturer,Model,Serial` |

## Repo contents

| File                          | Purpose                                                                       |
| ----------------------------- | ----------------------------------------------------------------------------- |
| `VM-Pilot.psd1`               | PowerShell module manifest. Identity, exports, PSGallery metadata. |
| `VM-Pilot.psm1`               | Module entry. Exposes the `Start-VMPilot` cmdlet. |
| `VMPilot.GUI.ps1`             | The host WPF GUI. Dark theme, segmented controls, status + progress + completion. |
| `VMPilot.bat`                 | Thin launcher for double-click use. Auto-elevates and starts the GUI hidden. |
| `Get-Win11VHDX.ps1`           | Builder. DISM-applies a Windows 11 ISO to a GPT/UEFI VHDX. Accepts `-IsoPath` / `-PickIso` (skips download), or falls back to Fido. Auto-names the VHDX after the release detected inside the ISO when `-OutVhdx` isn't pinned, and refuses to overwrite a parent any VM still depends on. |
| `VMPilotCollect.ps1`          | Offline: runs inside the VM at specialize. Writes the v1 hash CSV (optional Group Tag column) or, with `-Identifier`, the v2 `Manufacturer,Model,Serial` CSV. |
| `AutopilotEnroll.GUI.ps1`     | Online: small WPF window that runs inside the VM at OOBE Shift+F10, fronts the community script. |
| `AutopilotV2Import.ps1`       | Online: runs inside the VM at OOBE via `C:\importv2.bat`. AutoPilot v2 / Device preparation — imports the device identifier (`-identifier -Online`). |
| `Reset-VMPilot.ps1`           | Standalone cleanup utility. Wipes test VMs, parent VHDX, and cached community script for a clean re-run. |
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
- **Parent VHDX** — built automatically on first use. When no cached
  `C:\VMs\Win11-25H2.vhdx` exists, the GUI opens the **Get Windows 11
  Install Media** wizard:
  - Guided click-path to download the official **Windows 11 (multi-edition
    ISO for x64 devices)** from Microsoft's Software Download page
    (`https://www.microsoft.com/en-us/software-download/windows11`).
  - Click **BUILD VHDX FROM ISO**, pick the `.iso` you saved, and the
    builder DISM-applies it to `C:\VMs\Win11-25H2.vhdx` with a live apply
    percentage. A non-25H2 ISO (e.g. 24H2) is rejected.
  - Once the wizard finishes, the pending VM build continues automatically.
  You can also open this wizard any time with the green **SETUP** button to
  pre-build the parent VHDX. The 25H2 VHDX is built once and reused.
- **Internet** — once at first build to download the Windows 11 ISO,
  and from inside the VM during Online enrollment so it can
  reach Microsoft Graph.
- **Intune admin account** (Online mode only) with consent for
  `Device.ReadWrite.All`, `DeviceManagementManagedDevices.ReadWrite.All`,
  `DeviceManagementServiceConfig.ReadWrite.All`, and
  `DeviceManagementScripts.ReadWrite.All`.

## Licensing & redistribution

VM-Pilot is MIT-licensed code that **does not include or redistribute any
Microsoft software**. You download the Windows 11 ISO yourself from
Microsoft's official [Software Download page](https://www.microsoft.com/en-us/software-download/windows11)
(the SETUP wizard walks you through it), and `Get-Win11VHDX.ps1` DISM-applies
that ISO to a local VHDX. Microsoft sees you as the downloader, not VM-Pilot
or this repo.

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
| **WIN RELEASE** — 25H2                  | Windows 11 build used. Fixed at 25H2 (cached parent VHDX).               |
| **VM NAME**                            | Hyper-V VM name. Must not collide with an existing VM.                   |
| **CPU CORES** — 1 / 2 / 4              | Defaults to 2. Bump to 4 for faster boot.                                 |
| **RAM (GB)** — 4 / 8 / 16              | Defaults to 4. Bump to 8 for faster boot.                                 |
| **GROUP TAG** *(Offline only)*         | Optional. Adds a `Group Tag` column to the CSV. Leave blank to omit.   |
| **COLLECT HWID** / **COLLECT & UPLOAD** | Label changes with mode. Kicks off the run.                            |
| **OPEN AUTOPILOT** *(bottom-left)*     | Launches the Intune AutoPilot Devices page in your default browser.    |
| **SETUP** *(bottom, green)*            | Opens the **Get Windows 11 Install Media** wizard: guided steps to download an official Microsoft ISO, then builds the parent VHDX from the ISO you pick (live percentage, auto-named by the release inside the ISO). Warns first if a parent VHDX already exists or a VM depends on it. |
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
- **First click of COLLECT HWID** — if no cached parent VHDX exists at
  `C:\VMs\Win11-25H2.vhdx`, the **Get Windows 11 Install Media** wizard
  opens: download the official ISO from Microsoft, then **BUILD VHDX FROM
  ISO** (~5-10 min, live apply percentage). When it finishes, the VM build
  continues automatically. The 25H2 parent VHDX is built once and cached.
- **First Online run** — VM-Pilot also downloads
  `Get-WindowsAutopilotInfoCommunity.ps1` to `C:\Tools\VMPilot\` (cached).
- **Every subsequent run** — parent VHDX is reused, community script is reused.
  VM creation + boot is the only time spent (~5-10 min total per VM).

## Building media manually (SETUP)

The green **SETUP** button is an on-demand alternative to the auto-triggered
build dialog — useful for pre-building a parent VHDX, or when you'd rather
grab the official Microsoft ISO yourself:

1. Click **SETUP** → the **Get Windows 11 Install Media** wizard opens with
   numbered steps and an **OPEN DOWNLOAD PAGE** button (Microsoft's Software
   Download page).
2. Follow the steps to download a **Windows 11 (multi-edition ISO for x64
   devices)** — choose the product language → Confirm → 64-bit Download.
3. Click **BUILD VHDX FROM ISO**, pick the `.iso` you saved, and watch the
   live status: *Mounting ISO… → Detected Windows 11 25H2 → Applying Windows
   image… NN% → Writing UEFI… → Finalizing*.
4. The VHDX is auto-named from the release inside the ISO
   (`C:\VMs\Win11-25H2.vhdx`). A non-25H2 ISO (e.g. 24H2) is rejected. On
   success the wizard shows **Build your first VM!** and closes itself.

If a parent VHDX already exists, SETUP warns before doing anything and names
any VMs that depend on it (which must be removed via **CLEANUP VMs** before a
rebuild can replace the parent).

## In-VM enrollment GUI (Online only)

Once the VM is booted and at OOBE region screen:

1. Press **`Shift+F10`** to open a command prompt.
2. Run **`C:\importv1.bat`**.
3. A small **VM-Pilot** window (subtitle: *AutoPilot Import*) appears with
   the device serial, a Group Tag field, and an Assigned User UPN field
   (both optional).
4. Click **ENROLL DEVICE**. A PowerShell window opens showing the community
   script's live progress.
5. A Microsoft sign-in browser will open — sign in with your Intune admin.
6. Watch the upload + assignment poll. When the script reboots the VM,
   AutoPilot picks up the assigned profile on the next OOBE boot and
   enrolls the device end-to-end without further interaction.

For **Autopilot v2 (Device preparation)** run **`C:\importv2.bat`** at step 2
instead — it imports the device identifier rather than the hash and has no
Group Tag / Assigned User inputs. See *AutoPilot v2 / Device preparation*
above.

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
   **PowerShell 7** window that runs the `AutopilotCleanup` module's
   `Invoke-AutopilotCleanup` against those serials. At its action menu, choose
   **[1] Remove records only**.
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
.\Reset-VMPilot.ps1 -ResetISO  # Also nukes the cached Windows ISO (~5 GB)
```

It self-elevates, removes every VM not on its keep list, deletes their
`C:\VMs\<name>\` folders, removes the cached parent VHDX, and removes the
cached community AutoPilot script. Override the keep list with
`-Keep @('VM1','VM2',...)`.

## Output locations

| Mode    | Location                                                                  |
| ------- | ------------------------------------------------------------------------- |
| Offline | `C:\Autopilot CSV Collection\` on the host — `AutoPilotHWID-<serial>.csv` (v1) or `AutoPilotID-<serial>.csv` (v2). |
| Online  | Imported directly into your Intune tenant; the CSV exists only inside the VM at `C:\HWID\` and is discarded with the VM. |

## PowerShell 5.1 vs 7

VM-Pilot runs under both **Windows PowerShell 5.1** (`powershell.exe`, ships
in every Windows box) and **PowerShell 7+** (`pwsh.exe`). `VMPilot.bat` and
`Start-VMPilot` prefer `pwsh` when it's installed and fall back to 5.1.

The one thing to know: the two read script files differently. PowerShell 7
defaults to **UTF-8**; Windows PowerShell 5.1 defaults to the legacy
**Windows-1252** codepage *unless the file carries a UTF-8 byte-order mark
(BOM)*. The bundled `.ps1`/`.psd1`/`.psm1` files contain non-ASCII
characters (em-dashes, etc.) and are therefore saved **UTF-8 with a BOM** so
5.1 parses them correctly. Two practical consequences:

- **Launch either way.** `powershell.exe -File .\VMPilot.GUI.ps1` and
  `pwsh -File .\VMPilot.GUI.ps1` both work.
- **If you edit a script, keep the BOM.** Some editors/formatters silently
  re-save UTF-8 *without* a BOM; under 5.1 that reintroduces parser errors
  on the non-ASCII characters. Save as "UTF-8 with BOM", or just run the
  edited file under `pwsh`. The in-VM scripts (`AutopilotEnroll.GUI.ps1`,
  `VMPilotCollect.ps1`) run under the VM's 5.1, so this applies to them too.

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
- **ISO download resolver (CLI fallback)** — Pete Batard's Fido:
  https://github.com/pbatard/Fido
- **Original CLI workflow that this replaced** —
  https://github.com/markorr321/HyperPilot-Offline-HWID-Collection-Workflow
