# VMPilot - WPF GUI (dark, minimal)
# Spins up a fresh Hyper-V VM from a cached parent VHDX, collects the AutoPilot
# hardware hash, and optionally imports it to Intune via Microsoft Graph.
# Auto-elevates; hides host console; runs the workflow in a background runspace.

# --- Auto-elevate ---------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    Start-Process $psExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$PSCommandPath`"") -Verb RunAs
    [Environment]::Exit(0)
}

# --- Hide host console + DWM dark title bar -------------------------------
$nativeTypes = @'
using System;
using System.Runtime.InteropServices;
public static class NativeUtil {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("dwmapi.dll")]   public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
'@
try {
    Add-Type -TypeDefinition $nativeTypes -ErrorAction Stop
    $h = [NativeUtil]::GetConsoleWindow()
    if ($h -ne [IntPtr]::Zero) { [NativeUtil]::ShowWindow($h, 0) | Out-Null }
} catch { }

# --- WPF assemblies -------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# --- Hyper-V startup check ------------------------------------------------
# Module ships via PSGallery; on a fresh install we can't assume Hyper-V is
# present. Detect early and offer to enable + reboot before any code path
# tries to call Get-VM.

function Show-VMPilotDialog {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Message,
        [string]$PrimaryText   = 'OK',
        [string]$SecondaryText,
        [string]$PrimaryColor  = '#0078D4'
    )
    $hasSecondary = -not [string]::IsNullOrWhiteSpace($SecondaryText)
    $secondaryXaml = if ($hasSecondary) {
@"
      <Button Grid.Column="0" x:Name="BtnSecondary" Content="$SecondaryText"
              Width="140" Height="36" Margin="0,0,8,0"
              Background="#2A2A2A" Foreground="#FFFFFF" BorderThickness="0"
              FontWeight="SemiBold" Cursor="Hand"/>
"@
    } else { '' }

    [xml]$x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="480" SizeToContent="Height"
        WindowStartupLocation="CenterScreen"
        Background="#161616" Foreground="#FFFFFF"
        FontFamily="Segoe UI Variable, Segoe UI" ResizeMode="NoResize">
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="$Title" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,12"/>
    <TextBlock Grid.Row="1" x:Name="Body" Foreground="#C0C0C0" FontSize="13"
               TextWrapping="Wrap" Margin="0,0,0,24"/>
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
$secondaryXaml
      <Button Grid.Column="2" x:Name="BtnPrimary" Content="$PrimaryText"
              Width="160" Height="36"
              Background="$PrimaryColor" Foreground="#FFFFFF" BorderThickness="0"
              FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </Grid>
</Window>
"@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $dlg.FindName('Body').Text = $Message
    $script:__vmpDlgChoice = 'Closed'
    $dlg.FindName('BtnPrimary').Add_Click({ $script:__vmpDlgChoice = 'Primary';   $dlg.Close() })
    if ($hasSecondary) {
        $dlg.FindName('BtnSecondary').Add_Click({ $script:__vmpDlgChoice = 'Secondary'; $dlg.Close() })
    }
    [void]$dlg.ShowDialog()
    return $script:__vmpDlgChoice
}

function Test-HyperVState {
    # Fast path: cmdlet present → feature is live
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) { return 'Ready' }
    # Slow path: DISM query (a few seconds)
    try {
        foreach ($name in @('Microsoft-Hyper-V-All','Microsoft-Hyper-V')) {
            $f = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction SilentlyContinue
            if ($f) {
                switch ($f.State) {
                    'EnablePending' { return 'EnablePending' }
                    'Enabled'       { return 'Ready' }
                    default         { return 'Disabled' }
                }
            }
        }
        return 'NotAvailable'
    } catch { return 'NotAvailable' }
}

function Invoke-EnableHyperVWithProgress {
    # Shows a progress dialog while Enable-WindowsOptionalFeature runs on a
    # background runspace, so the UI stays responsive (the indeterminate
    # progress bar keeps animating). Returns @{ Success = bool; Error = string }.
    [xml]$x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Enabling Hyper-V" Width="440" SizeToContent="Height"
        WindowStartupLocation="CenterScreen"
        Background="#161616" Foreground="#FFFFFF"
        FontFamily="Segoe UI Variable, Segoe UI" ResizeMode="NoResize">
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Enabling Hyper-V" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,12"/>
    <TextBlock Grid.Row="1" Foreground="#C0C0C0" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,16"
               Text="This takes about a minute. Please don't close this window."/>
    <ProgressBar Grid.Row="2" IsIndeterminate="True" Height="6" Background="#1F1F1F" Foreground="#0078D4" BorderThickness="0"/>
  </Grid>
</Window>
"@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))

    # Spawn a child powershell.exe to run the enable. Doing this in a runspace
    # fails with "Class not registered" (HRESULT 0x80040154) because the DISM
    # COM components don't initialize cleanly under a child runspace's
    # apartment state. A separate process gets its own COM init and works.
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $childCmd = "try { Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart -ErrorAction Stop | Out-Null; exit 0 } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $psExe
    $psi.Arguments              = "-NoProfile -ExecutionPolicy Bypass -Command `"& { $childCmd }`""
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $proc = [System.Diagnostics.Process]::Start($psi)

    $script:__enableResult = $null
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({
        if ($proc.HasExited) {
            $timer.Stop()
            $stderrText = $proc.StandardError.ReadToEnd().Trim()
            if ($proc.ExitCode -eq 0) {
                $script:__enableResult = @{ Success = $true; Error = $null }
            } else {
                $errMsg = if ($stderrText) { $stderrText } else { "Enable failed (exit code $($proc.ExitCode))" }
                $script:__enableResult = @{ Success = $false; Error = $errMsg }
            }
            $dlg.Close()
        }
    })
    $timer.Start()

    [void]$dlg.ShowDialog()
    return $script:__enableResult
}

switch (Test-HyperVState) {
    'Ready' { } # continue to main GUI
    'NotAvailable' {
        [void](Show-VMPilotDialog -Title 'Hyper-V Not Available' `
            -Message ("Hyper-V isn't available on this edition of Windows. " +
                      "VM-Pilot requires Windows 10/11 Pro, Enterprise, or Education.`r`n`r`n" +
                      "Windows Home does not include Hyper-V.") `
            -PrimaryText 'OK')
        [Environment]::Exit(1)
    }
    'EnablePending' {
        $r = Show-VMPilotDialog -Title 'Reboot Required' `
            -Message "Hyper-V is enabled but a reboot is required before VM-Pilot can use it. Reboot now?" `
            -PrimaryText 'REBOOT NOW' -SecondaryText 'REBOOT LATER'
        if ($r -eq 'Primary') { Restart-Computer -Force }
        [Environment]::Exit(0)
    }
    'Disabled' {
        $r = Show-VMPilotDialog -Title 'Hyper-V Required' `
            -Message ("VM-Pilot needs Hyper-V to create virtual machines, but it's not enabled on this machine.`r`n`r`n" +
                      "Enable it now? A reboot is required after enable.") `
            -PrimaryText 'ENABLE HYPER-V' -SecondaryText 'CANCEL'
        if ($r -ne 'Primary') { [Environment]::Exit(0) }

        $result = Invoke-EnableHyperVWithProgress
        if (-not $result -or -not $result.Success) {
            $msg = if ($result) { $result.Error } else { 'Unknown error.' }
            [void](Show-VMPilotDialog -Title 'Enable Failed' `
                -Message "Failed to enable Hyper-V:`r`n`r`n$msg" -PrimaryText 'OK')
            [Environment]::Exit(1)
        }

        $r = Show-VMPilotDialog -Title 'Hyper-V Enabled' `
            -Message ("Hyper-V has been enabled successfully. A reboot is required to complete the installation.`r`n`r`n" +
                      "After reboot, run Start-VMPilot again to launch the GUI.`r`n`r`nReboot now?") `
            -PrimaryText 'REBOOT NOW' -SecondaryText 'REBOOT LATER'
        if ($r -eq 'Primary') { Restart-Computer -Force }
        [Environment]::Exit(0)
    }
}

# --- Constants ------------------------------------------------------------
$script:BootSource         = 'C:\VMs\Win11-24H2.vhdx'
# Prefer the builder vendored in the module folder; fall back to the legacy
# C:\Tools\WinVHDX\ location for users who installed the script there before
# the module wrapper existed.
$script:BuilderScript      = $(
    $localBuilder  = Join-Path $PSScriptRoot 'Get-Win11VHDX.ps1'
    $legacyBuilder = 'C:\Tools\WinVHDX\Get-Win11VHDX.ps1'
    if     (Test-Path $localBuilder)  { $localBuilder }
    elseif (Test-Path $legacyBuilder) { $legacyBuilder }
    else                              { $localBuilder }
)
$script:VMPath             = 'C:\VMs'
$script:FilesToCopy        = @('C:\Autopilot HWID Collection\AutoPilotHWID-Collection.bat')
$script:SearchPattern      = 'AutoPilotHWID*'
$script:SourceFolder       = 'HWID'
$script:DestinationPath    = 'C:\Autopilot HWID Collection'
# Community AutoPilot script — pre-cached on the host, injected onto each VM's VHDX
# at C:\ so the user can run it from OOBE Shift+F10 with a single short command.
$script:CommunityScriptUrl   = 'https://raw.githubusercontent.com/andrew-s-taylor/WindowsAutopilotInfo/main/Community%20Version/get-windowsautopilotinfocommunity.ps1'
$script:CommunityScriptCache = 'C:\Tools\VMPilot\Get-WindowsAutopilotInfoCommunity.ps1'
$script:CommunityScriptInVM  = 'Get-WindowsAutopilotInfoCommunity.ps1'   # lands at C:\<this>
$script:EnrollGuiInVM        = 'AutopilotEnroll.GUI.ps1'                 # lands at C:\<this>
$script:EnrollBatInVM        = 'import.bat'                              # lands at C:\import.bat — what the user runs at Shift+F10
$script:CollectScriptInVM    = 'VMPilotCollect.ps1'                      # Offline: lands at C:\<this>, called by SetupComplete.cmd
$script:IntuneAutopilotUrl   = 'https://intune.microsoft.com/#view/Microsoft_Intune_Enrollment/AutopilotDevices.ReactView/filterOnManualRemediationRequired~/false'

# --- XAML -----------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VM-Pilot"
        Width="600" Height="900"
        WindowStartupLocation="CenterScreen"
        Background="#161616"
        Foreground="#FFFFFF"
        FontFamily="Segoe UI Variable, Segoe UI"
        ResizeMode="CanMinimize"
        UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">

  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#1F1F1F"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#3A3A3A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,11"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="CaretBrush" Value="#FFFFFF"/>
      <Setter Property="SelectionBrush" Value="#0078D4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#5A5A5A"/>
              </Trigger>
              <Trigger Property="IsFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#0078D4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Segment" TargetType="RadioButton">
      <Setter Property="Background" Value="#1F1F1F"/>
      <Setter Property="Foreground" Value="#A8A8A8"/>
      <Setter Property="BorderBrush" Value="#3A3A3A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2A2A2A"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#4A4A4A"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#0078D4"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#0078D4"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="#0078D4"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="52"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1F8AE0"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#0061B0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#2A2A2A"/>
                <Setter Property="Foreground" Value="#707070"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#909090"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="2,0,0,8"/>
    </Style>
  </Window.Resources>

  <Grid Margin="32,28,32,28">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/> <!-- Title -->
      <RowDefinition Height="Auto"/> <!-- Mode -->
      <RowDefinition Height="Auto"/> <!-- VM name -->
      <RowDefinition Height="Auto"/> <!-- CPU/RAM -->
      <RowDefinition Height="Auto"/> <!-- Online-only fields -->
      <RowDefinition Height="Auto"/> <!-- Button -->
      <RowDefinition Height="Auto"/> <!-- Divider -->
      <RowDefinition Height="*"/>    <!-- Status + result -->
    </Grid.RowDefinitions>

    <!-- Title -->
    <StackPanel Grid.Row="0" Margin="0,0,0,22">
      <TextBlock Text="VM-Pilot" FontSize="26" FontWeight="SemiBold"/>
      <TextBlock Text="Spin up a fresh Hyper-V VM and collect the AutoPilot hardware hash." Foreground="#909090" FontSize="13" Margin="0,6,0,0"/>
    </StackPanel>

    <!-- Mode (left) + Win Release (right) -->
    <Grid Grid.Row="1" Margin="0,0,0,18">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="20"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <StackPanel Grid.Column="0">
        <TextBlock Text="MODE" Style="{StaticResource FieldLabel}"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="6"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <RadioButton Grid.Column="0" x:Name="ModeOffline" GroupName="Mode" Content="Offline" IsChecked="True" Style="{StaticResource Segment}"/>
          <RadioButton Grid.Column="2" x:Name="ModeOnline"  GroupName="Mode" Content="Online"  Style="{StaticResource Segment}"/>
        </Grid>
      </StackPanel>

      <StackPanel Grid.Column="2">
        <TextBlock Text="WIN RELEASE" Style="{StaticResource FieldLabel}"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="6"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <RadioButton Grid.Column="0" x:Name="Rel24H2" GroupName="Release" Content="24H2" IsChecked="True" Style="{StaticResource Segment}"/>
          <RadioButton Grid.Column="2" x:Name="Rel25H2" GroupName="Release" Content="25H2" Style="{StaticResource Segment}"/>
        </Grid>
      </StackPanel>
    </Grid>

    <!-- VM name -->
    <StackPanel Grid.Row="2" Margin="0,0,0,18">
      <TextBlock Text="VM NAME" Style="{StaticResource FieldLabel}"/>
      <TextBox x:Name="VMNameBox" Text="ME1"/>
    </StackPanel>

    <!-- CPU/RAM -->
    <Grid Grid.Row="3" Margin="0,0,0,18">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="20"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <StackPanel Grid.Column="0">
        <TextBlock Text="CPU CORES" Style="{StaticResource FieldLabel}"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="6"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="6"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <RadioButton Grid.Column="0" x:Name="Cpu1" GroupName="Cpu" Content="1" Style="{StaticResource Segment}"/>
          <RadioButton Grid.Column="2" x:Name="Cpu2" GroupName="Cpu" Content="2" IsChecked="True" Style="{StaticResource Segment}"/>
          <RadioButton Grid.Column="4" x:Name="Cpu4" GroupName="Cpu" Content="4" Style="{StaticResource Segment}"/>
        </Grid>
      </StackPanel>

      <StackPanel Grid.Column="2">
        <TextBlock Text="RAM (GB)" Style="{StaticResource FieldLabel}"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="6"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="6"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <RadioButton Grid.Column="0" x:Name="Ram4"  GroupName="Ram" Content="4"  IsChecked="True" Style="{StaticResource Segment}"/>
          <RadioButton Grid.Column="2" x:Name="Ram8"  GroupName="Ram" Content="8"  Style="{StaticResource Segment}"/>
          <RadioButton Grid.Column="4" x:Name="Ram16" GroupName="Ram" Content="16" Style="{StaticResource Segment}"/>
        </Grid>
      </StackPanel>
    </Grid>

    <!-- Group Tag (Offline only; toggled by Update-ModeUI). Online mode captures its
         own group tag inside the VM via AutopilotEnroll.GUI.ps1. -->
    <StackPanel Grid.Row="4" x:Name="GroupTagPanel" Margin="0,0,0,18">
      <TextBlock Text="GROUP TAG (OPTIONAL)" Style="{StaticResource FieldLabel}"/>
      <TextBox x:Name="GroupTagBox" Text=""/>
    </StackPanel>

    <!-- Primary button -->
    <Button Grid.Row="5" x:Name="RunButton" Content="COLLECT HWID" Style="{StaticResource PrimaryButton}" Margin="0,8,0,22"/>

    <!-- Divider -->
    <Border Grid.Row="6" Height="1" Background="#2A2A2A" Margin="0,0,0,22"/>

    <!-- Status + progress (top) + completion/serial (centered) + Cleanup link (bottom) -->
    <Grid Grid.Row="7">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0">
        <TextBlock x:Name="StatusText"
                   Text=""
                   FontSize="14"
                   Foreground="#FFFFFF"
                   Margin="0,0,0,12"
                   TextWrapping="Wrap"/>
        <ProgressBar x:Name="ActivityBar"
                     Height="4"
                     IsIndeterminate="True"
                     Foreground="#0078D4"
                     Background="#252525"
                     BorderThickness="0"
                     Visibility="Collapsed"/>
      </StackPanel>

      <!-- Center stack: Complete (or red error) + the serial number block -->
      <StackPanel Grid.Row="1" VerticalAlignment="Center" HorizontalAlignment="Center">
        <TextBlock x:Name="CompletedIcon" Text="Complete"
                   FontSize="36" FontWeight="SemiBold" Foreground="#1ACB5F"
                   HorizontalAlignment="Center" TextAlignment="Center"
                   Padding="0,4,0,8"
                   Visibility="Collapsed"/>

        <TextBlock x:Name="ResultText" Text=""
                   FontSize="13" Foreground="#F03A47" TextWrapping="Wrap"
                   HorizontalAlignment="Center" TextAlignment="Center"
                   Visibility="Collapsed"/>

        <!-- DEVICE SERIAL block: shown alongside Complete, auto-copied to clipboard -->
        <StackPanel x:Name="SerialPanel" Visibility="Collapsed" Margin="0,20,0,0">
          <TextBlock Text="DEVICE SERIAL" Style="{StaticResource FieldLabel}" HorizontalAlignment="Center"/>
          <TextBlock x:Name="SerialText" FontSize="14"
                     FontFamily="Cascadia Mono, Consolas, Courier New"
                     Foreground="#FFFFFF" HorizontalAlignment="Center" Margin="0,4,0,0"/>
          <TextBlock Text="copied to clipboard" FontSize="11"
                     Foreground="#707070" HorizontalAlignment="Center"
                     Margin="0,6,0,0" FontStyle="Italic"/>
        </StackPanel>
      </StackPanel>

      <!-- Bottom row: Open AutoPilot (left, blue) | Cleanup VMs (red) + Exit (gray) on right. -->
      <Grid Grid.Row="2" Margin="0,12,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <Button Grid.Column="0" x:Name="IntuneButton" Content="OPEN AUTOPILOT"
                Width="160" Height="36"
                Background="#0078D4" Foreground="#FFFFFF" BorderThickness="0"
                FontSize="12" FontWeight="SemiBold" Cursor="Hand">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="Bd" Property="Background" Value="#1F8AE0"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                  <Setter TargetName="Bd" Property="Background" Value="#0061B0"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>

        <Button Grid.Column="2" x:Name="CleanupButton" Content="CLEANUP VMs"
                Width="140" Height="36"
                Background="#F03A47" Foreground="#FFFFFF" BorderThickness="0"
                FontSize="12" FontWeight="SemiBold" Cursor="Hand">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="Bd" Property="Background" Value="#FF5560"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                  <Setter TargetName="Bd" Property="Background" Value="#C92B37"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>

        <Button Grid.Column="3" x:Name="ExitButton" Content="EXIT"
                Width="90" Height="36" Margin="8,0,0,0"
                Background="#2A2A2A" Foreground="#FFFFFF" BorderThickness="0"
                FontSize="12" FontWeight="SemiBold" Cursor="Hand">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="Bd" Property="Background" Value="#3A3A3A"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                  <Setter TargetName="Bd" Property="Background" Value="#1F1F1F"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>
      </Grid>
    </Grid>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$VMNameBox      = $window.FindName('VMNameBox')
$RunButton      = $window.FindName('RunButton')
$StatusText     = $window.FindName('StatusText')
$ActivityBar    = $window.FindName('ActivityBar')
$ResultText     = $window.FindName('ResultText')
$CompletedIcon  = $window.FindName('CompletedIcon')
$ModeOffline    = $window.FindName('ModeOffline')
$ModeOnline     = $window.FindName('ModeOnline')
$Rel24H2        = $window.FindName('Rel24H2')
$Rel25H2        = $window.FindName('Rel25H2')
$GroupTagBox    = $window.FindName('GroupTagBox')
$GroupTagPanel  = $window.FindName('GroupTagPanel')
$SerialPanel    = $window.FindName('SerialPanel')
$SerialText     = $window.FindName('SerialText')
$CleanupButton    = $window.FindName('CleanupButton')
$IntuneButton     = $window.FindName('IntuneButton')
$ExitButton       = $window.FindName('ExitButton')

# --- Dark title bar (DWM immersive dark mode) -----------------------------
$window.Add_SourceInitialized({
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
        $useDark = 1
        $r = [NativeUtil]::DwmSetWindowAttribute($hwnd, 20, [ref]$useDark, 4)
        if ($r -ne 0) { [NativeUtil]::DwmSetWindowAttribute($hwnd, 19, [ref]$useDark, 4) | Out-Null }
    } catch { }
})

# --- Mode toggle: swap button label + show/hide Group Tag (Offline only) --
function Update-ModeUI {
    if ($ModeOnline.IsChecked) {
        $RunButton.Content       = 'COLLECT & UPLOAD'
        $GroupTagPanel.Visibility = 'Collapsed'
    } else {
        $RunButton.Content       = 'COLLECT HWID'
        $GroupTagPanel.Visibility = 'Visible'
    }
}
$ModeOffline.Add_Checked({ Update-ModeUI })
$ModeOnline.Add_Checked({ Update-ModeUI })
Update-ModeUI   # apply initial state (Offline default → Group Tag visible)

# --- UI helpers -----------------------------------------------------------
function Set-Status {
    param([string]$Text)
    $window.Dispatcher.Invoke([Action]{ $StatusText.Text = $Text })
}
function Set-Result {
    # Error/warning text. Hides the success icon if it was showing.
    param([string]$Text, [string]$Color = '#F03A47')
    $window.Dispatcher.Invoke([Action]{
        $CompletedIcon.Visibility = 'Collapsed'
        $ResultText.Text          = $Text
        $ResultText.Foreground    = $Color
        $ResultText.Visibility    = 'Visible'
    })
}
function Set-Done {
    # Success state: drawn checkmark icon, no verbose text.
    $window.Dispatcher.Invoke([Action]{
        $StatusText.Text          = ''
        $ResultText.Text          = ''
        $ResultText.Visibility    = 'Collapsed'
        $CompletedIcon.Visibility = 'Visible'
    })
}
function Hide-CompletedIcon {
    $window.Dispatcher.Invoke([Action]{
        $CompletedIcon.Visibility = 'Collapsed'
        $SerialPanel.Visibility   = 'Collapsed'
        $SerialText.Text          = ''
    })
}
function Show-Serial {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $window.Dispatcher.Invoke([Action]{
        $SerialText.Text         = $Value
        $SerialPanel.Visibility  = 'Visible'
        try { [System.Windows.Clipboard]::SetText($Value) } catch { }
    })
}

function Get-CheckedRadio {
    param([int[]]$Values, [string]$Prefix, [int]$Default)
    foreach ($v in $Values) {
        $rb = $window.FindName("$Prefix$v")
        if ($rb -and $rb.IsChecked) { return $v }
    }
    return $Default
}

# --- Workflow runspace ----------------------------------------------------
$script:Runspace = $null
$script:PSInst   = $null

function Start-Workflow {
    $vmName   = $VMNameBox.Text.Trim()
    $cpu      = Get-CheckedRadio -Values 1,2,4   -Prefix 'Cpu' -Default 2
    $ramGB    = Get-CheckedRadio -Values 4,8,16  -Prefix 'Ram' -Default 4
    $online   = [bool]$ModeOnline.IsChecked
    $groupTag = $GroupTagBox.Text.Trim()
    $release  = if ($Rel25H2.IsChecked) { '25H2' } else { '24H2' }
    $bootSource    = "C:\VMs\Win11-$release.vhdx"

    if ([string]::IsNullOrWhiteSpace($vmName)) {
        Set-Result -Text 'VM name cannot be empty.' -Color '#F03A47'
        return
    }

    Hide-CompletedIcon
    $window.Dispatcher.Invoke([Action]{ $ResultText.Visibility = 'Collapsed'; $ResultText.Text = '' })
    Set-Status -Text 'Starting…'
    $RunButton.IsEnabled    = $false
    $RunButton.Content      = 'WORKING…'
    $ActivityBar.Visibility = 'Visible'

    # Online mode: VM lands at OOBE region screen (no unattend). We pre-inject
    # the community script to C:\Get-WindowsAutopilotInfoCommunity.ps1 in the VHDX.
    # User does SHIFT+F10 in vmconnect and runs ONE line:
    #   powershell C:\Get-WindowsAutopilotInfoCommunity.ps1 -Online -Reboot [-GroupTag X] [-AssignedUser Y]
    # Community script handles Connect-MgGraph (browser sign-in), upload, assignment
    # poll, and -Reboot which returns the VM to OOBE → AutoPilot self-enrolls.
    # Device never leaves OOBE state.

    $sharedVars = @{
        VMName              = $vmName
        CpuCount            = $cpu
        RamGB               = $ramGB
        Online              = $online
        GroupTag            = $groupTag
        Release             = $release
        ScriptDir           = $PSScriptRoot
        BootSource      = $bootSource            # per-release override
        BuilderScript   = $script:BuilderScript
        VMPath          = $script:VMPath
        FilesToCopy     = $script:FilesToCopy
        SearchPattern   = $script:SearchPattern
        SourceFolder    = $script:SourceFolder
        DestinationPath = $script:DestinationPath
        CommunityScriptUrl   = $script:CommunityScriptUrl
        CommunityScriptCache = $script:CommunityScriptCache
        CommunityScriptInVM  = $script:CommunityScriptInVM
        EnrollGuiInVM        = $script:EnrollGuiInVM
        EnrollBatInVM        = $script:EnrollBatInVM
        CollectScriptInVM    = $script:CollectScriptInVM
        Window          = $window
        StatusText      = $StatusText
        ResultText      = $ResultText
        CompletedIcon   = $CompletedIcon
        SerialPanel     = $SerialPanel
        SerialText      = $SerialText
        RunButton       = $RunButton
        ActivityBar     = $ActivityBar
        ModeOnline      = $ModeOnline
    }

    $script:Runspace = [runspacefactory]::CreateRunspace()
    $script:Runspace.ApartmentState = 'STA'
    $script:Runspace.ThreadOptions  = 'ReuseThread'
    $script:Runspace.Open()
    foreach ($k in $sharedVars.Keys) {
        $script:Runspace.SessionStateProxy.SetVariable($k, $sharedVars[$k])
    }

    $script:PSInst = [powershell]::Create()
    $script:PSInst.Runspace = $script:Runspace

    $workflow = {
        function Set-Status {
            param([string]$Text)
            $Window.Dispatcher.Invoke([Action]{ $StatusText.Text = $Text })
        }
        function Set-Result {
            param([string]$Text, [string]$Color = '#F03A47')
            $Window.Dispatcher.Invoke([Action]{
                $CompletedIcon.Visibility = 'Collapsed'
                $ResultText.Text          = $Text
                $ResultText.Foreground    = $Color
                $ResultText.Visibility    = 'Visible'
            })
        }
        function Set-Done {
            $Window.Dispatcher.Invoke([Action]{
                $StatusText.Text          = ''
                $ResultText.Text          = ''
                $ResultText.Visibility    = 'Collapsed'
                $CompletedIcon.Visibility = 'Visible'
            })
        }
        function Show-Serial {
            param([string]$Value)
            if ([string]::IsNullOrWhiteSpace($Value)) { return }
            $Window.Dispatcher.Invoke([Action]{
                $SerialText.Text         = $Value
                $SerialPanel.Visibility  = 'Visible'
                try { [System.Windows.Clipboard]::SetText($Value) } catch { }
            })
        }
        function Restore-Button {
            $Window.Dispatcher.Invoke([Action]{
                $RunButton.IsEnabled = $true
                if ($ModeOnline.IsChecked) { $RunButton.Content = 'COLLECT & UPLOAD' } else { $RunButton.Content = 'COLLECT HWID' }
                $ActivityBar.Visibility = 'Collapsed'
                $StatusText.Text = ''
            })
        }

        try {
            # ===== VHDX template =====
            if (Test-Path $BootSource -PathType Leaf) {
                Set-Status 'VHDX template ready (cached)'
            } else {
                if (-not (Test-Path $BuilderScript)) {
                    Set-Result -Text "VHDX template missing and Get-Win11VHDX.ps1 not found at $BuilderScript." -Color '#F03A47'
                    Restore-Button
                    return
                }

                # Always pull a fresh Fido before building. Microsoft periodically
                # tweaks their ISO download endpoints which breaks the on-disk Fido;
                # grabbing the latest from upstream means the build works first try
                # without a retry loop. Cache it in a stable location (NOT the
                # module folder — that would pollute the published package on
                # Publish-Module).
                $fidoCacheDir = 'C:\Tools\WinVHDX'
                if (-not (Test-Path $fidoCacheDir)) {
                    New-Item -Path $fidoCacheDir -ItemType Directory -Force | Out-Null
                }
                Set-Status 'Refreshing Fido from GitHub…'
                $fidoPath = Join-Path $fidoCacheDir 'Fido.ps1'
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1' `
                                      -OutFile $fidoPath -UseBasicParsing -ErrorAction Stop
                } catch {
                    Set-Result -Text "Failed to refresh Fido from GitHub: $($_.Exception.Message)" -Color '#F03A47'
                    Restore-Button
                    return
                }

                Set-Status 'Building Windows VHDX template (one-time, may take 5–30 min)…'
                try {
                    & $BuilderScript -Release $Release -Edition Pro -OutVhdx $BootSource -WorkDir $fidoCacheDir 2>&1 | ForEach-Object {
                        $line = "$_"
                        if     ($line -match 'Fetching Fido')               { Set-Status 'Fetching Fido…' }
                        elseif ($line -match 'Resolving ISO URL')           { Set-Status 'Resolving Microsoft ISO URL…' }
                        elseif ($line -match 'Downloading ISO')             { Set-Status 'Downloading Windows ISO (~5 GB, slow)…' }
                        elseif ($line -match 'Reusing existing ISO')        { Set-Status 'ISO cached — preparing…' }
                        elseif ($line -match 'Mounting ISO')                { Set-Status 'Mounting ISO…' }
                        elseif ($line -match 'Using image index')           { Set-Status 'Reading install image…' }
                        elseif ($line -match 'Creating .*GB, dynamic')      { Set-Status 'Creating empty VHDX…' }
                        elseif ($line -match 'Applying image')              { Set-Status 'Applying Windows image (slow)…' }
                        elseif ($line -match 'Writing UEFI')                { Set-Status 'Writing UEFI boot files…' }
                        elseif ($line -match 'Dismounting')                 { Set-Status 'Finalizing VHDX…' }
                    }
                } catch {
                    Set-Result -Text "VHDX build failed: $($_.Exception.Message)" -Color '#F03A47'
                    Restore-Button
                    return
                }
                if (-not (Test-Path $BootSource -PathType Leaf)) {
                    Set-Result -Text "Builder finished but no VHDX appeared at $BootSource." -Color '#F03A47'
                    Restore-Button
                    return
                }
            }

            # ===== Create VM =====
            Set-Status 'Creating virtual machine…'
            if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
                Set-Result -Text "A VM named '$VMName' already exists. Pick a different name." -Color '#F03A47'
                Restore-Button
                return
            }
            if (-not (Test-Path $VMPath)) { New-Item -Path $VMPath -ItemType Directory -Force | Out-Null }

            $sw = Get-VMSwitch | Where-Object Name -eq 'Default Switch' | Select-Object -First 1
            if (-not $sw) { $sw = Get-VMSwitch | Select-Object -First 1 }
            if (-not $sw) {
                Set-Result -Text 'No Hyper-V virtual switch found. Create one in Hyper-V Manager first.' -Color '#F03A47'
                Restore-Button
                return
            }

            if (-not (Get-Module -ListAvailable -Name HyperV.VMFactory)) {
                Set-Status 'Installing HyperV.VMFactory module…'
                if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
                }
                Install-Module -Name HyperV.VMFactory -Scope CurrentUser -Force -ErrorAction Stop
            }
            Import-Module HyperV.VMFactory -ErrorAction Stop

            New-HyperVVM -VMName $VMName `
                         -Path $VMPath `
                         -VMSwitch $sw.Name `
                         -VMGeneration 2 `
                         -VMProcessorCount $CpuCount `
                         -VMMemoryStartupBytes ([int64]$RamGB * 1GB) `
                         -ParentDisk $BootSource `
                         -ErrorAction Stop | Out-Null

            # ===== Inject mode-specific payload into the child VHDX =====
            # Online: pre-injected community AutoPilot script (VM stays at OOBE; user runs via Shift+F10)
            # Offline: collection bat + SetupComplete.cmd (VM auto-collects and shuts down)
            $childVhd = (Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1).Path

            if ($Online) {
                Set-Status 'Caching community AutoPilot script…'
                $cacheDir = Split-Path $CommunityScriptCache -Parent
                if (-not (Test-Path $cacheDir)) { New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null }
                if (-not (Test-Path $CommunityScriptCache -PathType Leaf)) {
                    try {
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                        Invoke-WebRequest -Uri $CommunityScriptUrl -OutFile $CommunityScriptCache -UseBasicParsing -ErrorAction Stop
                    } catch {
                        Set-Result -Text "Failed to download community script from GitHub: $($_.Exception.Message)"
                        Restore-Button
                        return
                    }
                }
                Set-Status 'Injecting community script into VM…'
            } else {
                Set-Status 'Injecting offline collection script into VM…'
                $collectSrc = Join-Path $ScriptDir $CollectScriptInVM
                if (-not (Test-Path $collectSrc -PathType Leaf)) {
                    Set-Result -Text "Collection script not found in repo at $collectSrc"
                    Restore-Button
                    return
                }
            }

            $mountFolder = Join-Path $env:TEMP "VMPilot-Inject-$(Get-Random)"
            New-Item -Path $mountFolder -ItemType Directory -Force | Out-Null
            Mount-VHD -Path $childVhd -NoDriveLetter -ErrorAction Stop
            $partition = $null
            try {
                $vhdFile = Split-Path $childVhd -Leaf
                $disk = Get-Disk | Where-Object { $_.Location -like "*$vhdFile*" }
                $partition = $disk | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
                Add-PartitionAccessPath -InputObject $partition -AccessPath $mountFolder -ErrorAction Stop
                Start-Sleep -Seconds 1

                if ($Online) {
                    # Drop the community AutoPilot script + the in-VM enrollment GUI + a one-line .bat
                    # at C:\ on the VHDX. User runs `C:\Enroll.bat` from OOBE Shift+F10 → opens the
                    # in-VM GUI → user clicks Enroll → community script handles sign-in + upload +
                    # assignment + -Reboot which returns VM to OOBE → AutoPilot self-enrolls.
                    Copy-Item -Path $CommunityScriptCache -Destination (Join-Path $mountFolder $CommunityScriptInVM) -Force

                    $enrollGuiSrc = Join-Path $ScriptDir $EnrollGuiInVM
                    if (-not (Test-Path $enrollGuiSrc -PathType Leaf)) {
                        throw "In-VM enrollment GUI not found in repo at $enrollGuiSrc"
                    }
                    Copy-Item -Path $enrollGuiSrc -Destination (Join-Path $mountFolder $EnrollGuiInVM) -Force

                    # Pre-install NuGet + trust PSGallery so the community script's
                    # Install-Script call doesn't prompt the user. Then launch the GUI.
                    # NOTE: `|` is literal inside cmd "..." — do NOT escape with ^|, that
                    # gets passed to PowerShell verbatim and fails to parse.
                    $batContent = @"
@echo off
title VM-Pilot AutoPilot Import
echo Priming PowerShell package management (no interaction needed)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:`$false | Out-Null; Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue"
echo Launching AutoPilot Enrollment GUI...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\$EnrollGuiInVM
"@
                    [IO.File]::WriteAllText((Join-Path $mountFolder $EnrollBatInVM), $batContent, [Text.UTF8Encoding]::new($false))
                } else {
                    # Offline: copy the collection script + generate SetupComplete.cmd that
                    # invokes it with -GroupTag (omitted if blank). Collection script writes
                    # the CSV with a 'Group Tag' column only when the value is non-empty.
                    $collectSrc = Join-Path $ScriptDir $CollectScriptInVM
                    Copy-Item -Path $collectSrc -Destination (Join-Path $mountFolder $CollectScriptInVM) -Force

                    $tagArg = if (-not [string]::IsNullOrWhiteSpace($GroupTag)) { " -GroupTag `"$GroupTag`"" } else { '' }
                    $setupContent = @"
@echo off
if not exist "C:\HWID" mkdir "C:\HWID"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\$CollectScriptInVM$tagArg > C:\HWID\collection.log 2>&1
shutdown /s /f /t 5
"@
                    $setupDir = Join-Path $mountFolder 'Windows\Setup\Scripts'
                    if (-not (Test-Path $setupDir)) { New-Item -Path $setupDir -ItemType Directory -Force | Out-Null }
                    [IO.File]::WriteAllText((Join-Path $setupDir 'SetupComplete.cmd'), $setupContent, [Text.UTF8Encoding]::new($false))
                }
            } finally {
                if ($partition) { Remove-PartitionAccessPath -InputObject $partition -AccessPath $mountFolder -ErrorAction SilentlyContinue }
                Dismount-VHD -Path $childVhd -ErrorAction SilentlyContinue
                Remove-Item $mountFolder -Force -Recurse -ErrorAction SilentlyContinue
            }

            # ===== Boot the VM and open vmconnect =====
            Set-Status 'Booting VM…'
            Start-VM -Name $VMName -ErrorAction Stop
            try { Start-Process vmconnect.exe -ArgumentList 'localhost', $VMName -ErrorAction Stop } catch { }

            # ===== Online mode: VM is at OOBE — user runs the community script via Shift+F10 =====
            # Community script handles upload + assignment + reboot-from-OOBE → AutoPilot enrolls.
            if ($Online) {
                # Query the VM's BIOS serial from Hyper-V settings so we can show it
                # in the GUI + clipboard (matches what Win32_BIOS will return inside the VM)
                try {
                    $ms = Get-CimInstance -Namespace 'root\virtualization\v2' `
                                          -ClassName 'Msvm_VirtualSystemSettingData' `
                                          -Filter "ElementName='$VMName' AND VirtualSystemType='Microsoft:Hyper-V:System:Realized'" `
                                          -ErrorAction SilentlyContinue
                    $bios = "$($ms.BIOSSerialNumber)"
                    if ($bios) { Show-Serial -Value $bios }
                } catch { }
                Set-Done
                Restore-Button
                return
            }

            Set-Status 'Collecting hardware hash inside VM…'
            $maxWait = 900; $elapsed = 0; $shutdown = $false
            while ($elapsed -lt $maxWait) {
                $state = (Get-VM -Name $VMName -ErrorAction SilentlyContinue).State
                if ($state -eq 'Off') { $shutdown = $true; break }
                Start-Sleep -Seconds 5
                $elapsed += 5
                if ($elapsed % 30 -eq 0) {
                    Set-Status "Collecting hardware hash inside VM… (${elapsed}s)"
                }
            }
            if (-not $shutdown) {
                Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
            }

            # ===== Offline-only: wait for VM to self-shutdown, extract CSV, restart =====
            Set-Status 'Extracting CSV from VM…'
            $vhdPath = (Get-VM -Name $VMName).HardDrives | Select-Object -First 1 -ExpandProperty Path
            if ((Get-VM -Name $VMName).State -eq 'Running') {
                Stop-VM -Name $VMName -Force
                $t = 0; while ((Get-VM -Name $VMName).State -ne 'Off' -and $t -lt 60) { Start-Sleep -Seconds 1; $t++ }
                Start-Sleep -Seconds 3
            }

            $mountFolder = Join-Path $env:TEMP "VMPilot-Extract-$(Get-Random)"
            New-Item -Path $mountFolder -ItemType Directory -Force | Out-Null
            Mount-VHD -Path $vhdPath -ReadOnly -NoDriveLetter -ErrorAction Stop
            $partition = $null
            $collected = $false
            try {
                $vhdFile = Split-Path $vhdPath -Leaf
                $disk = Get-Disk | Where-Object { $_.Location -like "*$vhdFile*" }
                $partition = $disk | Get-Partition | Where-Object { $_.Size -gt 50GB } | Select-Object -First 1
                Add-PartitionAccessPath -InputObject $partition -AccessPath $mountFolder -ErrorAction Stop
                Start-Sleep -Seconds 1

                $sourcePath = $mountFolder
                $searchPath = Join-Path $sourcePath $SourceFolder
                if (Test-Path $searchPath) { $sourcePath = $searchPath }
                $files = Get-ChildItem -Path $sourcePath -Filter $SearchPattern -Recurse -File -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending

                if ($files.Count -gt 0) {
                    if (-not (Test-Path $DestinationPath)) { New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null }
                    $destCsv = Join-Path $DestinationPath $files[0].Name
                    Copy-Item -Path $files[0].FullName -Destination $destCsv -Force
                    $collected = $true
                    # Read serial from the CSV so we can surface it in the GUI + clipboard
                    try {
                        $row = Import-Csv -Path $destCsv | Select-Object -First 1
                        if ($row) { $script:CollectedSerial = "$($row.'Device Serial Number')" }
                    } catch { }
                }
            } finally {
                if ($partition) { Remove-PartitionAccessPath -InputObject $partition -AccessPath $mountFolder -ErrorAction SilentlyContinue }
                Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
                Remove-Item $mountFolder -Force -Recurse -ErrorAction SilentlyContinue
            }

            Start-VM -Name $VMName -ErrorAction SilentlyContinue

            if ($collected) {
                if ($script:CollectedSerial) { Show-Serial -Value $script:CollectedSerial }
                Set-Done
            } else {
                Set-Result -Text 'No hash CSV found on the VM. Mount its VHDX and check C:\HWID\collection.log.' -Color '#F03A47'
            }

        } catch {
            Set-Result -Text "Error: $($_.Exception.Message)" -Color '#F03A47'
        } finally {
            Restore-Button
        }
    }

    [void]$script:PSInst.AddScript($workflow)
    [void]$script:PSInst.BeginInvoke()
}

# --- Wire up + cleanup ----------------------------------------------------
$RunButton.Add_Click({ Start-Workflow })

# Cleanup hyperlink: opens a modal dialog with all VMs listed for selective or bulk removal
function Show-CleanupDialog {
    [xml]$dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VM Cleanup"
        Width="520" Height="560"
        WindowStartupLocation="CenterOwner"
        Background="#161616" Foreground="#FFFFFF"
        FontFamily="Segoe UI Variable, Segoe UI"
        ResizeMode="CanResize">
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Text="VM Cleanup" FontSize="22" FontWeight="SemiBold"/>
    <TextBlock Grid.Row="1" Foreground="#909090" FontSize="12" Margin="0,4,0,16" TextWrapping="Wrap"
               Text="Select VMs to remove. Each VM is stopped, deleted from Hyper-V, and its C:\VMs\&lt;name&gt; folder is wiped."/>

    <ListBox Grid.Row="2" x:Name="VmListBox"
             Background="#1F1F1F" Foreground="#FFFFFF" BorderBrush="#3A3A3A" BorderThickness="1"
             SelectionMode="Single"/>

    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="BtnRemoveSelected" Content="REMOVE SELECTED" Width="170" Height="36" Margin="0,0,8,0"
              Background="#0078D4" Foreground="#FFFFFF" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="BtnRemoveAll" Content="REMOVE ALL" Width="120" Height="36" Margin="0,0,8,0"
              Background="#F03A47" Foreground="#FFFFFF" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="BtnClose" Content="CLOSE" Width="100" Height="36"
              Background="#2A2A2A" Foreground="#FFFFFF" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $dlgReader = New-Object System.Xml.XmlNodeReader $dlgXaml
    $dlg = [Windows.Markup.XamlReader]::Load($dlgReader)
    $dlg.Owner = $window

    $VmListBox        = $dlg.FindName('VmListBox')
    $BtnRemoveSel     = $dlg.FindName('BtnRemoveSelected')
    $BtnRemoveAll     = $dlg.FindName('BtnRemoveAll')
    $BtnClose         = $dlg.FindName('BtnClose')

    function Update-VmList {
        $VmListBox.Items.Clear()
        $vms = Get-VM | Sort-Object Name
        if (-not $vms) {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = '(no VMs)'
            $tb.Foreground = '#707070'
            $tb.Padding = '8,12,8,12'
            [void]$VmListBox.Items.Add($tb)
            return
        }
        foreach ($vm in $vms) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content    = ('{0,-30} {1}' -f $vm.Name, $vm.State)
            $cb.Tag        = $vm.Name
            $cb.Foreground = '#FFFFFF'
            $cb.Margin     = '8,6,8,6'
            $cb.FontFamily = 'Cascadia Mono, Consolas, Courier New'
            $cb.FontSize   = 13
            [void]$VmListBox.Items.Add($cb)
        }
    }

    function Get-CheckedNames {
        $names = @()
        foreach ($item in $VmListBox.Items) {
            if ($item -is [System.Windows.Controls.CheckBox] -and $item.IsChecked) { $names += "$($item.Tag)" }
        }
        return ,$names
    }

    function Remove-VMs {
        param([string[]]$Names)
        foreach ($n in $Names) {
            Stop-VM   -Name $n -TurnOff -Force -ErrorAction SilentlyContinue
            Remove-VM -Name $n -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "C:\VMs\$n" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $BtnRemoveSel.Add_Click({
        $names = Get-CheckedNames
        if ($names.Count -eq 0) {
            [void][System.Windows.MessageBox]::Show('No VMs are checked.', 'VM Cleanup',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }
        $msg = "Permanently remove $($names.Count) VM(s)?`r`n`r`n" + ($names -join "`r`n")
        $ans = [System.Windows.MessageBox]::Show($msg, 'Confirm Cleanup',
            [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
        Remove-VMs -Names $names
        Update-VmList
    })

    $BtnRemoveAll.Add_Click({
        $names = @()
        foreach ($item in $VmListBox.Items) {
            if ($item -is [System.Windows.Controls.CheckBox]) { $names += "$($item.Tag)" }
        }
        if ($names.Count -eq 0) { return }
        $msg = "Permanently remove ALL $($names.Count) VM(s)?`r`n`r`nThis includes VMs you did not create with VM-Pilot."
        $ans = [System.Windows.MessageBox]::Show($msg, 'Confirm Remove ALL',
            [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
        Remove-VMs -Names $names
        Update-VmList
    })

    $BtnClose.Add_Click({ $dlg.Close() })

    Update-VmList
    [void]$dlg.ShowDialog()
    Set-Status -Text ''
}

$CleanupButton.Add_Click({ Show-CleanupDialog })

# Open Intune AutoPilot devices page in the default browser
$IntuneButton.Add_Click({
    try { Start-Process $script:IntuneAutopilotUrl -ErrorAction Stop }
    catch { Set-Status -Text "Failed to open browser: $($_.Exception.Message)" }
})

# Exit: close the host GUI (Closing handler still cleans up runspace/PSInst)
$ExitButton.Add_Click({ $window.Close() })

$window.Add_Closing({
    if ($script:PSInst)   { try { $script:PSInst.Stop() | Out-Null; $script:PSInst.Dispose() } catch { } }
    if ($script:Runspace) { try { $script:Runspace.Close(); $script:Runspace.Dispose() } catch { } }
})

[void]$window.ShowDialog()
