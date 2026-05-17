# HyperPilot AutoPilot HWID Collection Workflow
# Complete workflow for collecting AutoPilot HWID from HyperPilot VMs
# This script handles the entire process:
# 1. Copy batch scripts TO VM
# 2. Wait for you to run the scripts on the VM
# 3. Copy generated CSV files FROM VM

param(
    [Parameter(Mandatory=$false)]
    [string]$VMName,

    [Parameter(Mandatory=$false)]
    [switch]$CreateNew,

    [Parameter(Mandatory=$false)]
    [string[]]$FilesToCopy = @(
        "C:\Autopilot HWID Collection\AutoPilotHWID-Collection.bat"
    ),

    [Parameter(Mandatory=$false)]
    [string]$SearchPattern = "AutoPilotHWID*",

    [Parameter(Mandatory=$false)]
    [string]$SourceFolder = "HWID",

    [Parameter(Mandatory=$false)]
    [string]$DestinationPath = "C:\Autopilot HWID Collection"
)

# Separator line
$separator = "=" * 80

# Auto-elevate to Administrator if not already
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Elevating to Administrator..." -ForegroundColor Yellow
    
    # Detect PowerShell version and use appropriate executable
    $psExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
    
    # Build argument list for parameters
    $argList = @("-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($VMName) { $argList += @("-VMName", "`"$VMName`"") }
    if ($CreateNew) { $argList += @("-CreateNew") }
    if ($SearchPattern -ne "AutoPilotHWID*") { $argList += @("-SearchPattern", "`"$SearchPattern`"") }
    if ($SourceFolder -ne "HWID") { $argList += @("-SourceFolder", "`"$SourceFolder`"") }
    if ($DestinationPath -ne "C:\Autopilot HWID Collection") { $argList += @("-DestinationPath", "`"$DestinationPath`"") }
    
    # Relaunch as administrator with same PowerShell version
    Start-Process $psExe -ArgumentList $argList -Verb RunAs
    
    # Force close the non-admin window
    [Environment]::Exit(0)
}

Write-Host "`n$separator" -ForegroundColor Cyan
Write-Host "  HyperPilot HWID Collection Workflow" -ForegroundColor Cyan
Write-Host "$separator" -ForegroundColor Cyan

# ============================================================================
# STEP 0: CHOOSE MODE (create new VM vs. pick existing)
# ============================================================================

if (-not $VMName -and -not $CreateNew) {
    Write-Host "`nHow would you like to proceed?" -ForegroundColor Cyan
    Write-Host "  [1] Create a new VM (via HyperV.VMFactory) and then collect HWID" -ForegroundColor Yellow
    Write-Host "  [2] Use an existing VM" -ForegroundColor Yellow

    do {
        $modeSel = Read-Host "`nSelect option (1-2)"
    } while ($modeSel -ne '1' -and $modeSel -ne '2')

    if ($modeSel -eq '1') { $CreateNew = $true }
}

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

    # Prompt: VM storage path
    $defaultVMPath = "C:\VMs"
    $vmPathInput = Read-Host "VM storage path [default: $defaultVMPath]"
    $VMPath = if ([string]::IsNullOrWhiteSpace($vmPathInput)) { $defaultVMPath } else { $vmPathInput }
    if (-not (Test-Path $VMPath)) {
        try {
            New-Item -Path $VMPath -ItemType Directory -Force | Out-Null
            Write-Host "Created folder: $VMPath" -ForegroundColor Green
        } catch {
            Write-Error "Could not create $VMPath : $_"
            exit 1
        }
    }

    # Prompt: virtual switch (pick from numbered list of existing switches)
    $switches = @(Get-VMSwitch)
    if ($switches.Count -eq 0) {
        Write-Error "No Hyper-V virtual switches found. Create one in Hyper-V Manager first."
        exit 1
    }
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

    # Prompt: customize specs (defaults are tuned for Win11 + Autopilot)
    if ($useParentDisk) {
        Write-Host "`nDefault VM specs: Generation 2, 4 GB RAM, 2 vCPU, TPM enabled (OS disk size inherited from parent)" -ForegroundColor Cyan
    } else {
        Write-Host "`nDefault VM specs: Generation 2, 4 GB RAM, 2 vCPU, 64 GB OS disk, TPM enabled" -ForegroundColor Cyan
    }
    $customize = Read-Host "Customize specs? [y/N]"
    if ($customize -match '^[Yy]') {
        $memInput = Read-Host "Memory in GB [4]"
        $cpuInput = Read-Host "vCPU count [2]"
        $memBytes = if ($memInput) { [int64]$memInput * 1GB } else { 4GB }
        $cpuCount = if ($cpuInput) { [int]$cpuInput } else { 2 }
        if (-not $useParentDisk) {
            $diskInput = Read-Host "OS disk size in GB [64]"
            $diskBytes = if ($diskInput) { [int64]$diskInput * 1GB } else { 64GB }
        }
    } else {
        $memBytes = 4GB
        $cpuCount = 2
        if (-not $useParentDisk) { $diskBytes = 64GB }
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
        # --- Inject the collection bat into the child VHDX, then boot to OOBE ---
        # VM will land at the OOBE region screen; user runs the bat via Shift+F10.
        Write-Host "`nInjecting collection script into child VHDX..." -ForegroundColor Cyan

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

        try {
            Mount-VHD -Path $childVhd -ErrorAction Stop
        } catch {
            Write-Error "Failed to mount child VHDX: $_"
            exit 1
        }

        $injectedPaths = @()
        try {
            $vhdFile  = Split-Path $childVhd -Leaf
            $disk     = Get-Disk | Where-Object { $_.Location -like "*$vhdFile*" }
            $partition = $disk | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
            if (-not $partition) { throw "Could not find Windows partition on $childVhd" }

            if (-not $partition.DriveLetter) {
                $usedLetters = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name
                $letter = (67..90 | ForEach-Object { [char]$_ } | Where-Object { $_ -notin $usedLetters }) | Select-Object -First 1
                if (-not $letter) { throw "No available drive letters" }
                Set-Partition -InputObject $partition -NewDriveLetter $letter
                Start-Sleep -Seconds 2
                $driveLetter = $letter
            } else {
                $driveLetter = $partition.DriveLetter
            }

            foreach ($src in $FilesToCopy) {
                $leaf = Split-Path $src -Leaf
                $dst  = Join-Path "${driveLetter}:\" $leaf
                Copy-Item -Path $src -Destination $dst -Force
                $injectedPaths += "C:\$leaf"
                Write-Host "✓ Injected: C:\$leaf" -ForegroundColor Green
            }

            # Also drop the first bat as %WINDIR%\Setup\Scripts\SetupComplete.cmd.
            # Windows auto-runs SetupComplete.cmd from this exact path after specialize,
            # before OOBE shows — no unattend.xml dance required.
            $setupScriptsDir = "${driveLetter}:\Windows\Setup\Scripts"
            if (-not (Test-Path $setupScriptsDir)) {
                New-Item -Path $setupScriptsDir -ItemType Directory -Force | Out-Null
            }
            $setupCompletePath = Join-Path $setupScriptsDir "SetupComplete.cmd"
            Copy-Item -Path $FilesToCopy[0] -Destination $setupCompletePath -Force
            Write-Host "✓ Injected: $setupCompletePath (auto-runs at first boot)" -ForegroundColor Green
        } finally {
            Dismount-VHD -Path $childVhd -ErrorAction SilentlyContinue
        }

        # Phase 1 (Copy-VMFile) is unnecessary now — the bat is already on the disk.
        $SkipPhase1 = $true

        # Boot the VM (will run collection via specialize, then shut itself down)
        Write-Host "`nStarting VM..." -ForegroundColor Cyan
        Start-VM -Name $newVMName -ErrorAction Stop
        Write-Host "✓ VM started — Windows will auto-collect HWID, then shut down." -ForegroundColor Green

        # Auto-launch vmconnect so the user can watch progress
        try {
            Start-Process vmconnect.exe -ArgumentList 'localhost', $newVMName -ErrorAction Stop
            Write-Host "✓ vmconnect launched for '$newVMName' (watch progress)" -ForegroundColor Green
        } catch {
            Write-Warning "Could not auto-launch vmconnect: $_"
        }

        # Poll for VM to shut itself down after RunSynchronousCommand completes
        Write-Host "`nWaiting for VM to complete collection and shut down..." -ForegroundColor Yellow
        $maxWait = 900  # 15 minutes
        $elapsed = 0
        $shutdown = $false
        while ($elapsed -lt $maxWait) {
            $state = (Get-VM -Name $newVMName -ErrorAction SilentlyContinue).State
            if ($state -eq 'Off') { $shutdown = $true; break }
            Start-Sleep -Seconds 5
            $elapsed += 5
            if ($elapsed % 30 -eq 0) {
                Write-Host "  ...waiting (${elapsed}s elapsed, state=$state)" -ForegroundColor Gray
            }
        }
        if (-not $shutdown) {
            Write-Warning "VM did not shut down within $maxWait seconds. Forcing shutdown to continue extraction."
            Stop-VM -Name $newVMName -TurnOff -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "✓ VM has shut down — proceeding to file extraction" -ForegroundColor Green
        }
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
if (-not (Get-Variable -Name SkipPhase1 -Scope Script -ErrorAction SilentlyContinue) -and
    -not (Get-Variable -Name SkipPhase1 -Scope Local -ErrorAction SilentlyContinue)) {
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

Write-Host "`n$separator" -ForegroundColor Cyan
Write-Host "  PHASE 3: Collect Files FROM VM" -ForegroundColor Cyan
Write-Host "$separator" -ForegroundColor Cyan

# Get VHD path
Write-Host "`nGetting VHD path..." -ForegroundColor Cyan
$vm = Get-VM -Name $VMName
$vhdPath = ($vm | Select-Object -ExpandProperty HardDrives).Path
if (-not $vhdPath) {
    Write-Error "Could not determine VHD path"
    exit 1
}
Write-Host "VHD Path: $vhdPath" -ForegroundColor Yellow

# Stop VM if running
if ($vm.State -eq "Running") {
    Write-Host "`nStopping VM..." -ForegroundColor Yellow
    Stop-VM -Name $VMName -Force
    
    # Wait for VM to fully stop with progress indicator
    $timeout = 60
    $elapsed = 0
    Write-Host "Waiting for VM to shut down" -NoNewline
    while ((Get-VM -Name $VMName).State -ne "Off" -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 1
        Write-Host "." -NoNewline
        $elapsed++
    }
    Write-Host ""
    
    if ((Get-VM -Name $VMName).State -ne "Off") {
        Write-Error "VM did not stop within timeout period"
        exit 1
    }
    
    # Additional delay to ensure VM resources are fully released
    Write-Host "VM stopped, waiting for resources to release..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    Write-Host "✓ VM stopped and ready" -ForegroundColor Green
}

# Mount VHD
Write-Host "`nMounting VHD (read-only)..." -ForegroundColor Cyan
$mountRetries = 3
$mountSuccess = $false

for ($i = 1; $i -le $mountRetries; $i++) {
    try {
        Mount-VHD -Path $vhdPath -ReadOnly -ErrorAction Stop
        Write-Host "✓ VHD mounted" -ForegroundColor Green
        $mountSuccess = $true
        break
    } catch {
        if ($i -lt $mountRetries) {
            Write-Host "Mount attempt $i failed, retrying in 2 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        } else {
            Write-Error "Failed to mount VHD after $mountRetries attempts: $_"
            exit 1
        }
    }
}

if (-not $mountSuccess) {
    Write-Error "Could not mount VHD"
    exit 1
}

# Assign drive letter
Write-Host "`nAssigning drive letter..." -ForegroundColor Cyan
$driveLetter = $null
try {
    $vhdFileName = Split-Path $vhdPath -Leaf
    $disk = Get-Disk | Where-Object {$_.Location -like "*$vhdFileName*"}
    $partition = $disk | Get-Partition | Where-Object {$_.Size -gt 50GB} | Select-Object -First 1
    
    if ($partition) {
        # Find available drive letter
        $usedLetters = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name
        $availableLetter = (67..90 | ForEach-Object {[char]$_} | Where-Object {$_ -notin $usedLetters}) | Select-Object -First 1
        
        if ($availableLetter) {
            Set-Partition -InputObject $partition -NewDriveLetter $availableLetter
            $driveLetter = $availableLetter
            Write-Host "Drive letter assigned: ${driveLetter}:" -ForegroundColor Yellow
            
            # Wait for drive to be accessible
            Write-Host "Waiting for drive to be ready" -NoNewline
            $driveReady = $false
            $maxWait = 15
            for ($w = 0; $w -lt $maxWait; $w++) {
                Start-Sleep -Seconds 1
                Write-Host "." -NoNewline
                try {
                    $testPath = "${driveLetter}:\"
                    $null = Get-Item $testPath -ErrorAction Stop
                    $driveReady = $true
                    break
                } catch {
                    # Drive not ready yet
                }
            }
            Write-Host ""
            
            if (-not $driveReady) {
                throw "Drive ${driveLetter}: assigned but not accessible after $maxWait seconds"
            }
            
            Write-Host "✓ Drive ${driveLetter}:\ is ready" -ForegroundColor Green
        } else {
            throw "No available drive letters"
        }
    } else {
        throw "Could not find suitable partition"
    }
} catch {
    Write-Error "Failed to assign drive letter: $_"
    Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
    exit 1
}

# Search for files
Write-Host "`nSearching for files..." -ForegroundColor Cyan
$sourcePath = "${driveLetter}:\"
if ($SourceFolder) {
    $searchPath = Join-Path $sourcePath $SourceFolder
    if (Test-Path $searchPath) {
        $sourcePath = $searchPath
    }
}

$files = Get-ChildItem -Path $sourcePath -Filter $SearchPattern -Recurse -File -ErrorAction SilentlyContinue | 
    Sort-Object LastWriteTime -Descending

if ($files.Count -eq 0) {
    Write-Warning "No files matching `"$SearchPattern`" found in $sourcePath"
    Write-Host "`nListing root directory contents:" -ForegroundColor Yellow
    Get-ChildItem "${driveLetter}:\" | Format-Table Name, LastWriteTime, Length
    $collectedCount = 0
} else {
    Write-Host "Found $($files.Count) file(s) (sorted by newest first):" -ForegroundColor Green
    $files | ForEach-Object { 
        Write-Host "  - $($_.Name) (Modified: $($_.LastWriteTime))" -ForegroundColor Yellow 
    }
    
    # Get only the newest file
    $newestFile = $files[0]
    Write-Host "`nNewest file: $($newestFile.Name) - $($newestFile.LastWriteTime)" -ForegroundColor Cyan
    
    # Create destination folder if needed
    if (-not (Test-Path $DestinationPath)) {
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
        Write-Host "Created destination folder: $DestinationPath" -ForegroundColor Green
    }
    
    # Copy only the newest file
    Write-Host "`nCopying newest file..." -ForegroundColor Cyan
    $collectedCount = 0
    try {
        $destFile = Join-Path $DestinationPath $newestFile.Name
        Copy-Item -Path $newestFile.FullName -Destination $destFile -Force
        Write-Host "  ✓ Copied: $($newestFile.Name)" -ForegroundColor Green
        $collectedCount = 1
    } catch {
        Write-Host "  ✗ Failed: $($newestFile.Name) - $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Dismount VHD
Write-Host "`nDismounting VHD..." -ForegroundColor Cyan
try {
    Dismount-VHD -Path $vhdPath -ErrorAction Stop
    Write-Host "✓ VHD dismounted" -ForegroundColor Green
} catch {
    Write-Warning "Failed to dismount VHD: $_"
    Write-Warning "You may need to manually dismount: Dismount-VHD -Path `"$vhdPath`""
}

# Restart VM
Write-Host "`nRestarting VM..." -ForegroundColor Cyan
Start-VM -Name $VMName

# Wait for VM to be fully running
Write-Host "Waiting for VM to start" -NoNewline
$startTimeout = 60
$startElapsed = 0
while ((Get-VM -Name $VMName).State -ne "Running" -and $startElapsed -lt $startTimeout) {
    Start-Sleep -Seconds 1
    Write-Host "." -NoNewline
    $startElapsed++
}
Write-Host ""

if ((Get-VM -Name $VMName).State -eq "Running") {
    Write-Host "✓ VM is running" -ForegroundColor Green
    # Additional delay for VM to fully initialize
    Write-Host "Waiting for VM to fully initialize (30 seconds)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
    Write-Host "✓ VM initialization complete" -ForegroundColor Green
} else {
    Write-Warning "VM did not start within timeout period"
}

# ============================================================================
# FINAL SUMMARY
# ============================================================================

Write-Host "`n$separator" -ForegroundColor Cyan
Write-Host "  WORKFLOW COMPLETE" -ForegroundColor Cyan
Write-Host "$separator" -ForegroundColor Cyan
Write-Host "VM Name:              $VMName"
Write-Host "Files Copied TO VM:   $successCount" -ForegroundColor Green
Write-Host "Files Collected:      $collectedCount" -ForegroundColor Green
if ($collectedCount -gt 0) {
    Write-Host "Collection Location:  $DestinationPath" -ForegroundColor Green
}
Write-Host "VM Status:            Running" -ForegroundColor Green
Write-Host "$separator" -ForegroundColor Cyan

if ($collectedCount -gt 0) {
    Write-Host "`n✓ SUCCESS: Workflow completed successfully!" -ForegroundColor Green
    Write-Host "Your HWID files are ready at: $DestinationPath" -ForegroundColor White
} else {
    Write-Host "`n⚠ WARNING: No files were collected from the VM" -ForegroundColor Yellow
    Write-Host "Please verify the scripts ran successfully on the VM" -ForegroundColor White
}

Read-Host "`nPress Enter to exit"
[Environment]::Exit(0)
