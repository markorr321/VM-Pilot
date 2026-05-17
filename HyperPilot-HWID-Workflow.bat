@echo off
REM HyperPilot AutoPilot HWID Collection Workflow - Standalone Version
REM This is a self-contained batch file with embedded PowerShell script

REM Check for Administrator privileges and auto-elevate if needed
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)

echo Starting HyperPilot HWID Collection Workflow...
echo.

REM Check if running PowerShell 7, fallback to Windows PowerShell
where pwsh >nul 2>nul
if %errorlevel% == 0 (
    pwsh.exe -NoExit -ExecutionPolicy Bypass -Command "Invoke-Command -ScriptBlock ([ScriptBlock]::Create((Get-Content '%~f0' | Select-Object -Skip 25) -join [Environment]::NewLine))"
) else (
    powershell.exe -NoExit -ExecutionPolicy Bypass -Command "Invoke-Command -ScriptBlock ([ScriptBlock]::Create((Get-Content '%~f0' | Select-Object -Skip 25) -join [Environment]::NewLine))"
)
exit /b
:: ============== PowerShell Script Below This Line ==============

# HyperPilot AutoPilot HWID Collection Workflow
# Complete workflow for collecting AutoPilot HWID from HyperPilot VMs
# This script handles the entire process:
# 1. Copy batch scripts TO VM
# 2. Wait for you to run the scripts on the VM
# 3. Copy generated CSV files FROM VM

# Configuration variables (you can modify these as needed)
$VMName = $null  # Will prompt for VM selection if not set
$CreateNew = $false  # Set by the mode prompt below
$FilesToCopy = @("C:\Autopilot HWID Collection\AutoPilotHWID-Collection.bat")
$SearchPattern = "AutoPilotHWID*"
$SourceFolder = "HWID"
$DestinationPath = "C:\Autopilot HWID Collection"

# Separator line
$separator = "=" * 80

Write-Host "`n$separator" -ForegroundColor Cyan
Write-Host "  HyperPilot HWID Collection Workflow" -ForegroundColor Cyan
Write-Host "$separator" -ForegroundColor Cyan

# ============================================================================
# STEP 0: CHOOSE MODE (create new VM vs. pick existing)
# ============================================================================

Write-Host "`nHow would you like to proceed?" -ForegroundColor Cyan
Write-Host "  [1] Create a new VM (via HyperV.VMFactory) and then collect HWID" -ForegroundColor Yellow
Write-Host "  [2] Use an existing VM" -ForegroundColor Yellow

do {
    $modeSel = Read-Host "`nSelect option (1-2)"
} while ($modeSel -ne '1' -and $modeSel -ne '2')

if ($modeSel -eq '1') { $CreateNew = $true }

# ============================================================================
# STEP 0.5: CREATE NEW VM (HyperV.VMFactory)
# ============================================================================

if ($CreateNew) {
    Write-Host "`n$separator" -ForegroundColor Cyan
    Write-Host "  PHASE 0: Create New VM" -ForegroundColor Cyan
    Write-Host "$separator" -ForegroundColor Cyan

    # Ensure HyperV.VMFactory module is available
    if (-not (Get-Module -ListAvailable -Name HyperV.VMFactory)) {
        Write-Host "`nHyperV.VMFactory module not found. Installing from PSGallery..." -ForegroundColor Yellow
        try {
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
            }
            Install-Module -Name HyperV.VMFactory -Scope CurrentUser -Force -ErrorAction Stop
            Write-Host "✓ Module installed" -ForegroundColor Green
        } catch {
            Write-Error "Failed to install HyperV.VMFactory: $_"
            exit 1
        }
    }
    Import-Module HyperV.VMFactory -ErrorAction Stop

    # Prompt: VM name (must not collide with an existing VM)
    do {
        $newVMName = Read-Host "`nName for new VM"
        if ([string]::IsNullOrWhiteSpace($newVMName)) {
            Write-Host "VM name cannot be empty." -ForegroundColor Red
            $nameInvalid = $true
        } elseif (Get-VM -Name $newVMName -ErrorAction SilentlyContinue) {
            Write-Host "A VM named '$newVMName' already exists. Choose another name." -ForegroundColor Red
            $nameInvalid = $true
        } else {
            $nameInvalid = $false
        }
    } while ($nameInvalid)

    # VM storage path: always C:\VMs, auto-created if missing
    $VMPath = "C:\VMs"
    if (-not (Test-Path $VMPath)) {
        try {
            New-Item -Path $VMPath -ItemType Directory -Force | Out-Null
            Write-Host "Created VM storage folder: $VMPath" -ForegroundColor Green
        } catch {
            Write-Error "Could not create $VMPath : $_"
            exit 1
        }
    }

    # Virtual switch: prefer "Default Switch"; fall back to prompt if missing or ambiguous
    $switches = @(Get-VMSwitch)
    if ($switches.Count -eq 0) {
        Write-Error "No Hyper-V virtual switches found. Create one in Hyper-V Manager first."
        exit 1
    }
    $defaultSwitch = $switches | Where-Object Name -eq 'Default Switch' | Select-Object -First 1
    if ($defaultSwitch) {
        $VMSwitchName = $defaultSwitch.Name
        Write-Host "Using virtual switch: $VMSwitchName" -ForegroundColor Green
    } else {
        Write-Host "`nAvailable virtual switches:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $switches.Count; $i++) {
            Write-Host ("  [{0}] {1,-30} Type: {2}" -f ($i + 1), $switches[$i].Name, $switches[$i].SwitchType) -ForegroundColor Yellow
        }
        do {
            $swSel = Read-Host "Select switch number (1-$($switches.Count))"
            $swNum = 0
            $swValid = [int]::TryParse($swSel, [ref]$swNum) -and $swNum -ge 1 -and $swNum -le $switches.Count
            if (-not $swValid) { Write-Host "Invalid selection." -ForegroundColor Red }
        } while (-not $swValid)
        $VMSwitchName = $switches[$swNum - 1].Name
    }

    # Prompt: boot source (ISO for fresh install OR parent VHDX for differencing disk)
    $defaultBootSource = "C:\HyperPilot\Templates\24H2.vhdx"
    do {
        $bootInput = Read-Host "Boot source (.iso for fresh install, .vhdx for sysprepped template) [default: $defaultBootSource]"
        $bootSource = if ([string]::IsNullOrWhiteSpace($bootInput)) { $defaultBootSource } else { $bootInput }
        if (-not (Test-Path $bootSource -PathType Leaf)) {
            Write-Host "File not found: $bootSource" -ForegroundColor Red
            $bootValid = $false
        } else {
            $ext = [System.IO.Path]::GetExtension($bootSource).ToLowerInvariant()
            if ($ext -ne '.iso' -and $ext -ne '.vhdx') {
                Write-Host "Unsupported extension: $ext (must be .iso or .vhdx)" -ForegroundColor Red
                $bootValid = $false
            } else {
                $bootValid = $true
            }
        }
    } while (-not $bootValid)
    $useParentDisk = ([System.IO.Path]::GetExtension($bootSource).ToLowerInvariant() -eq '.vhdx')

    # CPU cores
    do {
        $cpuIn = Read-Host "`nCPU Cores [1, 2, 4] (default 2)"
        if ([string]::IsNullOrWhiteSpace($cpuIn)) { $cpuCount = 2; break }
        $n = 0
        if ([int]::TryParse($cpuIn, [ref]$n) -and ($n -in 1,2,4)) { $cpuCount = $n; break }
        Write-Host "Invalid. Must be 1, 2, or 4." -ForegroundColor Red
    } while ($true)

    # RAM
    do {
        $ramIn = Read-Host "RAM in GB [4, 8, 16] (default 4)"
        if ([string]::IsNullOrWhiteSpace($ramIn)) { $ramGB = 4; break }
        $n = 0
        if ([int]::TryParse($ramIn, [ref]$n) -and ($n -in 4,8,16)) { $ramGB = $n; break }
        Write-Host "Invalid. Must be 4, 8, or 16." -ForegroundColor Red
    } while ($true)
    $memBytes = [int64]$ramGB * 1GB

    # ISO path also needs OS disk size; parent-disk path inherits from the template
    if (-not $useParentDisk) { $diskBytes = 64GB }

    # Show config summary and confirm before creating
    $bootKind = if ($useParentDisk) { "$bootSource (parent VHDX)" } else { "$bootSource (ISO)" }
    Write-Host "`n$separator" -ForegroundColor Cyan
    Write-Host "  VM Configuration Summary" -ForegroundColor Cyan
    Write-Host "$separator" -ForegroundColor Cyan
    Write-Host ("  VM Name:        {0}" -f $newVMName)     -ForegroundColor Yellow
    Write-Host ("  Storage path:   {0}" -f $VMPath)        -ForegroundColor Yellow
    Write-Host ("  Switch:         {0}" -f $VMSwitchName)  -ForegroundColor Yellow
    Write-Host ("  Boot source:    {0}" -f $bootKind)      -ForegroundColor Yellow
    Write-Host ("  CPU Cores:      {0}" -f $cpuCount)      -ForegroundColor Yellow
    Write-Host ("  RAM:            {0} GB" -f $ramGB)      -ForegroundColor Yellow
    Write-Host ("  Generation:     2")                     -ForegroundColor Yellow
    Write-Host ("  TPM:            Enabled")               -ForegroundColor Yellow
    if (-not $useParentDisk) {
        Write-Host ("  OS Disk:        {0} GB" -f ($diskBytes / 1GB)) -ForegroundColor Yellow
    }
    Write-Host "$separator" -ForegroundColor Cyan

    $confirm = Read-Host "Proceed with VM creation? [Y/n]"
    if ($confirm -match '^[Nn]') {
        Write-Host "Aborted by user." -ForegroundColor Red
        exit 0
    }

    # Create the VM (route to -ParentDisk for VHDX, -ISOPath for ISO)
    # For VHDX path we delay PowerOn until after unattend.xml is injected.
    Write-Host "`nCreating VM '$newVMName'..." -ForegroundColor Cyan
    $newVMArgs = @{
        VMName               = $newVMName
        Path                 = $VMPath
        VMSwitch             = $VMSwitchName
        VMGeneration         = 2
        VMProcessorCount     = $cpuCount
        VMMemoryStartupBytes = $memBytes
        ErrorAction          = 'Stop'
    }
    if ($useParentDisk) {
        $newVMArgs['ParentDisk'] = $bootSource
    } else {
        $newVMArgs['ISOPath']         = $bootSource
        $newVMArgs['OSDiskSizeBytes'] = $diskBytes
        $newVMArgs['PowerOnVM']       = $true
    }
    try {
        New-HyperVVM @newVMArgs
        Write-Host "✓ VM created" -ForegroundColor Green
    } catch {
        Write-Error "VM creation failed: $_"
        exit 1
    }

    $VMName = $newVMName

    if ($useParentDisk) {
        # --- Inject the collection bat into the child VHDX, then boot ---
        Write-Host "`nInjecting collection scripts..." -ForegroundColor Cyan

        $childVhd = (Get-VMHardDiskDrive -VMName $newVMName | Select-Object -First 1).Path
        if (-not $childVhd -or -not (Test-Path $childVhd)) {
            Write-Error "Could not locate child VHDX for $newVMName"
            exit 1
        }

        # Validate every file we plan to inject exists on the host first
        foreach ($f in $FilesToCopy) {
            if (-not (Test-Path $f -PathType Leaf)) {
                Write-Error "Source file not found on host: $f"
                exit 1
            }
        }

        # Mount via folder access path (no drive letter — avoids Explorer auto-open popup)
        $mountFolder = Join-Path $env:TEMP "HWID-Inject-$(Get-Random)"
        New-Item -Path $mountFolder -ItemType Directory -Force | Out-Null

        try {
            Mount-VHD -Path $childVhd -NoDriveLetter -ErrorAction Stop
        } catch {
            Write-Error "Failed to mount child VHDX: $_"
            Remove-Item $mountFolder -Force -Recurse -ErrorAction SilentlyContinue
            exit 1
        }

        $injectedPaths = @()
        $partition = $null
        try {
            $vhdFile  = Split-Path $childVhd -Leaf
            $disk     = Get-Disk | Where-Object { $_.Location -like "*$vhdFile*" }
            $partition = $disk | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
            if (-not $partition) { throw "Could not find Windows partition on $childVhd" }

            Add-PartitionAccessPath -InputObject $partition -AccessPath $mountFolder -ErrorAction Stop
            Start-Sleep -Seconds 1

            foreach ($src in $FilesToCopy) {
                $leaf = Split-Path $src -Leaf
                $dst  = Join-Path $mountFolder $leaf
                Copy-Item -Path $src -Destination $dst -Force
                $injectedPaths += "C:\$leaf"
            }

            # Also drop the first bat as %WINDIR%\Setup\Scripts\SetupComplete.cmd
            # so Windows auto-runs it after specialize (before OOBE).
            $setupScriptsDir = Join-Path $mountFolder "Windows\Setup\Scripts"
            if (-not (Test-Path $setupScriptsDir)) {
                New-Item -Path $setupScriptsDir -ItemType Directory -Force | Out-Null
            }
            $setupCompletePath = Join-Path $setupScriptsDir "SetupComplete.cmd"
            Copy-Item -Path $FilesToCopy[0] -Destination $setupCompletePath -Force
            Write-Host "✓ Scripts injected" -ForegroundColor Green
        } finally {
            if ($partition) {
                Remove-PartitionAccessPath -InputObject $partition -AccessPath $mountFolder -ErrorAction SilentlyContinue
            }
            Dismount-VHD -Path $childVhd -ErrorAction SilentlyContinue
            Remove-Item $mountFolder -Force -Recurse -ErrorAction SilentlyContinue
        }

        # Phase 1 (Copy-VMFile) is unnecessary now — the bat is already on the disk.
        $SkipPhase1 = $true

        # Boot the VM (will run collection via specialize, then shut itself down)
        Write-Host "`nStarting VM..." -ForegroundColor Cyan
        Start-VM -Name $newVMName -ErrorAction Stop
        Write-Host "✓ VM started" -ForegroundColor Green

        # Auto-launch vmconnect so the user can watch progress
        try {
            Start-Process vmconnect.exe -ArgumentList 'localhost', $newVMName -ErrorAction Stop
        } catch {
            Write-Warning "Could not auto-launch vmconnect: $_"
        }

        # Poll for VM to shut itself down after RunSynchronousCommand completes
        Write-Host "`nWaiting for collection to complete..." -ForegroundColor Yellow
        $maxWait = 900  # 15 minutes
        $elapsed = 0
        $shutdown = $false
        while ($elapsed -lt $maxWait) {
            $state = (Get-VM -Name $newVMName -ErrorAction SilentlyContinue).State
            if ($state -eq 'Off') { $shutdown = $true; break }
            Start-Sleep -Seconds 5
            $elapsed += 5
            if ($elapsed -eq 60 -or $elapsed % 120 -eq 0) {
                Write-Host "  ...still waiting (${elapsed}s)" -ForegroundColor Gray
            }
        }
        if (-not $shutdown) {
            Write-Warning "VM did not shut down within $maxWait seconds. Forcing off."
            Stop-VM -Name $newVMName -TurnOff -Force -ErrorAction SilentlyContinue
        }
        Write-Host "✓ Collection complete" -ForegroundColor Green
    } else {
        # ISO install path — still requires a human at vmconnect
        Write-Host "`n$separator" -ForegroundColor Yellow
        Write-Host "  MANUAL STEP: Install Windows on the VM" -ForegroundColor Yellow
        Write-Host "$separator" -ForegroundColor Yellow
        Write-Host "Open 'vmconnect.exe' or Hyper-V Manager and complete the Windows install on" -ForegroundColor White
        Write-Host "VM '$VMName' until you reach the desktop (Guest Services need to be running)." -ForegroundColor White
        Read-Host "`nPress Enter once the VM is at the desktop to continue with HWID collection"
    }
}

# Default: don't skip Phase 1 unless the parent-disk path set it above
if (-not (Get-Variable -Name SkipPhase1 -Scope Local -ErrorAction SilentlyContinue) -and
    -not (Get-Variable -Name SkipPhase1 -Scope Script -ErrorAction SilentlyContinue)) {
    $SkipPhase1 = $false
}

# ============================================================================
# STEP 1: SELECT VM
# ============================================================================

if (-not $VMName) {
    $vms = Get-VM | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime
    
    if ($vms.Count -eq 0) {
        Write-Error "No VMs found"
        exit 1
    }
    
    Write-Host "`nAvailable VMs:" -ForegroundColor Cyan
    Write-Host "$separator" -ForegroundColor Cyan
    
    for ($i = 0; $i -lt $vms.Count; $i++) {
        $vm = $vms[$i]
        $memoryGB = [math]::Round($vm.MemoryAssigned / 1GB, 2)
        Write-Host ("  [{0}] {1,-30} State: {2,-10} CPU: {3}% Memory: {4}GB" -f 
            ($i + 1), 
            $vm.Name, 
            $vm.State, 
            $vm.CPUUsage, 
            $memoryGB) -ForegroundColor Yellow
    }
    
    Write-Host "$separator" -ForegroundColor Cyan
    
    do {
        $selection = Read-Host "`nSelect VM number (1-$($vms.Count))"
        $selectionNum = 0
        $validSelection = [int]::TryParse($selection, [ref]$selectionNum) -and 
                         $selectionNum -ge 1 -and 
                         $selectionNum -le $vms.Count
        
        if (-not $validSelection) {
            Write-Host "Invalid selection. Please enter a number between 1 and $($vms.Count)" -ForegroundColor Red
        }
    } while (-not $validSelection)
    
    $VMName = $vms[$selectionNum - 1].Name
    Write-Host "Selected: $VMName" -ForegroundColor Green
}

# Verify VM exists
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Error "VM '$VMName' not found"
    exit 1
}

if (-not $SkipPhase1) {

Write-Host "`n$separator" -ForegroundColor Cyan
Write-Host "  PHASE 1: Copy Scripts TO VM" -ForegroundColor Cyan
Write-Host "$separator" -ForegroundColor Cyan
Write-Host "Target VM: $VMName" -ForegroundColor Green
Write-Host "VM State: $($vm.State)" -ForegroundColor Yellow

# ============================================================================
# STEP 2: COPY FILES TO VM
# ============================================================================

# Check if VM needs to be started
if ($vm.State -ne "Running") {
    Write-Host "`nStarting VM..." -ForegroundColor Yellow
    
    # Handle "Starting" state - wait for it to finish starting
    if ($vm.State -eq "Starting") {
        Write-Host "VM is already starting, waiting for it to be ready..." -ForegroundColor Yellow
        $waitTime = 0
        while ((Get-VM -Name $VMName).State -eq "Starting" -and $waitTime -lt 60) {
            Start-Sleep -Seconds 2
            $waitTime += 2
        }
        $vm = Get-VM -Name $VMName
    } else {
        # VM is Off or other state, start it
        Start-VM -Name $VMName
    }
    
    # Wait for VM to be fully running
    Write-Host "Waiting for VM to start" -NoNewline
    $vmStartTimeout = 60
    $vmStartElapsed = 0
    while ((Get-VM -Name $VMName).State -ne "Running" -and $vmStartElapsed -lt $vmStartTimeout) {
        Start-Sleep -Seconds 1
        Write-Host "." -NoNewline
        $vmStartElapsed++
    }
    Write-Host ""
    
    if ((Get-VM -Name $VMName).State -eq "Running") {
        Write-Host "✓ VM is running" -ForegroundColor Green
        Write-Host "Waiting for VM to fully initialize (30 seconds)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        Write-Host "✓ VM ready" -ForegroundColor Green
    } else {
        Write-Warning "VM did not fully start"
    }
} else {
    Write-Host "`n✓ VM is already running and ready" -ForegroundColor Green
}

# Enable Guest Services if not already enabled
Write-Host "`nEnabling Guest Services..." -ForegroundColor Cyan
try {
    Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue
    Write-Host "✓ Guest Services enabled" -ForegroundColor Green
} catch {
    Write-Warning "Could not enable Guest Services: $_"
}

# Wait a moment for services to initialize
Start-Sleep -Seconds 2

# Verify Guest Services status
$guestService = Get-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"
if ($guestService.Enabled -and $guestService.PrimaryOperationalStatus -eq "Ok") {
    Write-Host "✓ Guest Services operational" -ForegroundColor Green
} else {
    Write-Warning "Guest Services may not be fully operational"
}

# Copy each file
Write-Host "`nCopying files to VM..." -ForegroundColor Cyan
$successCount = 0
$failCount = 0

foreach ($sourceFile in $FilesToCopy) {
    if (Test-Path $sourceFile) {
        $fileName = Split-Path $sourceFile -Leaf
        $destPath = "C:\$fileName"
        
        try {
            Write-Host "  Copying: $fileName" -ForegroundColor Yellow
            Copy-VMFile -Name $VMName -SourcePath $sourceFile -DestinationPath $destPath -FileSource Host -CreateFullPath -Force -ErrorAction Stop
            Write-Host "  ✓ Success: $fileName" -ForegroundColor Green
            $successCount++
        } catch {
            Write-Host "  ✗ Failed: $fileName - $($_.Exception.Message)" -ForegroundColor Red
            $failCount++
        }
    } else {
        Write-Host "  ✗ File not found: $sourceFile" -ForegroundColor Red
        $failCount++
    }
}

Write-Host "`n✓ Phase 1 Complete: $successCount files copied to VM" -ForegroundColor Green

if ($failCount -gt 0) {
    Write-Host "⚠ Warning: $failCount files failed to copy" -ForegroundColor Yellow
}

# ============================================================================
# STEP 3: USER RUNS SCRIPT ON VM
# ============================================================================

$batFileName = Split-Path $FilesToCopy[0] -Leaf
Write-Host "`n✓ Script copied to VM: C:\$batFileName" -ForegroundColor Green
Write-Host "Run the .bat file on the Hyper-V VM, then press Enter to continue" -ForegroundColor Yellow

Read-Host "`nPress Enter to continue"

} # end if (-not $SkipPhase1)

# ============================================================================
# STEP 4: COPY FILES FROM VM
# ============================================================================

Write-Host "`nExtracting CSV..." -ForegroundColor Cyan

$vm = Get-VM -Name $VMName
$vhdPath = ($vm | Select-Object -ExpandProperty HardDrives).Path
if (-not $vhdPath) {
    Write-Error "Could not determine VHD path"
    exit 1
}

# Stop VM if still running
if ($vm.State -eq "Running") {
    Stop-VM -Name $VMName -Force
    $timeout = 60; $elapsed = 0
    while ((Get-VM -Name $VMName).State -ne "Off" -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 1; $elapsed++
    }
    if ((Get-VM -Name $VMName).State -ne "Off") {
        Write-Error "VM did not stop within timeout period"
        exit 1
    }
    Start-Sleep -Seconds 3
}

# Mount VHD read-only without drive letter (avoids Explorer popup)
for ($i = 1; $i -le 3; $i++) {
    try {
        Mount-VHD -Path $vhdPath -ReadOnly -NoDriveLetter -ErrorAction Stop
        break
    } catch {
        if ($i -lt 3) { Start-Sleep -Seconds 2 }
        else { Write-Error "Failed to mount VHD after 3 attempts: $_"; exit 1 }
    }
}

# Attach via temp folder mount point (avoids Explorer auto-open popup)
$mountFolder = Join-Path $env:TEMP "HWID-Extract-$(Get-Random)"
New-Item -Path $mountFolder -ItemType Directory -Force | Out-Null
$partition = $null
try {
    $vhdFileName = Split-Path $vhdPath -Leaf
    $disk = Get-Disk | Where-Object {$_.Location -like "*$vhdFileName*"}
    $partition = $disk | Get-Partition | Where-Object {$_.Size -gt 50GB} | Select-Object -First 1
    if (-not $partition) { throw "Could not find suitable partition" }
    Add-PartitionAccessPath -InputObject $partition -AccessPath $mountFolder -ErrorAction Stop
    Start-Sleep -Seconds 1
} catch {
    Write-Error "Failed to attach VHD mount point: $_"
    Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
    Remove-Item $mountFolder -Force -Recurse -ErrorAction SilentlyContinue
    exit 1
}

# Find newest matching file
$collectedCount = 0
try {
    $sourcePath = $mountFolder
    if ($SourceFolder) {
        $searchPath = Join-Path $sourcePath $SourceFolder
        if (Test-Path $searchPath) { $sourcePath = $searchPath }
    }
    $files = Get-ChildItem -Path $sourcePath -Filter $SearchPattern -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if ($files.Count -eq 0) {
        Write-Warning "No files matching '$SearchPattern' found on the VM"
    } else {
        $newestFile = $files[0]
        if (-not (Test-Path $DestinationPath)) {
            New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
        }
        try {
            Copy-Item -Path $newestFile.FullName -Destination (Join-Path $DestinationPath $newestFile.Name) -Force
            Write-Host "✓ Copied: $($newestFile.Name)" -ForegroundColor Green
            $collectedCount = 1
        } catch {
            Write-Host "✗ Failed to copy $($newestFile.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} finally {
    if ($partition) {
        Remove-PartitionAccessPath -InputObject $partition -AccessPath $mountFolder -ErrorAction SilentlyContinue
    }
    Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
    Remove-Item $mountFolder -Force -Recurse -ErrorAction SilentlyContinue
}

# Start the VM so it's ready to use after the workflow exits
Start-VM -Name $VMName -ErrorAction SilentlyContinue

# ============================================================================
# FINAL SUMMARY
# ============================================================================

if ($collectedCount -gt 0) {
    Write-Host "`n✓ Done. HWID saved to: $DestinationPath" -ForegroundColor Green
} else {
    Write-Host "`n⚠ No files were collected from the VM" -ForegroundColor Yellow
}

Write-Host "`nPress Enter to Exit" -ForegroundColor Red -NoNewline
Read-Host
[Environment]::Exit(0)
