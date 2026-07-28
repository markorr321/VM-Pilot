# VMPilot - WPF GUI (dark, minimal)
# Spins up a fresh Hyper-V VM from a cached parent VHDX, collects the AutoPilot
# hardware hash, and optionally imports it to Intune via Microsoft Graph.
# Auto-elevates; hides host console; runs the workflow in a background runspace.

# --- Auto-elevate ---------------------------------------------------------
# Spawn the elevated child via Shell.Application.ShellExecute with show=0
# (SW_HIDE). Start-Process -WindowStyle Hidden hides the console AFTER it
# paints — produces a console flash before UAC, then another after acceptance.
# ShellExecute(verb='runas', show=0) creates the window in SW_HIDE from the
# start, so only the UAC prompt itself is visible.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $psExe   = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    $shell   = New-Object -ComObject Shell.Application
    try {
        $shell.ShellExecute($psExe, $argLine, '', 'runas', 0)
    } finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
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

# --- Shared dark theme ----------------------------------------------------
# One dictionary behind every window VM-Pilot shows: the main window, the
# Hyper-V prompts, the ISO wizard, the VM Cleanup dialog and every modal in
# between. Ported from Get-WindowsAutopilotImportGUICommunity's
# src\Themes\Dark.xaml so the two tools read as one family on a technician's
# bench — that theme's palette and its PrimaryButton / FieldLabel / Segment
# styles started life here in VM-Pilot, and this brings the rest home.
#
# Everything is hand-templated because WPF's stock templates are light-themed:
# a plain Background setter leaves CheckBoxes, ListBox rows and ScrollBars
# stubbornly grey-on-white, which is what made [System.Windows.MessageBox]
# look pasted-in from another decade.
#
# Deliberately NO implicit <Style TargetType="TextBlock">. An implicit TextBlock
# style also applies to the TextBlock a ContentPresenter generates for string
# content, so a Foreground or FontSize setter there silently overrides every
# button and segmented-control template — an unchecked Segment would render
# white instead of #A8A8A8. Text styling is keyed only; windows inherit
# Foreground and FontFamily from the Window element instead.
#
# StaticResource resolves backwards only, so brushes come first.
$script:ThemeToken = '<!-- @THEME@ -->'
$script:ThemeXaml = @'
    <!-- ===================== palette ===================== -->
    <SolidColorBrush x:Key="WindowBackground"   Color="#161616"/>
    <SolidColorBrush x:Key="SurfaceBackground"  Color="#1F1F1F"/>
    <SolidColorBrush x:Key="SurfaceRaised"      Color="#252525"/>
    <SolidColorBrush x:Key="SurfaceHover"       Color="#2A2A2A"/>
    <SolidColorBrush x:Key="BorderBrushSubtle"  Color="#2A2A2A"/>
    <SolidColorBrush x:Key="BorderBrushNormal"  Color="#3A3A3A"/>
    <SolidColorBrush x:Key="BorderBrushStrong"  Color="#4A4A4A"/>

    <SolidColorBrush x:Key="AccentBrush"        Color="#0078D4"/>
    <SolidColorBrush x:Key="AccentBrushHover"   Color="#1F8AE0"/>
    <SolidColorBrush x:Key="AccentBrushPressed" Color="#0061B0"/>

    <SolidColorBrush x:Key="TextPrimary"        Color="#FFFFFF"/>
    <SolidColorBrush x:Key="TextSecondary"      Color="#C0C0C0"/>
    <SolidColorBrush x:Key="TextMuted"          Color="#909090"/>
    <SolidColorBrush x:Key="TextDisabled"       Color="#707070"/>

    <SolidColorBrush x:Key="SuccessBrush"       Color="#107C41"/>
    <SolidColorBrush x:Key="SuccessBrushHover"  Color="#138A48"/>
    <SolidColorBrush x:Key="SuccessBrushPressed" Color="#0B5A2F"/>
    <SolidColorBrush x:Key="SuccessBrushLight"  Color="#1ACB5F"/>
    <SolidColorBrush x:Key="ErrorBrush"         Color="#F03A47"/>
    <SolidColorBrush x:Key="ErrorBrushHover"    Color="#FF5560"/>
    <SolidColorBrush x:Key="ErrorBrushPressed"  Color="#C92B37"/>
    <SolidColorBrush x:Key="ErrorBrushDim"      Color="#C92B37"/>

    <FontFamily x:Key="MonoFont">Cascadia Mono, Consolas, Courier New</FontFamily>

    <!-- ===================== text ===================== -->
    <!-- Uppercase micro-label above an input. -->
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="2,0,0,8"/>
    </Style>

    <Style x:Key="DialogTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>

    <Style x:Key="DialogMessage" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextSecondary}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,10,0,0"/>
    </Style>

    <Style x:Key="PageSubtitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,6,0,0"/>
    </Style>

    <Style x:Key="HintText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextDisabled}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="2,5,0,0"/>
    </Style>

    <Style x:Key="StepText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E0E0E0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,7"/>
    </Style>

    <!-- ===================== surfaces ===================== -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource SurfaceBackground}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrushSubtle}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16,14"/>
    </Style>

    <Style x:Key="Divider" TargetType="Border">
      <Setter Property="Height" Value="1"/>
      <Setter Property="Background" Value="{StaticResource BorderBrushSubtle}"/>
    </Style>

    <!-- ===================== buttons ===================== -->
    <!-- Main call to action. Dialogs re-use it at Height="36". -->
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="52"/>
      <Setter Property="Padding" Value="20,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentBrushHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentBrushPressed}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource SurfaceHover}"/>
                <Setter Property="Foreground" Value="{StaticResource TextDisabled}"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Toolbar-sized accent button (OPEN AUTOPILOT, REMOVE SELECTED). -->
    <Style x:Key="PrimaryButtonSmall" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
      <Setter Property="Height" Value="36"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="14,0"/>
    </Style>

    <!-- Constructive/green: SETUP, BUILD VHDX FROM ISO. -->
    <Style x:Key="SuccessButton" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource SuccessBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource SuccessBrushHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource SuccessBrushPressed}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource SurfaceHover}"/>
                <Setter Property="Foreground" Value="{StaticResource TextDisabled}"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Neutral/outlined: CLOSE, EXIT, dialog Cancel. -->
    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource SurfaceBackground}"/>
      <Setter Property="Foreground" Value="{StaticResource TextSecondary}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrushNormal}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource SurfaceHover}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BorderBrushStrong}"/>
                <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{StaticResource TextDisabled}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BorderBrushSubtle}"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Destructive confirm inside a dialog: outlined, so it never reads as the
         safe default the way a solid button does. -->
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource SecondaryButton}">
      <Setter Property="Foreground" Value="{StaticResource ErrorBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ErrorBrushDim}"/>
    </Style>

    <!-- Destructive entry point on a toolbar (CLEANUP VMs, REMOVE ALL), where the
         action still needs to be findable at a glance. -->
    <Style x:Key="DangerButtonSolid" TargetType="Button" BasedOn="{StaticResource PrimaryButtonSmall}">
      <Setter Property="Background" Value="{StaticResource ErrorBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource ErrorBrushHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource ErrorBrushPressed}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource SurfaceHover}"/>
                <Setter Property="Foreground" Value="{StaticResource TextDisabled}"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===================== segmented control ===================== -->
    <Style x:Key="Segment" TargetType="RadioButton">
      <Setter Property="Background" Value="{StaticResource SurfaceBackground}"/>
      <Setter Property="Foreground" Value="#A8A8A8"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrushNormal}"/>
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
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource SurfaceHover}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BorderBrushStrong}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{StaticResource TextDisabled}"/>
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource WindowBackground}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BorderBrushSubtle}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===================== inputs ===================== -->
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource SurfaceBackground}"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrushNormal}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,11"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="CaretBrush" Value="{StaticResource TextPrimary}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource AccentBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" SnapsToDevicePixels="True">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                            Focusable="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BorderBrushStrong}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{StaticResource TextDisabled}"/>
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource WindowBackground}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BorderBrushSubtle}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Read-only monospaced block: dialog detail, VM lists, command previews.
         Selectable on purpose — the point of showing a path or a serial is that
         the tech can copy it. -->
    <Style x:Key="OutputBox" TargetType="TextBox">
      <Setter Property="Background" Value="#121212"/>
      <Setter Property="Foreground" Value="{StaticResource TextSecondary}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrushSubtle}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontFamily" Value="{StaticResource MonoFont}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="IsReadOnlyCaretVisible" Value="False"/>
      <Setter Property="TextWrapping" Value="NoWrap"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
      <Setter Property="SelectionBrush" Value="{StaticResource AccentBrush}"/>
      <Setter Property="VerticalContentAlignment" Value="Top"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextSecondary}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,5,0,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="Box" Grid.Column="0" Width="18" Height="18" CornerRadius="4"
                      Background="{StaticResource SurfaceBackground}"
                      BorderBrush="{StaticResource BorderBrushNormal}" BorderThickness="1"
                      VerticalAlignment="Center" SnapsToDevicePixels="True">
                <Path x:Name="Tick" Data="M 2,6 L 6,10 L 12,2" Stroke="{StaticResource TextPrimary}"
                      StrokeThickness="2" Visibility="Collapsed"
                      HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center"
                                RecognizesAccessKey="True"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource BorderBrushStrong}"/>
                <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{StaticResource TextDisabled}"/>
                <Setter TargetName="Box" Property="Background" Value="{StaticResource WindowBackground}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource BorderBrushSubtle}"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===================== progress ===================== -->
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Background" Value="{StaticResource SurfaceRaised}"/>
      <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border Background="{TemplateBinding Background}" CornerRadius="3"/>
              <!-- PART_Track / PART_Indicator are required by ProgressBar's
                   contract; the indeterminate animation drives PART_Indicator. -->
              <Border x:Name="PART_Track" Background="Transparent"/>
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}"
                      CornerRadius="3" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===================== scrollbar ===================== -->
    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="Bd" Background="#3A3A3A" CornerRadius="4" Margin="3,0,3,0"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#565656"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="12"/>
      <Setter Property="MinWidth" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}"/>
                </Track.Thumb>
                <!-- Empty repeat buttons: no classic arrow boxes, but the
                     page-scroll click targets above and below still work. -->
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter Property="Height" Value="12"/>
                <Setter Property="MinHeight" Value="12"/>
                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollViewer">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <!-- ===================== list ===================== -->
    <!-- Stock ListBoxItem paints a system-blue selection block that survives any
         Background setter, so the row is fully templated too. -->
    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}"
                    SnapsToDevicePixels="True">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource SurfaceHover}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource SurfaceRaised}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Background" Value="{StaticResource SurfaceBackground}"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrushSubtle}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="4"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBox">
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" SnapsToDevicePixels="True">
              <ScrollViewer Padding="{TemplateBinding Padding}" Focusable="False">
                <ItemsPresenter/>
              </ScrollViewer>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@

function Get-ThemedXaml {
    <#
    .SYNOPSIS
        A window's XAML with the shared theme spliced in.
    .DESCRIPTION
        StaticResource only resolves against resources that already exist when
        the tree is built, so merging a dictionary after XamlReader.Load is too
        late and a loose script has no pack:// URI to reference. The theme is
        therefore spliced into <Window.Resources> at the @THEME@ token before
        parsing.
    #>
    param([Parameter(Mandatory)][string]$WindowXaml)

    if ($WindowXaml -notmatch [regex]::Escape($script:ThemeToken)) {
        throw "Window XAML is missing the $script:ThemeToken token, so the theme cannot be applied."
    }
    return $WindowXaml.Replace($script:ThemeToken, $script:ThemeXaml)
}

function New-ThemedWindow {
    <#
    .SYNOPSIS
        Loads themed window XAML into a Window instance.
    #>
    param([Parameter(Mandatory)][string]$WindowXaml)

    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml((Get-ThemedXaml -WindowXaml $WindowXaml))
    return [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
}

# --- Hyper-V startup check ------------------------------------------------
# Module ships via PSGallery; on a fresh install we can't assume Hyper-V is
# present. Detect early and offer to enable + reboot before any code path
# tries to call Get-VM.

function Show-VMPilotDialog {
    <#
    .SYNOPSIS
        Themed modal prompt. Returns 'Primary', 'Secondary' or 'Closed'.
    .DESCRIPTION
        Replaces [System.Windows.MessageBox], which renders a light-grey box
        with a system font in the middle of a dark app and cannot show
        selectable text — which matters when the message carries a path, a
        serial or a VM list the tech needs to copy.

        Layout matches Show-ApDialog in Get-WindowsAutopilotImportGUICommunity:
        title, wrapped message, optional monospaced detail block, then the
        buttons right-aligned with the confirm action last.
    .PARAMETER Detail
        Optional selectable, monospaced block below the message.
    .PARAMETER Danger
        Style the primary button as destructive (outlined red).
    #>
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Message,
        [string]$Detail,
        [string]$PrimaryText   = 'OK',
        [string]$SecondaryText,
        [switch]$Danger,
        [int]$Width = 480,
        $Owner
    )
    $hasSecondary = -not [string]::IsNullOrWhiteSpace($SecondaryText)
    $primaryStyle = if ($Danger) { 'DangerButton' } else { 'PrimaryButton' }

    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$([System.Security.SecurityElement]::Escape($Title))"
        SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterScreen"
        Background="#161616" Foreground="#FFFFFF"
        FontFamily="Segoe UI Variable, Segoe UI"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    $script:ThemeToken
  </Window.Resources>
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock x:Name="DlgTitle" Grid.Row="0" Style="{StaticResource DialogTitle}"/>
    <TextBlock x:Name="DlgMessage" Grid.Row="1" Style="{StaticResource DialogMessage}"/>
    <TextBox   x:Name="DlgDetail" Grid.Row="2" Style="{StaticResource OutputBox}"
               Margin="0,14,0,0" MaxHeight="220" TextWrapping="Wrap" Visibility="Collapsed"/>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
      <Button x:Name="BtnSecondary" Style="{StaticResource SecondaryButton}"
              MinWidth="110" Margin="0,0,8,0" Visibility="Collapsed"/>
      <Button x:Name="BtnPrimary" Style="{StaticResource $primaryStyle}"
              Height="36" MinWidth="130"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $dlg = New-ThemedWindow -WindowXaml $x
    $dlg.Width = $Width
    if ($Owner) {
        $dlg.Owner = $Owner
        $dlg.WindowStartupLocation = 'CenterOwner'
    }

    $dlg.FindName('DlgTitle').Text   = $Title
    $dlg.FindName('DlgMessage').Text = $Message

    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $detailBox = $dlg.FindName('DlgDetail')
        $detailBox.Text       = $Detail
        $detailBox.Visibility = 'Visible'
    }

    # DialogResult is what ShowDialog returns, and setting it closes the window.
    # Driving the close through DialogResult rather than Close() is what lets the
    # secondary button be IsCancel (Esc): WPF sets DialogResult itself for an
    # IsCancel button, and a handler that had already called Close() would then
    # be setting DialogResult on a closed window, which throws.
    $btnPrimary = $dlg.FindName('BtnPrimary')
    $btnPrimary.Content   = $PrimaryText
    $btnPrimary.IsDefault = $true
    $btnPrimary.Add_Click({ $dlg.DialogResult = $true }.GetNewClosure())

    $btnSecondary = $dlg.FindName('BtnSecondary')
    if ($hasSecondary) {
        $btnSecondary.Content    = $SecondaryText
        $btnSecondary.Visibility = 'Visible'
        $btnSecondary.IsCancel   = $true
    }

    # $null when the window was dismissed with its X rather than a button.
    $result = $dlg.ShowDialog()
    if ($result -eq $true)  { return 'Primary' }
    if ($result -eq $false) { return 'Secondary' }
    return 'Closed'
}

function Test-HyperVState {
    # Fast path #1: cmdlet present → feature is live
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) { return 'Ready' }

    # Fast path #2: SKU check via WMI is sub-second. Pro / Enterprise /
    # Education / Workstations / Server all support Hyper-V; Home does not.
    # We prefer this over Get-WindowsOptionalFeature (which calls DISM and
    # routinely takes 15-45 seconds per feature lookup) and treat any
    # supported SKU as 'Disabled' if the cmdlet check above came back empty.
    # The enable step will surface any real DISM error if our assumption is
    # wrong — that's a 1-second cost vs. 45 seconds of unconditional probing.
    try {
        $caption = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption
        if ($caption -notmatch 'Home' -and
            $caption -match 'Pro|Enterprise|Education|Workstation|Server') {
            return 'Disabled'
        }
    } catch { }

    return 'NotAvailable'
}

function Invoke-EnableHyperVWithProgress {
    # Shows a progress dialog while dism.exe enables Microsoft-Hyper-V-All in
    # the background. A DispatcherTimer polls the child process so the
    # indeterminate progress bar keeps animating. Returns
    # @{ Success = bool; Error = string }.
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Enabling Hyper-V" Width="440" SizeToContent="Height"
        WindowStartupLocation="CenterScreen"
        Background="#161616" Foreground="#FFFFFF"
        FontFamily="Segoe UI Variable, Segoe UI" ResizeMode="NoResize"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    $script:ThemeToken
  </Window.Resources>
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Enabling Hyper-V" Style="{StaticResource DialogTitle}"/>
    <TextBlock Grid.Row="1" Style="{StaticResource DialogMessage}" Margin="0,10,0,18"
               Text="This takes about a minute. Please don't close this window."/>
    <ProgressBar Grid.Row="2" IsIndeterminate="True"/>
  </Grid>
</Window>
"@
    $dlg = New-ThemedWindow -WindowXaml $x

    # Call dism.exe directly. The PowerShell Enable-WindowsOptionalFeature
    # cmdlet relies on DISM COM components that are sometimes misregistered
    # on IT-managed Enterprise machines (HRESULT 0x80040154 "Class not
    # registered"). dism.exe is a native binary that does the same work
    # without that dependency. Exit codes: 0 = success, 3010 = success +
    # reboot required (which is exactly what we expect for Hyper-V enable).
    $dismExe = Join-Path $env:WINDIR 'System32\dism.exe'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $dismExe
    $psi.Arguments              = '/Online /Enable-Feature /FeatureName:Microsoft-Hyper-V-All /All /NoRestart /Quiet'
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow         = $true
    $proc = [System.Diagnostics.Process]::Start($psi)

    $script:__enableResult = $null
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({
        if ($proc.HasExited) {
            $timer.Stop()
            $stdoutText = $proc.StandardOutput.ReadToEnd().Trim()
            $stderrText = $proc.StandardError.ReadToEnd().Trim()
            if ($proc.ExitCode -in 0, 3010) {
                $script:__enableResult = @{ Success = $true; Error = $null }
            } else {
                $combined = (($stderrText, $stdoutText) -join "`n").Trim()
                $errMsg = if ($combined) { $combined } else { "dism.exe exit code $($proc.ExitCode)" }
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
                -Message 'dism.exe could not enable the Hyper-V feature. Its output is below.' `
                -Detail $msg -PrimaryText 'OK' -Width 620)
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
$script:BootSource         = 'C:\VMs\Win11-25H2.vhdx'
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
$script:FilesToCopy        = @('C:\Autopilot CSV Collection\AutoPilotHWID-Collection.bat')
$script:SearchPattern      = 'AutoPilotHWID*'   # Offline v1 — hash CSV
$script:SearchPatternV2    = 'AutoPilotID*'     # Offline v2 — identifier CSV
$script:SourceFolder       = 'HWID'
$script:DestinationPath    = 'C:\Autopilot CSV Collection'   # holds both v1 hash and v2 identifier CSVs
# Online mode injects ONE entry point: C:\import.bat. It installs the
# Get-WindowsAutopilotImportGUICommunity script from PSGallery and runs it —
# a single self-contained GUI that covers AutoPilot v1 (hardware hash) and v2
# (Device preparation identifier), so the VM needs no other pre-injected files.
$script:ImportScriptName = 'Get-WindowsAutopilotImportGUICommunity'
$script:ImportBatInVM    = 'import.bat'   # lands at C:\import.bat
$script:CollectScriptInVM    = 'VMPilotCollect.ps1'                      # Offline: lands at C:\<this>, called by SetupComplete.cmd
$script:IntuneAutopilotUrl   = 'https://intune.microsoft.com/#view/Microsoft_Intune_Enrollment/AutopilotDevices.ReactView/filterOnManualRemediationRequired~/false'

# --- XAML -----------------------------------------------------------------
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VM-Pilot"
        Width="600" Height="940"
        WindowStartupLocation="CenterScreen"
        Background="#161616"
        Foreground="#FFFFFF"
        FontFamily="Segoe UI Variable, Segoe UI"
        ResizeMode="CanMinimize"
        UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">

  <Window.Resources>
    $script:ThemeToken
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
      <TextBlock Text="Spin up a fresh Hyper-V VM and collect its AutoPilot hardware hash or device identifier." Foreground="#909090" FontSize="13" Margin="0,6,0,0"/>
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
          <RadioButton x:Name="Rel25H2" GroupName="Release" Content="25H2" IsChecked="True" IsEnabled="False" Style="{StaticResource Segment}"/>
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

    <!-- Offline-only fields (toggled by Update-ModeUI). Online mode picks its
         AutoPilot version and group tag inside the VM instead: run import.bat
         at the OOBE Shift+F10 prompt and choose v1 or v2 in that GUI. -->
    <StackPanel Grid.Row="4" x:Name="OfflinePanel" Margin="0,0,0,18">
      <TextBlock Text="AUTOPILOT VERSION" Style="{StaticResource FieldLabel}"/>
      <Grid Margin="0,0,0,14">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="6"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <RadioButton Grid.Column="0" x:Name="ApV1" GroupName="ApVersion" Content="v1 Hash" IsChecked="True" Style="{StaticResource Segment}"/>
        <RadioButton Grid.Column="2" x:Name="ApV2" GroupName="ApVersion" Content="v2 Identifier" Style="{StaticResource Segment}"/>
      </Grid>

      <!-- v1 only: identifier imports have no group tag. -->
      <StackPanel x:Name="GroupTagPanel">
        <TextBlock Text="GROUP TAG (OPTIONAL)" Style="{StaticResource FieldLabel}"/>
        <TextBox x:Name="GroupTagBox" Text=""/>
      </StackPanel>
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
        <ProgressBar x:Name="ActivityBar" Height="4" IsIndeterminate="True" Visibility="Collapsed"/>
      </StackPanel>

      <!-- Center stack: Complete (or red error) + the serial number block -->
      <StackPanel Grid.Row="1" VerticalAlignment="Center" HorizontalAlignment="Center">
        <TextBlock x:Name="CompletedIcon" Text="Complete"
                   FontSize="26" FontWeight="SemiBold" Foreground="#1ACB5F"
                   HorizontalAlignment="Center" TextAlignment="Center"
                   Padding="0,2,0,4"
                   Visibility="Collapsed"/>

        <TextBlock x:Name="ResultText" Text=""
                   FontSize="13" Foreground="#F03A47" TextWrapping="Wrap"
                   HorizontalAlignment="Center" TextAlignment="Center"
                   Visibility="Collapsed"/>

        <!-- DEVICE SERIAL block: shown alongside Complete, auto-copied to clipboard -->
        <StackPanel x:Name="SerialPanel" Visibility="Collapsed" Margin="0,10,0,0">
          <TextBlock Text="DEVICE SERIAL" Style="{StaticResource FieldLabel}" HorizontalAlignment="Center"/>
          <TextBlock x:Name="SerialText" FontSize="14"
                     FontFamily="Cascadia Mono, Consolas, Courier New"
                     Foreground="#FFFFFF" HorizontalAlignment="Center" Margin="0,4,0,0"/>
          <TextBlock Text="copied to clipboard" FontSize="11"
                     Foreground="#707070" HorizontalAlignment="Center"
                     Margin="0,4,0,0" FontStyle="Italic"/>
        </StackPanel>

        <!-- CSV path: shown after an Offline collect. The .csv on the host holding
             the AutoPilot hardware hash (v1) or device identifier (v2); the link
             opens its folder. The label is retitled per version at collect time. -->
        <StackPanel x:Name="HashPanel" Visibility="Collapsed" Margin="0,10,0,0">
          <TextBlock x:Name="HashPanelLabel" Text="HARDWARE HASH SAVED TO" Style="{StaticResource FieldLabel}" HorizontalAlignment="Center"/>
          <TextBlock x:Name="HashPathText" FontSize="11"
                     FontFamily="Cascadia Mono, Consolas, Courier New"
                     Foreground="#C0C0C0" HorizontalAlignment="Center" TextAlignment="Center"
                     TextWrapping="Wrap" Margin="0,4,0,0"/>
          <TextBlock HorizontalAlignment="Center" Margin="0,5,0,0">
            <Hyperlink x:Name="HashOpenLink" Foreground="#3F9BFE" TextDecorations="Underline">
              <Run Text="Open folder"/>
            </Hyperlink>
          </TextBlock>
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

        <StackPanel Grid.Column="0" Orientation="Horizontal">
          <Button x:Name="IntuneButton" Content="OPEN AUTOPILOT" Width="148"
                  Style="{StaticResource PrimaryButtonSmall}"/>
          <Button x:Name="IsoWizardButton" Content="SETUP" Width="150" Margin="8,0,0,0"
                  Style="{StaticResource SuccessButton}"/>
        </StackPanel>

        <Button Grid.Column="2" x:Name="CleanupButton" Content="CLEANUP VMs" Width="132"
                Style="{StaticResource DangerButtonSolid}"/>

        <Button Grid.Column="3" x:Name="ExitButton" Content="EXIT" Width="84" Margin="8,0,0,0"
                Style="{StaticResource SecondaryButton}"/>
      </Grid>
    </Grid>
  </Grid>
</Window>
"@

$window = New-ThemedWindow -WindowXaml $xaml

$VMNameBox      = $window.FindName('VMNameBox')
$RunButton      = $window.FindName('RunButton')
$StatusText     = $window.FindName('StatusText')
$ActivityBar    = $window.FindName('ActivityBar')
$ResultText     = $window.FindName('ResultText')
$CompletedIcon  = $window.FindName('CompletedIcon')
$ModeOffline    = $window.FindName('ModeOffline')
$ModeOnline     = $window.FindName('ModeOnline')
$GroupTagBox    = $window.FindName('GroupTagBox')
$GroupTagPanel  = $window.FindName('GroupTagPanel')
$OfflinePanel   = $window.FindName('OfflinePanel')
$ApV1           = $window.FindName('ApV1')
$ApV2           = $window.FindName('ApV2')
$SerialPanel    = $window.FindName('SerialPanel')
$SerialText     = $window.FindName('SerialText')
$HashPanel      = $window.FindName('HashPanel')
$HashPanelLabel = $window.FindName('HashPanelLabel')
$HashPathText   = $window.FindName('HashPathText')
$HashOpenLink   = $window.FindName('HashOpenLink')
$CleanupButton    = $window.FindName('CleanupButton')
$IntuneButton     = $window.FindName('IntuneButton')
$IsoWizardButton  = $window.FindName('IsoWizardButton')
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

# --- Mode toggle: swap button label + show/hide the Offline-only fields ----
# Offline also picks the AutoPilot version here; v2 collects an identifier
# (Manufacturer,Model,Serial), which has no group tag, so that field hides.
function Update-ModeUI {
    if ($ModeOnline.IsChecked) {
        $RunButton.Content        = 'COLLECT & UPLOAD'
        $OfflinePanel.Visibility  = 'Collapsed'
    } else {
        $OfflinePanel.Visibility  = 'Visible'
        if ($ApV2.IsChecked) {
            $RunButton.Content        = 'COLLECT IDENTIFIER'
            $GroupTagPanel.Visibility = 'Collapsed'
        } else {
            $RunButton.Content        = 'COLLECT HWID'
            $GroupTagPanel.Visibility = 'Visible'
        }
    }
}
$ModeOffline.Add_Checked({ Update-ModeUI })
$ModeOnline.Add_Checked({ Update-ModeUI })
$ApV1.Add_Checked({ Update-ModeUI })
$ApV2.Add_Checked({ Update-ModeUI })
Update-ModeUI   # apply initial state (Offline + v1 → Group Tag visible)

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
        $HashPanel.Visibility     = 'Collapsed'
        $HashPathText.Text        = ''
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

# Guided "Get Windows ISO" wizard. Walks the user through downloading a
# Windows 11 ISO from Microsoft's official page, then runs the builder on
# the ISO they picked (same code path as Get-Win11VHDX.ps1 -PickIso — the
# builder auto-detects the release from the ISO and names the VHDX
# C:\VMs\Win11-<release>.vhdx, exactly where the GUI looks for it). The
# build streams live progress into this window via a runspace + Dispatcher,
# mirroring Start-Workflow. The file picker runs here on the UI thread
# (owned by this window) rather than inside the runspace, so it can't pop
# up behind the wizard.
$script:WizRunspace  = $null
$script:WizPSInst    = $null
$script:WizApplyTimer = $null
function Show-Win11IsoWizard {
    $downloadUrl = 'https://www.microsoft.com/en-us/software-download/windows11'

    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Get Windows 11 Install Media" Width="560" SizeToContent="Height"
        WindowStartupLocation="CenterOwner"
        Background="#161616" Foreground="#FFFFFF"
        FontFamily="Segoe UI Variable, Segoe UI" ResizeMode="NoResize"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    $script:ThemeToken
  </Window.Resources>
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Text="Get Windows 11 Install Media" Style="{StaticResource DialogTitle}" FontSize="20"/>
    <TextBlock Grid.Row="1" Style="{StaticResource DialogMessage}" Margin="0,8,0,18"
               Text="Download a Windows 11 ISO from Microsoft, then build the VM-Pilot parent VHDX from it. The VHDX is auto-named after the release inside the ISO."/>

    <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,0,0,18">
      <StackPanel>
        <TextBlock Style="{StaticResource StepText}" Text="1.  Click OPEN DOWNLOAD PAGE below."/>
        <TextBlock Style="{StaticResource StepText}" Text="2.  Under &quot;Download Windows 11 Disk Image (ISO) for x64 devices&quot;, pick &quot;Windows 11 (multi-edition ISO for x64 devices)&quot; from the drop-down, then click Download."/>
        <TextBlock Style="{StaticResource StepText}" Text="3.  In &quot;Select the product language&quot;, choose your language and click Confirm. (The page won't download yet - it prepares your link.)"/>
        <TextBlock Style="{StaticResource StepText}" Text="4.  Click the &quot;64-bit Download&quot; button that now appears and save the .iso file. (The link is valid for 24 hours.)"/>
        <TextBlock Style="{StaticResource StepText}" Margin="0" Text="5.  Once the download is complete, come back here, click BUILD VHDX FROM ISO, pick the file you saved, and wait for the build to finish."/>
      </StackPanel>
    </Border>

    <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,0,0,8">
      <Button x:Name="BtnOpenPage" Content="OPEN DOWNLOAD PAGE" Width="200" Height="40"
              Style="{StaticResource PrimaryButtonSmall}"/>
      <Button x:Name="BtnBuild" Content="BUILD VHDX FROM ISO" Width="210" Height="40" Margin="10,0,0,0"
              Style="{StaticResource SuccessButton}"/>
    </StackPanel>

    <StackPanel Grid.Row="4" Margin="0,8,0,0">
      <TextBlock x:Name="WizStatus" Foreground="#C0C0C0" FontSize="12" TextWrapping="Wrap"
                 Visibility="Collapsed" Margin="0,0,0,8"/>
      <ProgressBar x:Name="WizBar" Height="4" IsIndeterminate="True"
                   Foreground="{StaticResource SuccessBrush}"
                   Visibility="Collapsed"/>
    </StackPanel>

    <Button Grid.Row="5" x:Name="BtnClose" Content="CLOSE" Width="100"
            HorizontalAlignment="Right" Margin="0,16,0,0"
            Style="{StaticResource SecondaryButton}"/>
  </Grid>
</Window>
"@
    $dlg = New-ThemedWindow -WindowXaml $x
    $dlg.Owner = $window

    $btnOpen  = $dlg.FindName('BtnOpenPage')
    $btnBuild = $dlg.FindName('BtnBuild')
    $btnClose = $dlg.FindName('BtnClose')
    $wizStatus = $dlg.FindName('WizStatus')
    $wizBar    = $dlg.FindName('WizBar')

    $btnOpen.Add_Click({
        try { Start-Process $downloadUrl } catch {
            $wizStatus.Visibility = 'Visible'
            $wizStatus.Foreground = '#F03A47'
            $wizStatus.Text = "Couldn't open the browser. Go to: $downloadUrl"
        }
    })

    $btnBuild.Add_Click({
        # Guard: if a parent VHDX already exists, warn BEFORE the file picker
        # and the build. Rebuilding replaces it, and it's blocked entirely
        # while a VM depends on it — so catch that here instead of after a
        # doomed build. Best-effort; if Hyper-V queries fail we still warn
        # about the file existing.
        $existing = @(Get-ChildItem 'C:\VMs\Win11-*.vhdx' -File -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) {
            $deps = @()
            try {
                $targets = @($existing | ForEach-Object { [System.IO.Path]::GetFullPath($_.FullName) })
                foreach ($vm in (Get-VM -ErrorAction SilentlyContinue)) {
                    foreach ($d in (Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue)) {
                        if (-not $d.Path) { continue }
                        $dpFull = [System.IO.Path]::GetFullPath($d.Path)
                        $info   = Get-VHD -Path $d.Path -ErrorAction SilentlyContinue
                        $parent = if ($info -and $info.ParentPath) { [System.IO.Path]::GetFullPath($info.ParentPath) } else { $null }
                        if (($targets -contains $dpFull) -or ($parent -and ($targets -contains $parent))) { $deps += $vm.Name; break }
                    }
                }
            } catch { }
            $deps = @($deps | Select-Object -Unique)

            $msg    = 'Rebuilding replaces the parent VHDX that already exists.'
            $detail = ($existing | ForEach-Object { $_.FullName }) -join "`r`n"
            if ($deps.Count) {
                $msg   += ' The VM(s) listed below depend on it and must be removed first (CLEANUP VMs), or the rebuild will be blocked.'
                $detail += "`r`n`r`nDependent VMs:`r`n  " + ($deps -join "`r`n  ")
            }
            $ans = Show-VMPilotDialog -Title 'Parent VHDX already exists' -Message "$msg`r`n`r`nRebuild anyway?" `
                -Detail $detail -PrimaryText 'REBUILD' -SecondaryText 'CANCEL' -Danger -Width 560 -Owner $dlg
            if ($ans -ne 'Primary') { return }
        }

        $ofd = New-Object Microsoft.Win32.OpenFileDialog
        $ofd.Filter      = 'Windows ISO (*.iso)|*.iso|All files (*.*)|*.*'
        $ofd.Title       = 'Select the Windows 11 ISO you downloaded'
        $ofd.Multiselect = $false
        if (-not $ofd.ShowDialog($dlg)) { return }
        $isoPath = $ofd.FileName

        if (-not (Test-Path $script:BuilderScript)) {
            $wizStatus.Visibility = 'Visible'; $wizStatus.Foreground = '#F03A47'
            $wizStatus.Text = "Builder not found: $script:BuilderScript"
            return
        }

        # Lock the UI while building; a mid-build close would orphan the runspace.
        $btnBuild.IsEnabled = $false; $btnBuild.Content = 'BUILDING…'
        $btnOpen.IsEnabled  = $false; $btnClose.IsEnabled = $false
        $wizStatus.Visibility = 'Visible'; $wizStatus.Foreground = '#C0C0C0'; $wizStatus.Text = 'Starting build…'
        $wizBar.Visibility = 'Visible'; $wizBar.IsIndeterminate = $true

        $wizState = [hashtable]::Synchronized(@{ Applying = $false })

        $shared = @{
            Window        = $dlg
            Status        = $wizStatus
            Bar           = $wizBar
            BuildBtn      = $btnBuild
            OpenBtn       = $btnOpen
            CloseBtn      = $btnClose
            BuilderScript = $script:BuilderScript
            IsoPath       = $isoPath
            WizState      = $wizState
        }

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        foreach ($k in $shared.Keys) { $rs.SessionStateProxy.SetVariable($k, $shared[$k]) }
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $script:WizRunspace = $rs; $script:WizPSInst = $ps

        # Drive the apply percentage from a UI-thread timer. Expand-WindowsImage
        # reports progress through DISM's native callback, which does NOT land on
        # the runspace progress stream, so we can't read a % from the cmdlet.
        # Instead, once the builder announces its "Apply target: <drive> <bytes>",
        # poll that volume's used space against the total apply size every 1.5s
        # while Applying is true. Runs on the UI thread, so it touches $wizBar /
        # $wizStatus directly (no Dispatcher marshalling needed).

        $build = {
            function WSet { param([string]$t, [string]$c = '#C0C0C0')
                $Window.Dispatcher.Invoke([Action]{ $Status.Text = $t; $Status.Foreground = $c }) }
            function WBar { param([int]$p = -1)
                $Window.Dispatcher.Invoke([Action]{
                    if ($p -lt 0) { $Bar.IsIndeterminate = $true }
                    else { $Bar.IsIndeterminate = $false; $Bar.Maximum = 100; $Bar.Value = $p }
                }) }
            function WDone { param([bool]$ok, [string]$msg)
                $Window.Dispatcher.Invoke([Action]{
                    $Bar.Visibility = 'Collapsed'
                    $Status.Text = $msg
                    $Status.Foreground = $(if ($ok) { '#3FB950' } else { '#F03A47' })
                    if (-not $ok) {
                        # Failure: keep the wizard open so the user can read the
                        # error and retry the build.
                        $OpenBtn.IsEnabled  = $true
                        $CloseBtn.IsEnabled = $true
                        $BuildBtn.Content   = 'BUILD VHDX FROM ISO'
                        $BuildBtn.IsEnabled = $true
                    }
                }) }
            function WClose {
                # Success: let the user read the message, then auto-close so they
                # return to the GUI to build their first VM. BeginInvoke (async)
                # so this runspace thread does NOT block on the UI thread while
                # the dialog's Closing handler disposes this very runspace — a
                # synchronous Invoke here would deadlock.
                Start-Sleep -Milliseconds 2200
                $Window.Dispatcher.BeginInvoke([Action]{ $Window.Close() }) | Out-Null
            }

            $script:builtPath = $null
            try {
                # Same code path as Get-Win11VHDX.ps1 -PickIso, but the ISO was
                # already chosen on the UI thread, so feed it via -IsoPath. No
                # -OutVhdx → the builder auto-detects the release and names the
                # VHDX C:\VMs\Win11-<release>.vhdx.
                #
                # *>&1 (NOT 2>&1): the builder reports every phase via
                # Write-Host, which lands on the information stream. Inside a
                # runspace 2>&1 captures only errors, so the phase lines would
                # never reach this parser and the bar would sit frozen. *>&1
                # merges all streams so the status updates actually flow.
                & $BuilderScript -IsoPath $IsoPath *>&1 | ForEach-Object {
                    $line = "$_"
                    if     ($line -match 'Using supplied ISO')                 { WSet 'Using supplied ISO…'; WBar -1 }
                    elseif ($line -match 'Mounting ISO')                       { WSet 'Mounting ISO…'; WBar -1 }
                    elseif ($line -match 'Detected Windows 11 (\S+)')          { WSet "Detected Windows 11 $($Matches[1]) - building..." }
                    elseif ($line -match 'Output VHDX name set from image: (.+)$') { $script:builtPath = $Matches[1].Trim(); WSet "Target: $script:builtPath" }
                    elseif ($line -match 'Using image index')                  { WSet 'Reading install image…' }
                    elseif ($line -match 'Creating .*GB, dynamic')             { WSet 'Creating empty VHDX…'; WBar -1 }
                    elseif ($line -match 'Applying image')                     { WSet 'Applying Windows image…'; WBar -1; $WizState.Applying = $true }
                    elseif ($line -match '^Apply progress: (\d+)')             { $pct = [int]$Matches[1]; WBar $pct; WSet "Applying Windows image… $pct%" }
                    elseif ($line -match 'DISM apply verified')                { $WizState.Applying = $false; WSet 'DISM apply verified.'; WBar -1 }
                    elseif ($line -match 'Writing UEFI')                       { WSet 'Writing UEFI boot files…' }
                    elseif ($line -match 'Boot files verified')               { WSet 'UEFI boot files verified.' }
                    elseif ($line -match 'Dismounting')                       { WSet 'Finalizing VHDX…' }
                    elseif ($line -match '^Done: (.+)$')                       { $script:builtPath = $Matches[1].Trim() }
                }
                if ($script:builtPath -and (Test-Path $script:builtPath)) {
                    WDone $true "Parent VHDX built. Build your first VM!"
                } else {
                    WDone $true 'Build your first VM!'
                }
                WClose
            } catch {
                WDone $false "Build failed: $($_.Exception.Message)"
            }
        }
        [void]$ps.AddScript($build)
        [void]$ps.BeginInvoke()
    })

    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.Add_Closing({
        if ($script:WizPSInst)   { try { $script:WizPSInst.Stop() | Out-Null; $script:WizPSInst.Dispose() } catch { } }
        if ($script:WizRunspace) { try { $script:WizRunspace.Close(); $script:WizRunspace.Dispose() } catch { } }
        $script:WizPSInst = $null; $script:WizRunspace = $null
    })

    [void]$dlg.ShowDialog()
}

# --- Workflow runspace ----------------------------------------------------
$script:Runspace = $null
$script:PSInst   = $null

function Start-Workflow {
    $vmName   = $VMNameBox.Text.Trim()
    $cpu      = Get-CheckedRadio -Values 1,2,4   -Prefix 'Cpu' -Default 2
    $ramGB    = Get-CheckedRadio -Values 4,8,16  -Prefix 'Ram' -Default 4
    $online   = [bool]$ModeOnline.IsChecked
    # Offline only: v2 collects the device identifier instead of the hash, and
    # ignores the group tag (device preparation has no per-device tag).
    $collectId = (-not $online) -and [bool]$ApV2.IsChecked
    $groupTag  = if ($collectId) { '' } else { $GroupTagBox.Text.Trim() }
    # WIN RELEASE is fixed at 25H2 — the only supported Windows 11 release.
    $release    = '25H2'
    $bootSource = "C:\VMs\Win11-$release.vhdx"

    if ([string]::IsNullOrWhiteSpace($vmName)) {
        Set-Result -Text 'VM name cannot be empty.' -Color '#F03A47'
        return
    }

    # If no cached parent VHDX exists yet, send the user through the guided
    # "Get Windows 11 Install Media" wizard (download the ISO from Microsoft's
    # official page, then build the VHDX from it). The wizard is modal and
    # self-contained; it names the VHDX C:\VMs\Win11-<release>.vhdx. When it
    # returns, re-check — if the VHDX still isn't there the user cancelled or
    # the build failed, so bail before spawning the VM-creation runspace.
    if (-not (Test-Path $bootSource -PathType Leaf)) {
        Set-Status -Text 'No 25H2 parent VHDX yet — opening the Windows 11 install-media wizard…'
        Show-Win11IsoWizard
        if (-not (Test-Path $bootSource -PathType Leaf)) {
            Set-Status -Text 'Parent VHDX not built — cancelled.'
            return
        }
    }

    Hide-CompletedIcon
    $window.Dispatcher.Invoke([Action]{ $ResultText.Visibility = 'Collapsed'; $ResultText.Text = '' })
    Set-Status -Text 'Starting…'
    $RunButton.IsEnabled    = $false
    $RunButton.Content      = 'WORKING…'
    $ActivityBar.Visibility = 'Visible'

    # Online mode: VM lands at OOBE region screen (no unattend). We inject a single
    # C:\import.bat into the VHDX. User does SHIFT+F10 in vmconnect and runs it:
    # the bat installs Get-WindowsAutopilotImportGUICommunity from PSGallery and
    # launches it. That GUI picks v1 (hash) or v2 (identifier), collects Group Tag /
    # Assigned User, handles Connect-MgGraph (browser sign-in), the upload, the
    # assignment poll, and the reboot which returns the VM to OOBE → AutoPilot
    # self-enrolls. Device never leaves OOBE state.

    $sharedVars = @{
        VMName              = $vmName
        CpuCount            = $cpu
        RamGB               = $ramGB
        Online              = $online
        CollectIdentifier   = $collectId
        GroupTag            = $groupTag
        Release             = $release
        ScriptDir           = $PSScriptRoot
        BootSource      = $bootSource            # per-release override
        BuilderScript   = $script:BuilderScript
        VMPath          = $script:VMPath
        FilesToCopy     = $script:FilesToCopy
        SearchPattern   = $script:SearchPattern
        SearchPatternV2 = $script:SearchPatternV2
        SourceFolder    = $script:SourceFolder
        DestinationPath = $script:DestinationPath
        ImportScriptName     = $script:ImportScriptName
        ImportBatInVM        = $script:ImportBatInVM
        CollectScriptInVM    = $script:CollectScriptInVM
        Window          = $window
        StatusText      = $StatusText
        ResultText      = $ResultText
        CompletedIcon   = $CompletedIcon
        SerialPanel     = $SerialPanel
        SerialText      = $SerialText
        HashPanel       = $HashPanel
        HashPanelLabel  = $HashPanelLabel
        HashPathText    = $HashPathText
        RunButton       = $RunButton
        ActivityBar     = $ActivityBar
        ModeOnline      = $ModeOnline
        ApV2            = $ApV2
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
        function Show-HashPath {
            param([string]$Path)
            if ([string]::IsNullOrWhiteSpace($Path)) { return }
            $Window.Dispatcher.Invoke([Action]{
                $HashPanelLabel.Text   = if ($CollectIdentifier) { 'DEVICE IDENTIFIER SAVED TO' } else { 'HARDWARE HASH SAVED TO' }
                $HashPathText.Text     = $Path
                $HashPanel.Visibility  = 'Visible'
            })
        }
        function Restore-Button {
            $Window.Dispatcher.Invoke([Action]{
                $RunButton.IsEnabled = $true
                if ($ModeOnline.IsChecked)  { $RunButton.Content = 'COLLECT & UPLOAD' }
                elseif ($ApV2.IsChecked)    { $RunButton.Content = 'COLLECT IDENTIFIER' }
                else                        { $RunButton.Content = 'COLLECT HWID' }
                $ActivityBar.Visibility = 'Collapsed'
                $StatusText.Text = ''
            })
        }

        # Switch the progress bar between indeterminate and determinate.
        function Set-Progress {
            param([int]$Percent = -1)
            $Window.Dispatcher.Invoke([Action]{
                if ($Percent -lt 0) {
                    $ActivityBar.IsIndeterminate = $true
                } else {
                    $ActivityBar.IsIndeterminate = $false
                    $ActivityBar.Maximum         = 100
                    $ActivityBar.Value           = $Percent
                }
            })
        }



        try {
            # ===== VHDX template =====
            # The parent VHDX is built up-front via the "Get Windows 11 Install
            # Media" wizard (Show-Win11IsoWizard) on the UI thread before this
            # runspace spawns, so by now it must exist. Guard defensively.
            if (-not (Test-Path $BootSource -PathType Leaf)) {
                Set-Result -Text "Parent VHDX not found: $BootSource. Build it first via SETUP." -Color '#F03A47'
                Restore-Button
                return
            }
            Set-Status 'VHDX template ready (cached)'

            # ===== Create VM =====
            # Free any lingering handles on the parent VHDX before creating a
            # differencing-disk child. wimserv.exe (Windows Imaging Service)
            # commonly holds the parent open after DISM-apply finishes, which
            # makes the New-VM differencing-disk creation fail with
            # 0x80070020 "The process cannot access the file because it is
            # being used by another process".
            $stuck = Get-Process wimserv, wimlib-imagex, dism -ErrorAction SilentlyContinue
            if ($stuck) {
                Set-Status 'Releasing parent VHDX (closing wimserv handles)…'
                $stuck | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }

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

            # Force the VM to boot from the hard disk first (not network).
            # New-HyperVVM doesn't always set this, and a Gen 2 VM with
            # Network as the first boot device will hang on "Start PXE
            # over IPv4" until the PXE attempt times out.
            try {
                $vmHd = Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1
                if ($vmHd) {
                    Set-VMFirmware -VMName $VMName -FirstBootDevice $vmHd -ErrorAction Stop
                }
            } catch {
                Set-Status "Warning: couldn't set boot order ($($_.Exception.Message)) — VM may try PXE first"
            }

            # ===== Inject mode-specific payload into the child VHDX =====
            # Online: single C:\import.bat (VM stays at OOBE; user runs it via Shift+F10)
            # Offline: collection bat + SetupComplete.cmd (VM auto-collects and shuts down)
            $childVhd = (Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1).Path

            if ($Online) {
                Set-Status 'Injecting AutoPilot import launcher into VM…'
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
            # Disable Windows's global automount before Mount-VHD. The child
            # VHDX inherits the parent's multi-partition layout, and even
            # with -NoDriveLetter, Windows's automount service auto-assigns
            # letters to partitions it can read — including MSR partitions
            # with no filesystem, which trigger the "format disk in drive X:"
            # popup. mountvol /N suppresses automount globally; we restore
            # with /E in the finally block.
            & mountvol /N | Out-Null
            Mount-VHD -Path $childVhd -NoDriveLetter -ErrorAction Stop
            $partition = $null
            try {
                $vhdFile = Split-Path $childVhd -Leaf
                $disk = Get-Disk | Where-Object { $_.Location -like "*$vhdFile*" }
                $partition = $disk | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
                Add-PartitionAccessPath -InputObject $partition -AccessPath $mountFolder -ErrorAction Stop
                Start-Sleep -Seconds 1

                if ($Online) {
                    # Drop ONE entry point at C:\import.bat on the VHDX. The user runs it
                    # from the OOBE Shift+F10 prompt; it primes NuGet + trusts PSGallery so
                    # Install-Script never prompts, installs the single-file
                    # Get-WindowsAutopilotImportGUICommunity script, and launches it. That
                    # GUI covers both AutoPilot v1 (hardware hash + Group Tag / Assigned
                    # User + profile-assignment poll + reboot into enrollment) and v2
                    # (Device preparation identifier), so nothing else needs injecting.
                    #
                    # NOTE: `|` is literal inside cmd "..." — do NOT escape with ^|, that
                    # gets passed to PowerShell verbatim and fails to parse.
                    $batContent = @"
@echo off
title VM-Pilot AutoPilot Import
echo.
echo   VM-Pilot - AutoPilot Import
echo   Installing $ImportScriptName from the PowerShell Gallery...
echo   First run only - the VM needs internet access for this step.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:`$false | Out-Null; Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue; if (-not (Get-InstalledScript -Name '$ImportScriptName' -ErrorAction SilentlyContinue)) { Install-Script -Name '$ImportScriptName' -Force -Scope AllUsers -Confirm:`$false }; `$s = Get-InstalledScript -Name '$ImportScriptName' -ErrorAction SilentlyContinue; if (-not `$s) { Write-Host '  Could not install $ImportScriptName - check the VM has internet access.' -ForegroundColor Red; Read-Host '  Press Enter to close'; exit 1 }; & (Join-Path `$s.InstalledLocation '$ImportScriptName.ps1')"
"@
                    [IO.File]::WriteAllText((Join-Path $mountFolder $ImportBatInVM), $batContent, [Text.UTF8Encoding]::new($false))
                } else {
                    # Offline: copy the collection script + generate SetupComplete.cmd that
                    # invokes it with -GroupTag (omitted if blank). Collection script writes
                    # the CSV with a 'Group Tag' column only when the value is non-empty.
                    $collectSrc = Join-Path $ScriptDir $CollectScriptInVM
                    Copy-Item -Path $collectSrc -Destination (Join-Path $mountFolder $CollectScriptInVM) -Force

                    # v2 writes a headerless Manufacturer,Model,Serial line instead of the
                    # hash CSV; -GroupTag doesn't apply there and is already blanked out.
                    $idArg  = if ($CollectIdentifier) { ' -Identifier' } else { '' }
                    $tagArg = if (-not [string]::IsNullOrWhiteSpace($GroupTag)) { " -GroupTag `"$GroupTag`"" } else { '' }
                    $setupContent = @"
@echo off
if not exist "C:\HWID" mkdir "C:\HWID"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\$CollectScriptInVM$idArg$tagArg > C:\HWID\collection.log 2>&1
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
                & mountvol /E | Out-Null  # restore Windows automount
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

            $collectLabel = if ($CollectIdentifier) { 'device identifier' } else { 'hardware hash' }
            Set-Status "Collecting $collectLabel inside VM…"
            $maxWait = 900; $elapsed = 0; $shutdown = $false
            while ($elapsed -lt $maxWait) {
                $state = (Get-VM -Name $VMName -ErrorAction SilentlyContinue).State
                if ($state -eq 'Off') { $shutdown = $true; break }
                Start-Sleep -Seconds 5
                $elapsed += 5
                if ($elapsed % 30 -eq 0) {
                    Set-Status "Collecting $collectLabel inside VM… (${elapsed}s)"
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
            # Same automount suppression as the inject step — see comment there
            & mountvol /N | Out-Null
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
                $pattern = if ($CollectIdentifier) { $SearchPatternV2 } else { $SearchPattern }
                $files = Get-ChildItem -Path $sourcePath -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending

                if ($files.Count -gt 0) {
                    if (-not (Test-Path $DestinationPath)) { New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null }
                    $destCsv = Join-Path $DestinationPath $files[0].Name
                    Copy-Item -Path $files[0].FullName -Destination $destCsv -Force
                    $collected = $true
                    # Read serial from the CSV so we can surface it in the GUI + clipboard.
                    # The v2 file is headerless (Intune's import format), so supply the
                    # column names rather than letting Import-Csv eat the only data row.
                    try {
                        if ($CollectIdentifier) {
                            $row = Import-Csv -Path $destCsv -Header 'Manufacturer','Model','Serial' | Select-Object -First 1
                            if ($row) { $script:CollectedSerial = "$($row.Serial)" }
                        } else {
                            $row = Import-Csv -Path $destCsv | Select-Object -First 1
                            if ($row) { $script:CollectedSerial = "$($row.'Device Serial Number')" }
                        }
                    } catch { }
                }
            } finally {
                if ($partition) { Remove-PartitionAccessPath -InputObject $partition -AccessPath $mountFolder -ErrorAction SilentlyContinue }
                Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
                Remove-Item $mountFolder -Force -Recurse -ErrorAction SilentlyContinue
                & mountvol /E | Out-Null  # restore Windows automount
            }

            Start-VM -Name $VMName -ErrorAction SilentlyContinue

            if ($collected) {
                if ($script:CollectedSerial) { Show-Serial -Value $script:CollectedSerial }
                Show-HashPath -Path $destCsv
                Set-Done
            } else {
                $what = if ($CollectIdentifier) { 'identifier' } else { 'hash' }
                Set-Result -Text "No $what CSV found on the VM. Mount its VHDX and check C:\HWID\collection.log." -Color '#F03A47'
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
    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VM Cleanup"
        Width="520" Height="560"
        WindowStartupLocation="CenterOwner"
        Background="#161616" Foreground="#FFFFFF"
        FontFamily="Segoe UI Variable, Segoe UI"
        ResizeMode="CanResize"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    $script:ThemeToken
  </Window.Resources>
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Text="VM Cleanup" Style="{StaticResource DialogTitle}" FontSize="22"/>
    <TextBlock Grid.Row="1" Style="{StaticResource PageSubtitle}" FontSize="12" Margin="0,4,0,16"
               Text="Select VMs to remove. Each VM is stopped, deleted from Hyper-V, and its C:\VMs\&lt;name&gt; folder is wiped."/>

    <ListBox Grid.Row="2" x:Name="VmListBox" SelectionMode="Single"/>

    <StackPanel Grid.Row="3" Orientation="Vertical" Margin="0,14,0,0">
      <CheckBox x:Name="ChkCloud" Margin="2,0,0,2"
                Content="Also remove records from Intune / Autopilot / Entra ID (by serial)"/>
      <TextBlock x:Name="ChkCloudHint" Style="{StaticResource HintText}" Margin="30,0,0,12"
                 Text="Records-only offboard keyed on each VM's BIOS serial. Opens a PowerShell window that signs in to Microsoft Graph (Intune admin required)."/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnRemoveSelected" Content="REMOVE SELECTED" Width="170" Margin="0,0,8,0"
                Style="{StaticResource PrimaryButtonSmall}"/>
        <Button x:Name="BtnRemoveAll" Content="REMOVE ALL" Width="120" Margin="0,0,8,0"
                Style="{StaticResource DangerButtonSolid}"/>
        <Button x:Name="BtnClose" Content="CLOSE" Width="100"
                Style="{StaticResource SecondaryButton}"/>
      </StackPanel>
    </StackPanel>
  </Grid>
</Window>
"@
    $dlg = New-ThemedWindow -WindowXaml $dlgXaml
    $dlg.Owner = $window

    $VmListBox        = $dlg.FindName('VmListBox')
    $BtnRemoveSel     = $dlg.FindName('BtnRemoveSelected')
    $BtnRemoveAll     = $dlg.FindName('BtnRemoveAll')
    $BtnClose         = $dlg.FindName('BtnClose')
    $ChkCloud         = $dlg.FindName('ChkCloud')
    $ChkCloudHint     = $dlg.FindName('ChkCloudHint')

    # Cloud (tenant record) cleanup runs under the AutopilotCleanup module,
    # whose manifest requires PowerShell 7.0. Resolve a pwsh host: use the
    # current process if we're already Core, otherwise look for pwsh.exe on
    # PATH. If neither exists, the option is disabled with a why note.
    $pwshExe = if ($PSVersionTable.PSEdition -eq 'Core') {
        (Get-Process -Id $PID).Path
    } else {
        (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    }
    if (-not $pwshExe) {
        $ChkCloud.IsChecked = $false
        $ChkCloud.IsEnabled = $false
        $ChkCloudHint.Text  = 'Tenant cleanup needs PowerShell 7 (pwsh), which was not found. Install it from https://aka.ms/powershell to enable this.'
    }

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
            # No Foreground here on purpose: a local value outranks the theme's
            # hover/checked trigger setters, which would freeze the row colour.
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

    # Read a VM's firmware serial from Hyper-V settings. This is the same value
    # Win32_BIOS returns inside the VM, so it's the serial Autopilot/Intune/Entra
    # registered under - the join key for tenant cleanup. Must run BEFORE the VM
    # is deleted (a removed VM can't be queried).
    function Get-VmSerial {
        param([string]$Name)
        try {
            $ms = Get-CimInstance -Namespace 'root\virtualization\v2' `
                                  -ClassName 'Msvm_VirtualSystemSettingData' `
                                  -Filter "ElementName='$Name' AND VirtualSystemType='Microsoft:Hyper-V:System:Realized'" `
                                  -ErrorAction SilentlyContinue
            return "$($ms.BIOSSerialNumber)".Trim()
        } catch { return '' }
    }

    # Launch the pwsh-only records-only offboard for the given serials.
    function Start-CloudCleanup {
        param([string[]]$Serials)
        $runner = Join-Path $PSScriptRoot 'Invoke-VMPilotCloudCleanup.ps1'
        if (-not (Test-Path $runner)) {
            [void](Show-VMPilotDialog -Title 'Cloud cleanup helper not found' `
                -Message 'Invoke-VMPilotCloudCleanup.ps1 is missing from the VM-Pilot folder, so tenant records were not touched. Reinstall the module to restore it.' `
                -Detail $runner -Width 560 -Owner $dlg)
            return
        }
        # Each serial as its own double-quoted token, comma-joined into a
        # PowerShell array literal for the -SerialNumber parameter. Strip any
        # embedded quotes defensively (Hyper-V serials never contain them).
        $serialArg = ($Serials | ForEach-Object { '"{0}"' -f ($_ -replace '"','') }) -join ','
        $argLine   = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SerialNumber {1}' -f $runner, $serialArg
        Start-Process -FilePath $pwshExe -ArgumentList $argLine
    }

    # Shared path for both REMOVE buttons: capture serials first (if cloud
    # cleanup is on), remove locally, refresh, then offboard tenant records.
    function Invoke-Removal {
        param([string[]]$Names)
        $removeCloud = [bool]$ChkCloud.IsChecked
        $serials = @()
        if ($removeCloud) {
            foreach ($n in $Names) { $s = Get-VmSerial -Name $n; if ($s) { $serials += $s } }
        }
        Remove-VMs -Names $Names
        Update-VmList
        if ($removeCloud) {
            if ($serials.Count -eq 0) {
                [void](Show-VMPilotDialog -Title 'No serials to clean up' `
                    -Message 'The VM(s) were removed locally, but no BIOS serial could be read for any of them, so no tenant records were touched.' `
                    -Owner $dlg)
                return
            }
            Start-CloudCleanup -Serials $serials
        }
    }

    $BtnRemoveSel.Add_Click({
        $names = Get-CheckedNames
        if ($names.Count -eq 0) {
            [void](Show-VMPilotDialog -Title 'Nothing selected' `
                -Message 'No VMs are checked. Tick the ones you want removed, or use REMOVE ALL.' `
                -Owner $dlg)
            return
        }
        $msg = "Permanently remove $($names.Count) VM(s)? Each is stopped, deleted from Hyper-V, and its C:\VMs folder is wiped."
        if ($ChkCloud.IsChecked) {
            $msg += "`r`n`r`nAlso DELETE their Intune / Autopilot / Entra ID records (keyed on BIOS serial). This offboards the device from your tenant."
        }
        $ans = Show-VMPilotDialog -Title 'Confirm Cleanup' -Message $msg -Detail ($names -join "`r`n") `
            -PrimaryText 'REMOVE' -SecondaryText 'CANCEL' -Danger -Width 520 -Owner $dlg
        if ($ans -ne 'Primary') { return }
        Invoke-Removal -Names $names
    })

    $BtnRemoveAll.Add_Click({
        $names = @()
        foreach ($item in $VmListBox.Items) {
            if ($item -is [System.Windows.Controls.CheckBox]) { $names += "$($item.Tag)" }
        }
        if ($names.Count -eq 0) { return }
        $msg = "Permanently remove ALL $($names.Count) VM(s)? This includes VMs you did not create with VM-Pilot."
        if ($ChkCloud.IsChecked) {
            $msg += "`r`n`r`nAlso DELETE the Intune / Autopilot / Entra ID records for EVERY listed VM's serial. Records for non-VM-Pilot VMs will be removed too."
        }
        $ans = Show-VMPilotDialog -Title 'Confirm Remove ALL' -Message $msg -Detail ($names -join "`r`n") `
            -PrimaryText 'REMOVE ALL' -SecondaryText 'CANCEL' -Danger -Width 520 -Owner $dlg
        if ($ans -ne 'Primary') { return }
        Invoke-Removal -Names $names
    })

    $BtnClose.Add_Click({ $dlg.Close() })

    Update-VmList
    [void]$dlg.ShowDialog()
    Set-Status -Text ''
}

$CleanupButton.Add_Click({ Show-CleanupDialog })

# Guided ISO download + parent-VHDX build
$IsoWizardButton.Add_Click({ Show-Win11IsoWizard })

# "Open folder" under the saved hardware-hash path: select the .csv in Explorer.
# The path lives in the shared HashPathText element (set from the workflow
# runspace), so read it from there rather than a cross-runspace variable.
$HashOpenLink.Add_Click({
    $p = $HashPathText.Text
    if ($p -and (Test-Path $p)) { Start-Process explorer.exe "/select,`"$p`"" }
    elseif ($p) { Start-Process explorer.exe (Split-Path $p) }
})

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
