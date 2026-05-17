# VM-Pilot

WPF GUI for spinning up disposable Hyper-V VMs and collecting AutoPilot hardware
hashes — either as a CSV on disk (Offline) or imported directly into Intune
AutoPilot from inside the VM via Andrew Taylor's community script (Online).

## What it does

A single button-click in the host GUI:

1. **Builds** a Windows 11 25H2 parent VHDX (one-time, cached) via
   `Get-Win11VHDX.ps1` so you don't supply or maintain a template.
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
| `VMPilot.bat`                 | Thin launcher. Auto-elevates and starts the host GUI hidden (no console flash). |
| `VMPilot.GUI.ps1`             | The host WPF GUI. Dark theme, segmented controls, status + progress + completion. |
| `VMPilotCollect.ps1`          | Offline: runs inside the VM at specialize, writes the AutoPilot CSV with optional Group Tag column. |
| `AutopilotEnroll.GUI.ps1`     | Online: small WPF window that runs inside the VM at OOBE Shift+F10, fronts the community script. |
| `README.md`                   | This file.                                                                    |

## Prerequisites

- **Windows 10/11 host** with the Hyper-V role and Hyper-V Manager installed.
- **Administrator** rights (the launcher auto-elevates via UAC).
- **PowerShell 7+** preferred (`pwsh.exe`); falls back to Windows PowerShell 5.1.
- **`HyperV.VMFactory`** PowerShell module — auto-installed from PSGallery on
  first run (`Install-Module -Scope CurrentUser`).
- **Parent VHDX** — built automatically on first run by the bundled
  `Get-Win11VHDX.ps1` (ships with the module). It fetches Fido + the Windows
  11 ISO from Microsoft and DISM-applies it to a fresh GPT/UEFI VHDX at
  `C:\VMs\Win11-<release>.vhdx`, where `<release>` is whichever build you
  pick in the **WIN RELEASE** segment (24H2 by default; 25H2 also supported).
  The build takes ~10–30 min depending on network and runs once per release;
  every subsequent run reuses the cached VHDX.
- **Internet** — once per release at host build time for the ISO/community
  script downloads, and from inside the VM during Online enrollment so it
  can reach Microsoft Graph.
- **Intune admin account** (Online mode only) with consent for
  `Device.ReadWrite.All`, `DeviceManagementManagedDevices.ReadWrite.All`,
  `DeviceManagementServiceConfig.ReadWrite.All`, and
  `DeviceManagementScripts.ReadWrite.All`.

## Licensing & redistribution

VM-Pilot is MIT-licensed code that **does not include or redistribute any
Microsoft software**. On first run, the bundled `Get-Win11VHDX.ps1` builder
uses [Fido](https://github.com/pbatard/Fido) to query the public Microsoft
Software Download page and pull the Windows 11 ISO directly from Microsoft's
own servers to your machine. Microsoft sees you as the downloader, not
VM-Pilot or this repo.

You are responsible for ensuring your Windows licensing covers the VMs you
create. For short-lived test/eval VMs that exist only long enough to grab a
hardware hash, unactivated Windows is what Microsoft offers for exactly this
kind of usage. For longer-lived VMs or production deployments, apply a key
per your normal licensing agreement (retail, OEM, volume, MSDN, etc.).

**Do not** publish or share the cached `Win11-*.vhdx` files this tool
generates — they contain a Microsoft Windows installation and redistributing
them is a EULA violation. They are gitignored for that reason.

## Install + launch

```powershell
git clone https://github.com/markorr321/VM-Pilot.git
cd VM-Pilot
.\VMPilot.bat
```

`VMPilot.bat` triggers a UAC prompt, launches the WPF GUI hidden of any
console window, then the host workflow takes over.

## Host GUI controls

| Field                                  | Notes                                                                  |
| -------------------------------------- | ---------------------------------------------------------------------- |
| **MODE** — Offline / Online (Upload AP) | Selects which payload to inject into the VM.                            |
| **VM NAME**                            | Hyper-V VM name. Must not collide with an existing VM.                   |
| **CPU CORES** — 1 / 2 / 4              | Defaults to 2. Bump to 4 for faster boot.                                 |
| **RAM (GB)** — 4 / 8 / 16              | Defaults to 4. Bump to 8 for faster boot.                                 |
| **GROUP TAG** *(Offline only)*         | Optional. Adds a `Group Tag` column to the CSV. Leave blank to omit.   |
| **COLLECT HWID** / **COLLECT & UPLOAD** | Label changes with mode. Kicks off the run.                            |

Status text and an indeterminate progress bar show what stage you're at.
Success renders a large centered `Complete` in green; errors render red in
the same slot.

## First-run behavior

- **First run, ever** — VM-Pilot invokes `Get-Win11VHDX.ps1` which downloads
  Fido, then the Windows 11 ISO, then DISM-applies it to
  `C:\VMs\Win11-25H2.vhdx`. Expect 10–30 minutes depending on network speed.
- **First Online run** — VM-Pilot also downloads
  `Get-WindowsAutopilotInfoCommunity.ps1` to `C:\Tools\VMPilot\` (cached).
- **Every subsequent run** — parent VHDX is reused, community script is reused.
  VM creation + boot is the only time spent.

## In-VM enrollment GUI (Online only)

Once the VM is booted and at OOBE region screen:

1. Press **`Shift+F10`** to open a command prompt.
2. Run **`C:\import.bat`**.
3. A small **AutoPilot Enrollment** window appears with the device serial,
   a Group Tag field, and an Assigned User UPN field (both optional).
4. Click **ENROLL DEVICE**. A PowerShell window opens showing the community
   script's live progress.
5. A Microsoft sign-in browser will open — sign in with your Intune admin.
6. Watch the upload + assignment poll. When the script reboots the VM,
   AutoPilot picks up the assigned profile on the next OOBE boot and
   enrolls the device end-to-end without further interaction.

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
- **ISO download resolver** — Pete Batard's Fido:
  https://github.com/pbatard/Fido
- **Original CLI workflow that this replaced** —
  https://github.com/markorr321/HyperPilot-Offline-HWID-Collection-Workflow
