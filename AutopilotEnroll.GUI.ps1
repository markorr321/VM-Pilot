# AutopilotEnroll.GUI.ps1 -- runs INSIDE the VM at OOBE.
# Minimal WPF window that fronts Get-WindowsAutopilotInfoCommunity.ps1.
# Launched by C:\Enroll.bat from the OOBE Shift+F10 cmd prompt.
#
# Click "Enroll Device" -> launches the community script in a visible PowerShell
# window with -Online -Reboot (plus GroupTag/AssignedUser if filled in).
# Community script then: uploads hash -> polls state.deviceImportStatus until
# 'complete' -> triggers sync -> polls deploymentProfileAssignmentStatus until
# 'assigned' -> Restart-Computer -Force (from OOBE context, so the reboot
# returns to OOBE -> AutoPilot self-enrolls).

[CmdletBinding()]
param(
    [string]$GroupTag     = '',
    [string]$AssignedUser = '',
    [string]$ScriptPath   = 'C:\Get-WindowsAutopilotInfoCommunity.ps1'
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$serial = try { (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber } catch { 'unavailable' }

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VM-Pilot"
        Width="500" Height="540"
        WindowStartupLocation="CenterScreen"
        Background="#161616" Foreground="#FFFFFF"
        FontFamily="Segoe UI Variable, Segoe UI"
        ResizeMode="CanMinimize">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#1F1F1F"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#3A3A3A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="CaretBrush" Value="#FFFFFF"/>
      <Setter Property="SelectionBrush" Value="#0078D4"/>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#909090"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="2,0,0,6"/>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="#0078D4"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="48"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1F8AE0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#2A2A2A"/>
                <Setter Property="Foreground" Value="#707070"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="28">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,20">
      <TextBlock Text="VM-Pilot" FontSize="22" FontWeight="SemiBold"/>
      <TextBlock Text="AutoPilot Enrollment" Foreground="#909090" FontSize="13" Margin="0,2,0,0"/>
      <TextBlock x:Name="SerialText" Foreground="#909090" FontSize="12" Margin="0,4,0,0"/>
    </StackPanel>

    <StackPanel Grid.Row="1" Margin="0,0,0,14">
      <TextBlock Text="GROUP TAG (OPTIONAL)" Style="{StaticResource FieldLabel}"/>
      <TextBox x:Name="GroupTagBox"/>
    </StackPanel>

    <StackPanel Grid.Row="2" Margin="0,0,0,20">
      <TextBlock Text="ASSIGNED USER UPN (OPTIONAL)" Style="{StaticResource FieldLabel}"/>
      <TextBox x:Name="UserUpnBox"/>
    </StackPanel>

    <Button Grid.Row="3" x:Name="RunButton" Content="ENROLL DEVICE" Style="{StaticResource PrimaryButton}" Margin="0,0,0,18"/>

    <Border Grid.Row="4" Height="1" Background="#2A2A2A" Margin="0,0,0,16"/>

    <TextBlock Grid.Row="5" x:Name="StatusText"
               Text="Click ENROLL DEVICE. The community script will: sign in (browser opens) -&gt; upload hash -&gt; wait for AutoPilot profile assignment -&gt; reboot the VM back to OOBE so AutoPilot can enroll."
               Foreground="#A0A0A0" FontSize="13" TextWrapping="Wrap"/>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$SerialText  = $window.FindName('SerialText')
$GroupTagBox = $window.FindName('GroupTagBox')
$UserUpnBox  = $window.FindName('UserUpnBox')
$RunButton   = $window.FindName('RunButton')
$StatusText  = $window.FindName('StatusText')

$SerialText.Text  = "Device serial: $serial"
$GroupTagBox.Text = $GroupTag
$UserUpnBox.Text  = $AssignedUser

$RunButton.Add_Click({
    if (-not (Test-Path $ScriptPath -PathType Leaf)) {
        $StatusText.Text       = "Community script not found at $ScriptPath."
        $StatusText.Foreground = '#F03A47'
        return
    }

    $RunButton.IsEnabled = $false
    $RunButton.Content   = 'ENROLLING...'
    $StatusText.Text     = 'Running community AutoPilot script. A PowerShell window will show progress: upload -> wait for assignment -> reboot. Sign in when the Microsoft browser appears.'

    # -Online   = upload hash + trigger sync
    # -Assign   = wait for AutoPilot profile assignment to land (REQUIRED for -Reboot to fire)
    # -Reboot   = Restart-Computer -Force once assignment lands (from OOBE context -> returns to OOBE)
    # -NoExit   = keep the PowerShell window open so the user can see what the script is doing
    $apArgs = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-NoExit',
        '-File', $ScriptPath,
        '-Online','-Assign','-Reboot'
    )
    $tag = $GroupTagBox.Text.Trim()
    $upn = $UserUpnBox.Text.Trim()
    if ($tag) { $apArgs += '-GroupTag';     $apArgs += $tag }
    if ($upn) { $apArgs += '-AssignedUser'; $apArgs += $upn }

    Start-Process -FilePath 'powershell.exe' -ArgumentList $apArgs | Out-Null
})

[void]$window.ShowDialog()
