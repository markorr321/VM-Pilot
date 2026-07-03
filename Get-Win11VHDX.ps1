
<#
.SYNOPSIS
  Downloads a Windows 11 ISO (25H2, current channel) and builds a Gen-2/UEFI VHDX.

.EXAMPLE
  .\Get-Win11VHDX.ps1 -Release 25H2 -Edition Pro -OutVhdx C:\VMs\Win11-25H2.vhdx

.EXAMPLE
  # Browse to an existing ISO with a file picker instead of downloading.
  # The VHDX is auto-named after the Windows release detected inside the
  # picked ISO (e.g. C:\VMs\Win11-25H2.vhdx) unless you pin -OutVhdx:
  .\Get-Win11VHDX.ps1 -PickIso
#>
[CmdletBinding()]
param(
    [ValidateSet('25H2')]        [string]$Release  = '25H2',
    [ValidateSet('Home','Pro')]  [string]$Edition  = 'Pro',
    [string]$Language = 'English',
    [int]   $SizeGB   = 64,
    [string]$WorkDir  = 'C:\Tools\WinVHDX',
    [string]$OutVhdx  = "C:\VMs\Win11-$Release.vhdx",
    # Pre-supplied ISO. If provided, skips Fido + download entirely and
    # DISM-applies the existing file. Lets the GUI feed an ISO from any
    # source (Microsoft Software Download page, Visual Studio, VLSC, USB, etc.).
    [string]$IsoPath,
    # Pop a Windows "Open file" dialog to pick the ISO interactively. Sets
    # $IsoPath from whatever the user selects, then follows the same
    # supplied-ISO path as -IsoPath (skips Fido + download).
    [switch]$PickIso
)

$ErrorActionPreference = 'Stop'

# --- Admin check ---------------------------------------------------------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an elevated PowerShell — VHDX mount + DISM require admin."
}

# --- Optional ISO file picker -------------------------------------------
# If -PickIso was requested (and no explicit -IsoPath given), show a native
# Open-file dialog so the user can browse to the ISO they want to convert.
# OpenFileDialog requires an STA thread; PowerShell isn't guaranteed to run
# STA (e.g. -MTA, or pwsh on some hosts), so run the dialog on a dedicated
# STA thread when needed.
if ($PickIso -and -not $IsoPath) {
    Add-Type -AssemblyName System.Windows.Forms

    $showDialog = {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title  = 'Select the Windows ISO to convert'
        $dlg.Filter = 'Disc image (*.iso)|*.iso|All files (*.*)|*.*'
        $dlg.Multiselect = $false
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $dlg.FileName
        }
    }

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        $picked = & $showDialog
    } else {
        $picked = $null
        $t = [System.Threading.Thread]::new([System.Threading.ThreadStart]{ $script:picked = & $showDialog })
        $t.SetApartmentState('STA')
        $t.Start()
        $t.Join()
    }

    if (-not $picked) { throw "No ISO selected — cancelled." }
    $IsoPath = $picked
    Write-Host "Selected ISO: $IsoPath"
}

New-Item -ItemType Directory -Force $WorkDir            | Out-Null
New-Item -ItemType Directory -Force (Split-Path $OutVhdx) | Out-Null

# --- Fetch Fido (only external dep) -------------------------------------
$fido = Join-Path $WorkDir 'Fido.ps1'
if (-not (Test-Path $fido)) {
    Write-Host "Fetching Fido..."
    Invoke-WebRequest 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1' -OutFile $fido
}

# --- Resolve ISO --------------------------------------------------------
# If -IsoPath was supplied (e.g. a hand-picked ISO from the SETUP wizard), use
# that and skip the Fido + download flow entirely.
if ($IsoPath) {
    if (-not (Test-Path $IsoPath -PathType Leaf)) {
        throw "Supplied -IsoPath does not exist: $IsoPath"
    }
    $iso = $IsoPath
    Write-Host "Using supplied ISO: $iso"
} else {
    $iso = Join-Path $WorkDir "Win11-$Release-$Edition.iso"
}
if (-not (Test-Path $iso)) {
    # Microsoft's public download page now offers only the most-recent
    # Windows 11 release as a single combined Home/Pro/Edu ISO. Older
    # tokens like '24H2' and short editions like 'Pro' no longer match
    # anything in Fido's list. Always ask Fido for Latest + Home/Pro/Edu;
    # the DISM step below still picks the right edition from install.wim.
    $fidoRelease = 'Latest'
    $fidoEdition = 'Home/Pro/Edu'
    Write-Host "Resolving ISO URL for Windows 11 $fidoRelease $fidoEdition ($Language)..."
    # Merge all streams (*>&1) so Fido's Write-Host error messages (e.g. the
    # 715-123130 IP-block notice) are captured alongside the URL on stdout.
    $fidoOutput = & $fido -Win 11 -Rel $fidoRelease -Ed $fidoEdition -Lang $Language -Arch x64 -GetUrl *>&1 |
                  ForEach-Object { "$_" }
    $url = $fidoOutput | Where-Object { $_ -match '^https?://' } | Select-Object -First 1
    if (-not $url) {
        $errLines = $fidoOutput | Where-Object { $_ -match 'Error|banned|715-' }
        $errText  = if ($errLines) { ($errLines -join "`n") } else { ($fidoOutput -join "`n").Trim() }
        if (-not $errText) { $errText = "(no output from Fido) — try running '.\Fido.ps1 -Win 11' interactively to diagnose." }
        throw "Fido failed to resolve ISO URL:`n$errText"
    }
    Write-Host "Downloading ISO -> $iso"
    # Use BITS so we can emit real % progress that the GUI parses and shows
    # on its progress bar. Falls back to Invoke-WebRequest if BITS is broken
    # or unavailable (rare — BITS is a default Windows service).
    $useBits = $true
    try { Import-Module BitsTransfer -ErrorAction Stop } catch { $useBits = $false }

    if ($useBits) {
        $bitsJob = Start-BitsTransfer -Source $url -Destination $iso -DisplayName 'VMPilot-Win11ISO' -Asynchronous
        try {
            while ($bitsJob.JobState -in 'Transferring','Connecting','Queued') {
                $b = $bitsJob.BytesTransferred
                $t = $bitsJob.BytesTotal
                if ($t -gt 0) {
                    $pct = [int](($b / $t) * 100)
                    $cur = [int]($b / 1MB)
                    $tot = [int]($t / 1MB)
                    Write-Host "ISO progress: $pct% ($cur / $tot MB)"
                }
                Start-Sleep -Seconds 2
            }
            if ($bitsJob.JobState -eq 'Transferred') {
                Complete-BitsTransfer -BitsJob $bitsJob
                Write-Host "ISO progress: 100%"
            } else {
                $errDesc = $bitsJob.ErrorDescription
                Remove-BitsTransfer -BitsJob $bitsJob -ErrorAction SilentlyContinue
                throw "BITS transfer ended in state '$($bitsJob.JobState)': $errDesc"
            }
        } catch {
            if ($bitsJob) {
                Get-BitsTransfer -JobId $bitsJob.JobId -ErrorAction SilentlyContinue |
                    Remove-BitsTransfer -ErrorAction SilentlyContinue
            }
            throw
        }
    } else {
        Invoke-WebRequest -Uri $url -OutFile $iso
    }
} else {
    Write-Host "Reusing existing ISO: $iso"
}

# --- Suppress shell popups for the duration of the build ----------------
# Mounting the ISO and partitioning/formatting the fresh VHDX both make the
# Windows shell pop dialogs: AutoPlay when the ISO gets a drive letter, and
# "You need to format the disk in drive X:" for the raw VHDX volumes. Those
# popups steal focus and can interrupt Format-Volume mid-build (the failure
# seen when building from the GUI wizard). Stop Shell Hardware Detection --
# the service behind AutoPlay and the format prompt -- for the whole build
# and restore it in the finally block below, so it always comes back even if
# the build throws. `mountvol /N` (further down) adds belt-and-suspenders
# against auto-lettering races during partitioning.
$shellHW           = Get-Service -Name ShellHWDetection -ErrorAction SilentlyContinue
$shellHWWasRunning = [bool]($shellHW -and $shellHW.Status -eq 'Running')

try {
if ($shellHWWasRunning) { Stop-Service -Name ShellHWDetection -Force -ErrorAction SilentlyContinue }

# --- Mount ISO and locate install.wim/esd -------------------------------
Write-Host "Mounting ISO..."
$isoMount  = Mount-DiskImage -ImagePath $iso -PassThru
$isoDrive  = ($isoMount | Get-Volume).DriveLetter
$sources   = "${isoDrive}:\sources"
$installImg = Get-ChildItem $sources -Filter 'install.*' |
              Where-Object { $_.Name -in 'install.wim','install.esd' } |
              Select-Object -First 1
if (-not $installImg) { throw "No install.wim/install.esd under $sources" }

# Pick edition index
$editionName = if ($Edition -eq 'Pro') { 'Windows 11 Pro' } else { 'Windows 11 Home' }
$imgInfo = Get-WindowsImage -ImagePath $installImg.FullName |
           Where-Object { $_.ImageName -eq $editionName } |
           Select-Object -First 1
if (-not $imgInfo) {
    $available = (Get-WindowsImage -ImagePath $installImg.FullName).ImageName -join ', '
    throw "Edition '$editionName' not found. Available: $available"
}
Write-Host "Using image index $($imgInfo.ImageIndex): $($imgInfo.ImageName)"

# --- Name the VHDX after the release actually inside the ISO -------------
# With -PickIso / -IsoPath the ISO can be any build, so the -Release param
# (and thus the default output name) may not reflect what's really inside.
# Read the image's build number, map it to a friendly release, and use that
# to name the VHDX. Only override the name when the caller did NOT pin
# -OutVhdx explicitly — the GUI always passes -OutVhdx, so it keeps full
# control of naming; this auto-naming only kicks in on direct invocation.
$imgDetail = Get-WindowsImage -ImagePath $installImg.FullName -Index $imgInfo.ImageIndex
$imgBuild  = ([Version]$imgDetail.Version).Build
if ($imgBuild -eq 26100) {
    throw "This ISO is Windows 11 24H2 (build 26100). VM-Pilot only supports 25H2 (build 26200) - please supply a 25H2 ISO."
}
$buildToRelease = @{ 26200 = '25H2' }
$detectedRelease = $buildToRelease[$imgBuild]
if ($detectedRelease) {
    Write-Host "Detected Windows 11 $detectedRelease (build $imgBuild) in image."
    $Release = $detectedRelease
} else {
    # Unknown/newer build: name it by build number so the file is still
    # accurate and distinct rather than mislabeled with the -Release default.
    Write-Warning "Unrecognized Windows build $imgBuild - naming VHDX by build number."
    $detectedRelease = "build$imgBuild"
}
if (-not $PSBoundParameters.ContainsKey('OutVhdx')) {
    $OutVhdx = Join-Path (Split-Path $OutVhdx -Parent) "Win11-$detectedRelease.vhdx"
    New-Item -ItemType Directory -Force (Split-Path $OutVhdx) | Out-Null
    Write-Host "Output VHDX name set from image: $OutVhdx"
}

# --- Remove any existing VHDX at the target path -----------------------
# A prior build, an Explorer/Disk-Management mount, or a VM created from
# this VHDX can leave it locked or depended-on. A blind Remove-Item -Force
# either fails ("being used by another process") or — worse — silently
# deletes a differencing-disk parent and corrupts the child VM. So: refuse
# if a VM depends on it (naming the VM), otherwise dismount + retry-delete.
if (Test-Path $OutVhdx) {
    $target = [System.IO.Path]::GetFullPath($OutVhdx)

    # Refuse to delete a VHDX any VM is using — directly attached or as a
    # differencing-disk parent. Deleting it would break that VM.
    $dependents = @()
    try {
        foreach ($vm in (Get-VM -ErrorAction SilentlyContinue)) {
            foreach ($d in (Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue)) {
                if (-not $d.Path) { continue }
                $dpFull = [System.IO.Path]::GetFullPath($d.Path)
                $info   = Get-VHD -Path $d.Path -ErrorAction SilentlyContinue
                $parent = if ($info -and $info.ParentPath) { [System.IO.Path]::GetFullPath($info.ParentPath) } else { $null }
                if (($dpFull -ieq $target) -or ($parent -and ($parent -ieq $target))) {
                    $dependents += $vm.Name
                    break
                }
            }
        }
    } catch { }
    if ($dependents) {
        throw "Can't rebuild $OutVhdx - VM(s) depend on it as their disk/parent: $($dependents -join ', '). Remove those VMs (CLEANUP VMs) first, then rebuild."
    }

    # No dependents. Dismount it if attached, drop wimserv handles, retry-delete.
    if ((Get-VHD -Path $OutVhdx -ErrorAction SilentlyContinue).Attached) {
        Write-Host "Existing VHDX is attached - dismounting before rebuild..."
        Dismount-VHD -Path $OutVhdx -ErrorAction SilentlyContinue
    }
    Get-Process wimserv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $removed = $false
    for ($i = 0; $i -lt 5 -and -not $removed; $i++) {
        try { Remove-Item $OutVhdx -Force -ErrorAction Stop; $removed = $true }
        catch {
            Start-Sleep -Seconds 1
            Dismount-VHD -Path $OutVhdx -ErrorAction SilentlyContinue
            Get-Process wimserv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $removed) {
        throw "Can't delete $OutVhdx - it's locked by another process. Is it open or mounted in Explorer / Disk Management? Close whatever is using it, then rebuild."
    }
}

# --- Create + partition VHDX -------------------------------------------

Write-Host "Creating $OutVhdx ($SizeGB GB, dynamic)..."
$vhd  = New-VHD -Path $OutVhdx -SizeBytes ($SizeGB * 1GB) -Dynamic
# Disable Windows automount before Mount-VHD. Even on a fresh GPT disk,
# Windows's shell can pop "format disk in drive X:" while we're partitioning
# if it tries to auto-letter a partition mid-format. Restored at script end.
& mountvol /N | Out-Null
$disk = Mount-VHD -Path $OutVhdx -Passthru | Get-Disk
Initialize-Disk -Number $disk.Number -PartitionStyle GPT

# Assign the drive letter FIRST, then format by letter. Format-Volume
# -Partition fails with "Invalid Parameter" when formatting the ESP (and,
# on some hosts, the NTFS volume) on newer Windows builds (observed on
# 26200); Format-Volume -DriveLetter is reliable. Windows automount was
# disabled above (mountvol /N), so assigning a letter to a not-yet-formatted
# volume does NOT pop "You need to format the disk in drive X: before you
# can use it." — the popup the old format-first ordering was avoiding.

# EFI system partition (FAT32, 100 MB)
$efi = New-Partition -DiskNumber $disk.Number -Size 100MB `
                     -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$efi | Add-PartitionAccessPath -AssignDriveLetter
$efiLetter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $efi.PartitionNumber).DriveLetter
Format-Volume -DriveLetter $efiLetter -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null

# MSR (16 MB, no letter)
New-Partition -DiskNumber $disk.Number -Size 16MB `
              -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null

# Windows partition (rest, NTFS)
$win = New-Partition -DiskNumber $disk.Number -UseMaximumSize `
                     -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$win | Add-PartitionAccessPath -AssignDriveLetter
$winLetter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $win.PartitionNumber).DriveLetter
Format-Volume -DriveLetter $winLetter -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null

# --- Apply image + boot files ------------------------------------------
# Announce the apply target: the Windows volume letter and the image's
# uncompressed apply size in bytes. Expand-WindowsImage reports progress via
# DISM's native callback, which does NOT reach the runspace progress stream,
# so the GUI can't read a % from the cmdlet. Instead it polls this volume's
# used space against the size below for a real apply percentage.
$applyBytes = 0
try { $applyBytes = [long]$imgDetail.ImageSize } catch { $applyBytes = 0 }
Write-Host "Apply target: ${winLetter} $applyBytes"
Write-Host "Applying image (this takes a while)..."
Expand-WindowsImage -ImagePath $installImg.FullName -Index $imgInfo.ImageIndex -ApplyPath "${winLetter}:\"

# Verify DISM apply actually wrote a complete Windows install.
# The SYSTEM registry hive is a load-bearing file every Windows boot
# needs — if it's missing or empty, the apply was interrupted and the
# VHDX is unusable (boots to "Recovery: system registry file is missing").
$systemHive = "${winLetter}:\Windows\System32\config\SYSTEM"
if (-not (Test-Path $systemHive)) {
    throw "DISM apply incomplete — $systemHive does not exist. The install.wim may be corrupt or the apply was interrupted."
}
$hiveSize = (Get-Item $systemHive).Length
if ($hiveSize -lt 100KB) {
    throw "DISM apply incomplete — $systemHive is only $hiveSize bytes (expected several MB). The apply was likely interrupted."
}
Write-Host "DISM apply verified (SYSTEM hive: $([int]($hiveSize/1KB)) KB)."

Write-Host "Writing UEFI boot files..."
# Invoke bcdboot via cmd.exe — direct PowerShell invocation has been
# observed to silently fail with exit 87 (invalid parameter) on some
# hosts due to argument parsing quirks. cmd.exe sidesteps them entirely.
$bcdCmd = "bcdboot ${winLetter}:\Windows /s ${efiLetter}: /f UEFI"
& cmd /c $bcdCmd
if ($LASTEXITCODE -ne 0) {
    throw "bcdboot failed with exit $LASTEXITCODE. Command attempted: $bcdCmd"
}
# Verify bcdboot actually wrote the boot files. Exit 0 has been observed
# with no files written in edge cases; without this check the VHDX boots
# straight to "Start PXE over IPv4" because the EFI partition is empty.
$bootMgr = "${efiLetter}:\EFI\Microsoft\Boot\bootmgfw.efi"
if (-not (Test-Path $bootMgr)) {
    throw "bcdboot reported success (exit 0) but $bootMgr was not written. EFI partition may not be FAT32 or may be unwriteable."
}
Write-Host "Boot files verified at $bootMgr."

# --- Cleanup ------------------------------------------------------------
Write-Host "Dismounting..."
# Robust dismount. wimserv.exe (Windows Imaging Service) frequently
# holds the VHDX open after DISM operations and prevents Hyper-V from
# using it as a differencing-disk parent. Kill it, then retry-loop
# the dismount until Get-VHD confirms Attached=$false. Throw clearly
# if we can't actually free the file — better than silently leaving
# the user with a locked VHDX that fails at VM-creation time.
Dismount-VHD -Path $OutVhdx -ErrorAction SilentlyContinue
Get-Process wimserv -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Seconds 1

$retry = 0
while (((Get-VHD -Path $OutVhdx -ErrorAction SilentlyContinue).Attached) -and $retry -lt 5) {
    Start-Sleep -Seconds 2
    Get-Process wimserv -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Dismount-VHD -Path $OutVhdx -ErrorAction SilentlyContinue
    $retry++
}
if ((Get-VHD -Path $OutVhdx -ErrorAction SilentlyContinue).Attached) {
    throw "Failed to dismount $OutVhdx after build. A process is still holding it open."
}

Dismount-DiskImage -ImagePath $iso | Out-Null

Write-Host "`nDone: $OutVhdx" -ForegroundColor Green
Write-Host "Attach to a Gen-2 Hyper-V VM with Secure Boot + TPM enabled."
}
finally {
    # Restore shell popups: re-enable automount and Shell Hardware Detection
    # (both disabled at the top of the build). Runs on success AND failure so
    # AutoPlay / format prompts are never left disabled system-wide.
    & mountvol /E | Out-Null
    if ($shellHWWasRunning) { Start-Service -Name ShellHWDetection -ErrorAction SilentlyContinue }
}
