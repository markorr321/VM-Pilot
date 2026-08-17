<#
.SYNOPSIS
  Downloads Windows 11 install media (25H2 or 24H2) from Microsoft and builds
  a Gen-2/UEFI VHDX from it.

.DESCRIPTION
  With no media parameters the download is fully automatic. The heavy lifting
  is David Segura's OSD module (github.com/OSDeploy/OSD) -- the module behind
  OSDCloud -- which supplies Microsoft's Feature Update catalog. Its
  Get-FeatureUpdate resolves a release/channel/language into a direct download
  URL on dl.delivery.mp.microsoft.com plus the expected SHA256: the same media
  Windows Update itself serves. That replaced the old Fido path, which scraped
  Microsoft's public download page and broke whenever that page IP-blocked the
  caller (error 715-123130).

  OSD is GPL-3.0 and is installed from PowerShell Gallery at runtime; no part
  of it is bundled or redistributed with VM-Pilot.

  The catalog serves an .esd. DISM applies an .esd directly, so that path skips
  the ISO mount entirely. A hand-supplied .iso still works via -IsoPath /
  -PickIso and is mounted as before.

.EXAMPLE
  # Fully automatic: download 25H2 media and build C:\VMs\Win11-25H2.vhdx
  .\Get-Win11VHDX.ps1

.EXAMPLE
  # Same, for 24H2 -> C:\VMs\Win11-24H2.vhdx. Both parents can coexist.
  .\Get-Win11VHDX.ps1 -Release 24H2

.EXAMPLE
  .\Get-Win11VHDX.ps1 -Release 25H2 -Edition Pro -OutVhdx C:\VMs\Win11-25H2.vhdx

.EXAMPLE
  # Browse to an existing ISO with a file picker instead of downloading.
  # The VHDX is auto-named after the Windows release detected inside the
  # picked ISO (e.g. C:\VMs\Win11-25H2.vhdx) unless you pin -OutVhdx:
  .\Get-Win11VHDX.ps1 -PickIso

.LINK
  https://github.com/OSDeploy/OSD

.NOTES
  Media resolution and download URLs courtesy of the OSD module by David Segura
  (@OSDeploy), author of OSDCloud. Go star it: https://github.com/OSDeploy/OSD
#>
[CmdletBinding()]
param(
    [ValidateSet('25H2','24H2')] [string]$Release  = '25H2',
    [ValidateSet('Home','Pro')]  [string]$Edition  = 'Pro',
    # Licensing channel for downloaded media. Retail is the default because it
    # assumes no volume-licensing agreement; pass Volume if you hold one.
    [ValidateSet('Retail','Volume')] [string]$OSActivation = 'Retail',
    # Media language, in OSD's culture form (en-us, de-de, fr-fr, ...).
    # Deliberately not ValidateSet'd here -- OSD owns the authoritative list
    # and validates it, so this can't drift as that list changes.
    [string]$OSLanguage = 'en-us',
    [int]   $SizeGB   = 64,
    [string]$WorkDir  = 'C:\Tools\WinVHDX',
    [string]$OutVhdx  = "C:\VMs\Win11-$Release.vhdx",
    # Pre-supplied media. If provided, skips the download entirely and
    # DISM-applies the existing file. Lets the GUI feed media from any source
    # (Microsoft Software Download page, Visual Studio, VLSC, USB, etc.).
    # An .iso is mounted; an .esd/.wim is applied directly.
    [string]$IsoPath,
    # Pop a Windows "Open file" dialog to pick the media interactively. Sets
    # $IsoPath from whatever the user selects, then follows the same
    # supplied-media path as -IsoPath (skips the download).
    [switch]$PickIso
)

$ErrorActionPreference = 'Stop'

# Captured before anything can reassign $Release (the detect step below does).
# Distinguishes "caller asked for this release" from "caller took the default",
# which decides whether a release mismatch in supplied media is an error.
$releaseWasExplicit = $PSBoundParameters.ContainsKey('Release')

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
        $dlg.Title  = 'Select the Windows install media to convert'
        $dlg.Filter = 'Windows install media (*.iso;*.esd;*.wim)|*.iso;*.esd;*.wim|All files (*.*)|*.*'
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

# --- Resolve install media ----------------------------------------------
# If -IsoPath was supplied (e.g. a hand-picked ISO from the SETUP wizard), use
# that and skip the download flow entirely.
if ($IsoPath) {
    if (-not (Test-Path $IsoPath -PathType Leaf)) {
        throw "Supplied -IsoPath does not exist: $IsoPath"
    }
    $media = $IsoPath
    Write-Host "Using supplied ISO: $media"
} else {
    # --- Ensure the OSD module ------------------------------------------
    # OSD carries Microsoft's Feature Update catalog. Get-FeatureUpdate turns
    # a release/channel/language into a direct dl.delivery.mp.microsoft.com
    # URL plus the expected SHA256 -- the same media Windows Update serves.
    if (-not (Get-Module -ListAvailable -Name OSD)) {
        Write-Host "Installing OSD module from PowerShell Gallery..."
        # Install-Module bootstraps the NuGet provider with a Y/N prompt on a
        # clean host. That prompt has no console to render into when the GUI
        # runs this in a runspace, so it would hang the build -- install the
        # provider up front instead.
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        Install-Module -Name OSD -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module OSD -ErrorAction Stop
    Write-Host "OSD module version: $((Get-Module OSD).Version)"

    # OSD names releases "Windows 11 <ReleaseID> x64".
    $osName = "Windows 11 $Release x64"
    Write-Host "Resolving $osName $OSActivation ($OSLanguage) from Microsoft's catalog..."
    # Get-FeatureUpdate warns and returns nothing rather than throwing when
    # it can't match or can't reach the catalog, so check the result.
    $fu = Get-FeatureUpdate -OSName $osName -OSActivation $OSActivation -OSLanguage $OSLanguage
    if (-not $fu -or -not $fu.Url) {
        throw "OSD could not resolve install media for '$osName' ($OSActivation, $OSLanguage). Check internet connectivity, or supply your own media with -PickIso."
    }
    Write-Host "Catalog match: $($fu.Name)"

    $media = Join-Path $WorkDir $fu.FileName

    # Reuse a previous download only when it still matches the catalog hash.
    # A truncated or superseded file would otherwise surface much later as an
    # opaque DISM failure.
    $needDownload = $true
    if (Test-Path $media -PathType Leaf) {
        if ($fu.SHA256) {
            Write-Host "Verifying cached media..."
            if ((Get-FileHash -Path $media -Algorithm SHA256).Hash -ieq $fu.SHA256) {
                Write-Host "Reusing cached media: $media"
                $needDownload = $false
            } else {
                Write-Warning "Cached media failed its SHA256 check - re-downloading."
                Remove-Item $media -Force
            }
        } else {
            # No catalog hash to check against (24H2 entries currently ship
            # without one), so the cached file is taken on trust. Delete it and
            # re-run, or use -PickIso, if you suspect it.
            Write-Host "Reusing cached media (unverified - no catalog hash): $media"
            $needDownload = $false
        }
    }

    if ($needDownload) {
        Write-Host "Downloading media -> $media"
        # Use BITS so we can emit real % progress that the GUI parses and shows
        # on its progress bar. Falls back to Invoke-WebRequest if BITS is broken
        # or unavailable (rare — BITS is a default Windows service).
        $useBits = $true
        try { Import-Module BitsTransfer -ErrorAction Stop } catch { $useBits = $false }

        # Content length as reported by the transfer, used for the completeness
        # check below. 0 means "never learned it".
        $totalBytes = 0

        if ($useBits) {
            $bitsJob = Start-BitsTransfer -Source $fu.Url -Destination $media -DisplayName 'VMPilot-Win11Media' -Asynchronous
            try {
                # BITS reports BytesTotal as BG_SIZE_UNKNOWN ([uint64]::MaxValue,
                # 18446744073709551615) until the server's headers arrive -- which
                # is exactly what the first poll sees while the job is still
                # Connecting/Queued. Dividing that by 1MB yields 17592186044416,
                # which overflows [int] and used to abort the whole build. Treat
                # the sentinel as "size not known yet" and keep going; a real
                # total lands within a poll or two.
                $sizeUnknown = [uint64]::MaxValue
                while ($bitsJob.JobState -in 'Transferring','Connecting','Queued') {
                    $b = [uint64]$bitsJob.BytesTransferred
                    $t = [uint64]$bitsJob.BytesTotal
                    if ($t -gt 0 -and $t -ne $sizeUnknown) {
                        $totalBytes = $t
                        $pct = [int](($b / $t) * 100)
                        $cur = [int64]($b / 1MB)
                        $tot = [int64]($t / 1MB)
                        Write-Host "Download progress: $pct% ($cur / $tot MB)"
                    } else {
                        Write-Host "Download progress: unknown ($([int64]($b / 1MB)) MB so far)"
                    }
                    Start-Sleep -Seconds 2
                }
                if ($bitsJob.JobState -eq 'Transferred') {
                    Complete-BitsTransfer -BitsJob $bitsJob
                    Write-Host "Download progress: 100%"
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
            Invoke-WebRequest -Uri $fu.Url -OutFile $media
        }

        # Completeness check: did we get every byte the server promised? This
        # catches a truncated transfer, which is the failure the SHA256 check
        # below would otherwise catch -- except that not every catalog entry
        # has a hash (24H2 currently doesn't), so for those this is the only
        # check there is. It proves nothing about tampering; only the hash does.
        if ($totalBytes -gt 0) {
            $onDisk = (Get-Item $media).Length
            if ($onDisk -ne $totalBytes) {
                Remove-Item $media -Force -ErrorAction SilentlyContinue
                throw "Downloaded media is incomplete: got $onDisk bytes, server reported $totalBytes. The file was deleted - re-run to retry."
            }
            Write-Host "Download size verified ($onDisk bytes)."
        }

        # Verify against the catalog hash before spending 10 minutes applying
        # a corrupt image. Delete on mismatch so a re-run starts clean rather
        # than "reusing" the bad file.
        if ($fu.SHA256) {
            Write-Host "Verifying SHA256..."
            $actualHash = (Get-FileHash -Path $media -Algorithm SHA256).Hash
            if ($actualHash -ine $fu.SHA256) {
                Remove-Item $media -Force -ErrorAction SilentlyContinue
                throw "Downloaded media failed SHA256 verification (expected $($fu.SHA256), got $actualHash). The file was deleted - re-run to retry."
            }
            Write-Host "SHA256 verified."
        } else {
            # Not every catalog entry carries a hash (24H2 currently doesn't).
            # Say so plainly rather than letting silence imply a passed check --
            # the transport was still HTTPS-to-Microsoft either way.
            Write-Warning "Microsoft's catalog published no SHA256 for this release - skipping hash verification."
        }
    }
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

# --- Locate the Windows image -------------------------------------------
# An ISO has to be mounted so we can reach sources\install.wim|esd. Media from
# Microsoft's Feature Update catalog is already a standalone .esd -- it IS the
# image container, so DISM reads it directly and no mount is needed.
$mountedIso = $false
if ([System.IO.Path]::GetExtension($media) -ieq '.iso') {
    Write-Host "Mounting ISO..."
    $isoMount  = Mount-DiskImage -ImagePath $media -PassThru
    $mountedIso = $true
    $isoDrive  = ($isoMount | Get-Volume).DriveLetter
    $sources   = "${isoDrive}:\sources"
    $installImg = Get-ChildItem $sources -Filter 'install.*' |
                  Where-Object { $_.Name -in 'install.wim','install.esd' } |
                  Select-Object -First 1
    if (-not $installImg) { throw "No install.wim/install.esd under $sources" }
    $imagePath = $installImg.FullName
} else {
    Write-Host "Using downloaded image directly (no ISO mount needed)."
    $imagePath = $media
}

# Pick edition index
$editionName = if ($Edition -eq 'Pro') { 'Windows 11 Pro' } else { 'Windows 11 Home' }
$imgInfo = Get-WindowsImage -ImagePath $imagePath |
           Where-Object { $_.ImageName -eq $editionName } |
           Select-Object -First 1
if (-not $imgInfo) {
    $available = (Get-WindowsImage -ImagePath $imagePath).ImageName -join ', '
    throw "Edition '$editionName' not found in $imagePath. Available: $available. Re-run with -Edition set to one of those."
}
Write-Host "Using image index $($imgInfo.ImageIndex): $($imgInfo.ImageName)"

# --- Name the VHDX after the release actually inside the ISO -------------
# With -PickIso / -IsoPath the ISO can be any build, so the -Release param
# (and thus the default output name) may not reflect what's really inside.
# Read the image's build number, map it to a friendly release, and use that
# to name the VHDX. Only override the name when the caller did NOT pin
# -OutVhdx explicitly — the GUI always passes -OutVhdx, so it keeps full
# control of naming; this auto-naming only kicks in on direct invocation.
$imgDetail = Get-WindowsImage -ImagePath $imagePath -Index $imgInfo.ImageIndex
$imgBuild  = ([Version]$imgDetail.Version).Build
$buildToRelease = @{ 26200 = '25H2'; 26100 = '24H2' }
$detectedRelease = $buildToRelease[$imgBuild]
if ($detectedRelease) {
    Write-Host "Detected Windows 11 $detectedRelease (build $imgBuild) in image."
    # Downloaded media always matches by construction, but hand-supplied media
    # can be anything. When the caller named a release explicitly (the GUI
    # always does, to keep C:\VMs\Win11-<release>.vhdx honest), a mismatch is
    # an error rather than something to silently rename around.
    if ($releaseWasExplicit -and $detectedRelease -ne $Release) {
        throw "Requested -Release $Release but this media is Windows 11 $detectedRelease (build $imgBuild). Supply matching media, or re-run with -Release $detectedRelease."
    }
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
Write-Host "Applying image (this takes a while)..."

# Run dism.exe /Apply-Image directly so we can stream real percentage progress
# to the GUI. Expand-WindowsImage has no progress callback that reaches
# PowerShell streams; dism.exe emits its own CR-delimited progress lines which
# we parse and re-emit as "Apply progress: X%" for the GUI pipeline to consume.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = "$env:SystemRoot\System32\Dism.exe"
$psi.Arguments              = "/Apply-Image /ImageFile:`"$imagePath`" /Index:$($imgInfo.ImageIndex) /ApplyDir:${winLetter}:\"
$psi.UseShellExecute        = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow         = $true
$dismProc = [System.Diagnostics.Process]::Start($psi)

# DISM uses \r between progress updates when writing to a console; when
# redirected it may use \r or \n — read in chunks and split on both.
$buf     = New-Object char[] 256
$pending = New-Object System.Text.StringBuilder
$lastPct = -1
while ($true) {
    $read = $dismProc.StandardOutput.Read($buf, 0, $buf.Length)
    if ($read -eq 0) { break }
    for ($i = 0; $i -lt $read; $i++) {
        $ch = $buf[$i]
        if ($ch -eq [char]13 -or $ch -eq [char]10) {
            $line = $pending.ToString().Trim()
            [void]$pending.Clear()
            if ($line -match '\b(\d+(?:\.\d+)?)%') {
                $pct = [int][Math]::Round([double]$Matches[1])
                if ($pct -ne $lastPct) { Write-Host "Apply progress: $pct%"; $lastPct = $pct }
            }
        } else {
            [void]$pending.Append($ch)
        }
    }
}
$dismProc.WaitForExit()
if ($dismProc.ExitCode -ne 0) {
    $errText = try { $dismProc.StandardError.ReadToEnd().Trim() } catch { '' }
    throw "DISM /Apply-Image failed (exit $($dismProc.ExitCode))$(if ($errText) { ": $errText" })"
}

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

# Only the ISO path mounted anything; downloaded .esd media never was.
if ($mountedIso) { Dismount-DiskImage -ImagePath $media | Out-Null }

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
