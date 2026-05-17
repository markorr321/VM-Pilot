
<#
.SYNOPSIS
  Downloads a Windows 11 ISO (24H2 or 25H2, current channel) and builds a Gen-2/UEFI VHDX.

.EXAMPLE
  .\Get-Win11VHDX.ps1 -Release 25H2 -Edition Pro -OutVhdx C:\VMs\Win11-25H2.vhdx
#>
[CmdletBinding()]
param(
    [ValidateSet('24H2','25H2')] [string]$Release  = '25H2',
    [ValidateSet('Home','Pro')]  [string]$Edition  = 'Pro',
    [string]$Language = 'English',
    [int]   $SizeGB   = 64,
    [string]$WorkDir  = 'C:\Tools\WinVHDX',
    [string]$OutVhdx  = "C:\VMs\Win11-$Release.vhdx",
    # Pre-supplied ISO. If provided, skips Fido + download entirely and
    # DISM-applies the existing file. Lets the GUI feed an ISO from any
    # source (UUP Dump, Visual Studio, VLSC, USB drive, etc.).
    [string]$IsoPath
)

$ErrorActionPreference = 'Stop'

# --- Admin check ---------------------------------------------------------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an elevated PowerShell — VHDX mount + DISM require admin."
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
# If -IsoPath was supplied (e.g. from UUP Dump or a hand-picked file), use
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

# --- Create + partition VHDX -------------------------------------------
if (Test-Path $OutVhdx) { Remove-Item $OutVhdx -Force }

Write-Host "Creating $OutVhdx ($SizeGB GB, dynamic)..."
$vhd  = New-VHD -Path $OutVhdx -SizeBytes ($SizeGB * 1GB) -Dynamic
# Disable Windows automount before Mount-VHD. Even on a fresh GPT disk,
# Windows's shell can pop "format disk in drive X:" while we're partitioning
# if it tries to auto-letter a partition mid-format. Restored at script end.
& mountvol /N | Out-Null
$disk = Mount-VHD -Path $OutVhdx -Passthru | Get-Disk
Initialize-Disk -Number $disk.Number -PartitionStyle GPT

# Create + format + assign letter in that ORDER. Assigning the letter at
# partition-create time (via -AssignDriveLetter) makes Windows see an
# unformatted volume and pop "You need to format the disk in drive X:
# before you can use it." Formatting first and assigning the letter after
# avoids the popup entirely.

# EFI system partition (FAT32, 100 MB)
$efi = New-Partition -DiskNumber $disk.Number -Size 100MB `
                     -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
$efi | Add-PartitionAccessPath -AssignDriveLetter
$efiLetter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $efi.PartitionNumber).DriveLetter

# MSR (16 MB, no letter)
New-Partition -DiskNumber $disk.Number -Size 16MB `
              -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null

# Windows partition (rest, NTFS)
$win = New-Partition -DiskNumber $disk.Number -UseMaximumSize `
                     -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
Format-Volume -Partition $win -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
$win | Add-PartitionAccessPath -AssignDriveLetter
$winLetter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $win.PartitionNumber).DriveLetter

# --- Apply image + boot files ------------------------------------------
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

# Restore Windows automount (was disabled before Mount-VHD)
& mountvol /E | Out-Null

Write-Host "`nDone: $OutVhdx" -ForegroundColor Green
Write-Host "Attach to a Gen-2 Hyper-V VM with Secure Boot + TPM enabled."
