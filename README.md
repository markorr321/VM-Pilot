# VM-Pilot

WPF GUI for spinning up disposable Hyper-V VMs and collecting AutoPilot hardware
hashes — either as a CSV on disk (Offline) or imported directly into Intune
AutoPilot from inside the VM via Andrew Taylor's community script (Online).

## What it does

On first launch, VM-Pilot checks Hyper-V is enabled (and offers to enable
it + reboot if not). Then a single button-click in the host GUI:

1. **Builds** a Windows 11 parent VHDX (one-time per release, cached) via
   the bundled `Get-Win11VHDX.ps1` so you don't supply or maintain a template.
   Pick **24H2** or **25H2** in the GUI's WIN RELEASE segment.
2. **Creates** a differencing-disk child VM in Hyper-V via the
   `HyperV.VMFactory` PowerShell module — Gen 2, Secure Boot, vTPM, Default Switch.
3. **Injects** mode-specific payload into the child VHDX *before* first boot.
4. **Boots** the VM and opens vmconnect.

What happens next depends on mode:

### Offline mode (CSV)

- `VMPilotCollect.ps1` runs as `SetupComplete.cmd` (specialize pass, SYSTEM
  context, before OOBE).
- WMI queries `Win32_BIOS` and `MDM_DevDetail_Ext01` for the serial and
  hardware hash, writes the CSV to `C:\HWID\AutoPilotHWID-<serial>.csv`
  inside the VM with a **`Group Tag`** column when you fill the host field in.
- VM self-shuts-down via `shutdown /s /f /t 5`.
- Host polls for VM `Off`, mounts the child VHDX read-only via a folder
  access path (avoids Windows auto-opening Explorer), copies the newest
  matching CSV to `C:\Autopilot HWID Collection\`, dismounts, restarts the VM.

### Online mode (Intune AutoPilot import)

- VM lands at the **OOBE region screen** and **never leaves OOBE state**.
- You press **`Shift+F10`** in vmconnect and run **`C:\import.bat`**.
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

## Repo contents

| File                          | Purpose                                                                       |
| ----------------------------- | ----------------------------------------------------------------------------- |
| `VM-Pilot.psd1`               | PowerShell module manifest. Identity, exports, PSGallery metadata. |
| `VM-Pilot.psm1`               | Module entry. Exposes the `Start-VMPilot` cmdlet. |
| `VMPilot.GUI.ps1`             | The host WPF GUI. Dark theme, segmented controls, status + progress + completion. |
| `VMPilot.bat`                 | Thin launcher for double-click use. Auto-elevates and starts the GUI hidden. |
| `Get-Win11VHDX.ps1`           | Builder. DISM-applies a Windows 11 ISO to a GPT/UEFI VHDX. Accepts `-IsoPath` to skip download, or falls back to Fido. |
| `Get-UUPDumpISO.ps1`          | UUP Dump helper. Queries `api.uupdump.net`, downloads + runs the conversion pack, produces a fresh Win11 ISO from the Windows Update CDN. |
| `VMPilotCollect.ps1`          | Offline: runs inside the VM at specialize, writes the AutoPilot CSV with optional Group Tag column. |
| `AutopilotEnroll.GUI.ps1`     | Online: small WPF window that runs inside the VM at OOBE Shift+F10, fronts the community script. |
| `Reset-VMPilot.ps1`           | Standalone cleanup utility. Wipes test VMs, parent VHDX, and cached community script for a clean re-run. |
| `LICENSE`                     | MIT.                                                                          |
| `README.md`                   | This file.                                                                    |

## Prerequisites

- **Windows 10/11 host** with the Hyper-V role and Hyper-V Manager installed.
- **Administrator** rights (the launcher auto-elevates via UAC).
- **PowerShell 7+** preferred (`pwsh.exe`); falls back to Windows PowerShell 5.1.
- **`HyperV.VMFactory`** PowerShell module — auto-installed from PSGallery on
  first run (`Install-Module -Scope CurrentUser`).
- **Parent VHDX** — built automatically on first use of a release. When no
  cached VHDX exists for the picked release, the GUI shows a setup dialog:
  - **Download via UUP Dump (recommended)** — pulls UUP files from the
    Windows Update CDN (`*.delivery.mp.microsoft.com`), assembles a Win11
    ISO via UUP Dump's converter, DISM-applies to
    `C:\VMs\Win11-<release>.vhdx`. ~15-20 min on most hardware. Works on
    corporate networks where the public Software Download endpoint is
    blocked, because Windows Update has to work for the machine.
  - **Browse for an existing ISO** — point at a Win11 ISO you already
    have (Visual Studio Subscriptions, VLSC, MSDN, USB stick). Skips the
    UUP Dump conversion entirely (~5-10 min total).
  Per-release cache: 24H2 and 25H2 each have their own VHDX, built only
  when their respective release is picked.
- **Internet** — once per release at first build for UUP files or ISO
  download, and from inside the VM during Online enrollment so it can
  reach Microsoft Graph.
- **Intune admin account** (Online mode only) with consent for
  `Device.ReadWrite.All`, `DeviceManagementManagedDevices.ReadWrite.All`,
  `DeviceManagementServiceConfig.ReadWrite.All`, and
  `DeviceManagementScripts.ReadWrite.All`.

## Licensing & redistribution

VM-Pilot is MIT-licensed code that **does not include or redistribute any
Microsoft software**. On first run, the bundled helper (`Get-UUPDumpISO.ps1`
via [UUP Dump](https://uupdump.net), or `Get-Win11VHDX.ps1` with Fido as a
fallback) downloads Windows install media directly from Microsoft's own
servers (Windows Update CDN or the public Software Download page) to your
machine. Microsoft sees you as the downloader, not VM-Pilot or this repo.

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
| **WIN RELEASE** — 24H2 / 25H2          | Which Windows 11 build to use. Per-release parent VHDX cache.            |
| **VM NAME**                            | Hyper-V VM name. Must not collide with an existing VM.                   |
| **CPU CORES** — 1 / 2 / 4              | Defaults to 2. Bump to 4 for faster boot.                                 |
| **RAM (GB)** — 4 / 8 / 16              | Defaults to 4. Bump to 8 for faster boot.                                 |
| **GROUP TAG** *(Offline only)*         | Optional. Adds a `Group Tag` column to the CSV. Leave blank to omit.   |
| **COLLECT HWID** / **COLLECT & UPLOAD** | Label changes with mode. Kicks off the run.                            |
| **OPEN AUTOPILOT** *(bottom-left)*     | Launches the Intune AutoPilot Devices page in your default browser.    |
| **CLEANUP VMs** *(bottom-right, red)*  | Opens a dialog listing every Hyper-V VM with per-row checkboxes plus Remove Selected / Remove All buttons. Each removal stops the VM, deletes it, and wipes its `C:\VMs\<name>` folder. |
| **EXIT** *(bottom-right, gray)*        | Closes the GUI.                                                         |

Status text and an indeterminate progress bar show what stage you're at.
On success, the run renders a centered **Complete** in green plus a
**DEVICE SERIAL** block — the serial is auto-copied to your clipboard
ready to paste. Errors render in red in the same slot.

## First-run behavior

- **Hyper-V not enabled** — `Start-VMPilot` prints a yellow console notice,
  then the GUI shows a dialog: **Hyper-V Required — Enable it now?** Clicking
  **ENABLE HYPER-V** runs `dism.exe` in the background (1–3 minutes with an
  animated progress bar), then a **Reboot Required** dialog. After reboot,
  run `Start-VMPilot` again and the check passes silently.
- **First click of COLLECT HWID for a given release** — if no cached parent
  VHDX exists at `C:\VMs\Win11-<release>.vhdx`, the **Build Windows VHDX**
  dialog appears with two options:
  - **Download via UUP Dump (recommended)** — ~15-20 min, status text
    updates throughout (Downloading UUP files… 54%, Building install.wim…
    62%, etc.)
  - **Browse for an existing ISO** — ~5-10 min, skips UUP Dump entirely
  Each release (24H2, 25H2) builds independently and caches separately.
- **First Online run** — VM-Pilot also downloads
  `Get-WindowsAutopilotInfoCommunity.ps1` to `C:\Tools\VMPilot\` (cached).
- **Every subsequent run** — parent VHDX is reused, community script is reused.
  VM creation + boot is the only time spent (~5-10 min total per VM).

## In-VM enrollment GUI (Online only)

Once the VM is booted and at OOBE region screen:

1. Press **`Shift+F10`** to open a command prompt.
2. Run **`C:\import.bat`**.
3. A small **VM-Pilot** window (subtitle: *AutoPilot Import*) appears with
   the device serial, a Group Tag field, and an Assigned User UPN field
   (both optional).
4. Click **ENROLL DEVICE**. A PowerShell window opens showing the community
   script's live progress.
5. A Microsoft sign-in browser will open — sign in with your Intune admin.
6. Watch the upload + assignment poll. When the script reboots the VM,
   AutoPilot picks up the assigned profile on the next OOBE boot and
   enrolls the device end-to-end without further interaction.

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
| Offline | `C:\Autopilot HWID Collection\AutoPilotHWID-<serial>.csv` on the host.   |
| Online  | Imported directly into your Intune tenant; the CSV exists only inside the VM at `C:\HWID\` and is discarded with the VM. |

## Troubleshooting

- **VM doesn't boot to OOBE / never auto-shuts-down (Offline)** — mount the
  child VHDX manually and check `C:\HWID\collection.log` for the script's
  output. Usually a hash-collection error.
- **In-VM `import.bat` shows a parser error** — the in-VM enrollment GUI is
  intentionally pure-ASCII to avoid Windows PowerShell 5.1 encoding issues.
  If you edit `AutopilotEnroll.GUI.ps1`, keep it ASCII-only.
- **Sign-in succeeds but upload returns 403** — your account doesn't have
  the `DeviceManagementServiceConfig.ReadWrite.All` scope granted in your
  tenant. Have an admin grant consent.
- **Script imports + syncs but doesn't reboot** — you're missing the
  `-Assign` flag in the community script invocation. The community script
  needs all three: `-Online -Assign -Reboot`. VM-Pilot ships this combo by
  default; if you've forked the in-VM GUI, double-check.
- **Cached VHDX is locked** — a previous test VM is still using it as a
  differencing parent. Stop+remove that VM and its `C:\VMs\<name>\` folder
  before you can re-build the parent.

## Credits

- **AutoPilot upload + assignment polling** — Andrew Taylor's community
  fork of Get-WindowsAutopilotInfo:
  https://github.com/andrew-s-taylor/WindowsAutopilotInfo
- **VM provisioning** — `HyperV.VMFactory` by Sascha Stumpler:
  https://github.com/SasStu/HyperV.VMFactory
- **Windows ISO via Windows Update CDN** — UUP Dump:
  https://uupdump.net
- **ISO download resolver (fallback)** — Pete Batard's Fido:
  https://github.com/pbatard/Fido
- **Original CLI workflow that this replaced** —
  https://github.com/markorr321/HyperPilot-Offline-HWID-Collection-Workflow
