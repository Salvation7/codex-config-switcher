param([switch]$SmokeTest)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Engine.ps1')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SwitcherDpi {
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr window);
    [DllImport("user32.dll")] static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
    public static void EnableFallback() {
        try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { }
    }
    public static bool IsPerMonitorV2(IntPtr window) {
        try { return AreDpiAwarenessContextsEqual(GetWindowDpiAwarenessContext(window), new IntPtr(-4)); }
        catch (EntryPointNotFoundException) { return false; }
    }
}
'@
# The EXE manifest is the primary DPI declaration. This also covers direct script use.
[SwitcherDpi]::EnableFallback()
$script:SwitcherAppDirectory = $PSScriptRoot
$script:SwitcherConfigPath = Join-Path $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }) 'config.toml'
$script:ModeNames = @{ native = '原生'; glm = 'GLM'; deepseek = 'DeepSeek'; other = '其他' }
$script:ModeButtons = @{}
$script:ModeBadges = @{}
$script:MainForm = $null
$script:Resources = @'
<Window.Resources>
  <Style x:Key="ActionButton" TargetType="Button">
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Foreground" Value="#253440"/>
    <Setter Property="Background" Value="White"/>
    <Setter Property="BorderBrush" Value="#DCE3E9"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="14,8"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Chrome" CornerRadius="9" Background="{TemplateBinding Background}"
                  BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
            <ContentPresenter Margin="{TemplateBinding Padding}"
                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                VerticalAlignment="{TemplateBinding VerticalContentAlignment}" RecognizesAccessKey="True"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="#71A18E"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="#25835E"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Chrome" Property="Opacity" Value="0.76"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Chrome" Property="Opacity" Value="0.5"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="ModeButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Height" Value="112"/>
    <Setter Property="Padding" Value="18,14"/>
  </Style>
  <Style x:Key="LinkButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Foreground" Value="#4E6575"/>
    <Setter Property="Padding" Value="0,5"/>
    <Setter Property="FontSize" Value="12"/>
    <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#176846"/></Trigger></Style.Triggers>
  </Style>
  <Style TargetType="TextBox">
    <Setter Property="FontSize" Value="13"/><Setter Property="Padding" Value="10,8"/>
    <Setter Property="BorderBrush" Value="#D7DFE5"/><Setter Property="BorderThickness" Value="1"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
  </Style>
  <Style TargetType="ComboBox">
    <Setter Property="FontSize" Value="13"/><Setter Property="MinHeight" Value="36"/>
    <Setter Property="Padding" Value="8,4"/><Setter Property="VerticalContentAlignment" Value="Center"/>
  </Style>
</Window.Resources>
'@

function New-SwitcherWindow {
    param([string]$Markup)
    $reader = New-Object Xml.XmlNodeReader ([xml]$Markup.Replace('<!-- RESOURCES -->', $script:Resources))
    try { return [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
}

function Get-SwitcherBrush {
    param([string]$Color)
    return ((New-Object Windows.Media.BrushConverter).ConvertFromString($Color))
}

function Show-SwitcherError {
    param($ErrorRecord)
    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match 'API_KEY_REQUIRED:') { $message = '请先设置该厂商的 API Key。' }
    elseif ($message -match 'first-time setup') { $message = '首次设置需要填写 API Key。' }
    elseif ($message -match 'during switching') { $message = 'Codex 刚刚更新了配置，请重新点击切换。' }
    elseif ($message -match 'does not support') { $message = '该模型不支持所选思考强度，请重新选择。' }
    elseif ($message -match 'Codex rejected') { $message = 'Codex 未通过配置校验，原文件未修改。请检查重复表、TOML 语法或旧版配置项。' }
    elseif ($message -match 'different CODEX_HOME') { $message = '程序保存的原生设置属于另一个配置目录，本次没有写入。' }
    $message = $message -replace '(?i)sk-[A-Za-z0-9_.-]+', '[已隐藏]'
    [Windows.MessageBox]::Show($script:MainForm, $message, '未能完成操作', 'OK', 'Error') | Out-Null
}

function Update-SwitcherView {
    $status = Get-SwitcherStatus -ConfigPath $script:SwitcherConfigPath
    $script:MainForm.FindName('CurrentMode').Text = '已配置 · ' + $script:ModeNames[$status.Mode]
    $script:MainForm.FindName('CurrentModel').Text = $status.Model
    foreach ($mode in @('native', 'deepseek', 'glm')) {
        $button = $script:ModeButtons[$mode]
        $active = $status.Mode -eq $mode
        $button.Background = Get-SwitcherBrush $(if ($active) { '#EFF8F3' } else { '#FFFFFF' })
        $button.BorderBrush = Get-SwitcherBrush $(if ($active) { '#72A88F' } else { '#DCE3E9' })
        $button.Foreground = Get-SwitcherBrush $(if ($active) { '#175D42' } else { '#22313C' })
        $script:ModeBadges[$mode].Visibility = if ($active) { 'Visible' } else { 'Hidden' }
    }
}

function Update-ProviderEfforts {
    param($Dialog)
    $controls = $Dialog.Tag.Controls
    $old = [string]$controls.Effort.SelectedItem
    $controls.Effort.Items.Clear()
    $selected = @($Dialog.Tag.Catalog.models | Where-Object { $_.slug -eq [string]$controls.Model.SelectedItem })
    if ($selected.Count -eq 1) {
        foreach ($level in $selected[0].supported_reasoning_levels) { [void]$controls.Effort.Items.Add($level.effort) }
        $controls.Effort.SelectedItem = $old
        if ($controls.Effort.SelectedIndex -lt 0) { $controls.Effort.SelectedItem = $selected[0].default_reasoning_level }
    }
}

function Invoke-ProviderSave {
    param($Dialog)
    try {
        $mode = $Dialog.Tag.Mode
        $controls = $Dialog.Tag.Controls
        Save-ProviderConfiguration -Mode $mode -ApiKey $controls.Key.Password -Model ([string]$controls.Model.SelectedItem) -Effort ([string]$controls.Effort.SelectedItem) -ConfigPath $script:SwitcherConfigPath -AppDirectory $script:SwitcherAppDirectory | Out-Null
        if ((Get-SwitcherStatus $script:SwitcherConfigPath).Mode -eq $mode) {
            Switch-CodexProfile -Mode $mode -ConfigPath $script:SwitcherConfigPath -AppDirectory $script:SwitcherAppDirectory | Out-Null
            Update-SwitcherView
        }
        $controls.Key.Clear()
        $Dialog.DialogResult = $true
    } catch { Show-SwitcherError $_ }
}

function Show-ProviderSetup {
    param([ValidateSet('glm', 'deepseek')][string]$Mode, [switch]$PreviewOnly)
    $state = Initialize-Switcher -ConfigPath $script:SwitcherConfigPath -AppDirectory $script:SwitcherAppDirectory
    $profile = if ($Mode -eq 'glm') { $state.Glm } else { $state.Deepseek }
    $dialog = New-SwitcherWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="480" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="13" Background="#F7F9FB" Foreground="#253440"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType" RenderOptions.ClearTypeHint="Enabled">
  <!-- RESOURCES -->
  <Border x:Name="DialogContent" Background="#F7F9FB" Padding="24">
  <StackPanel>
    <TextBlock x:Name="DialogHeading" FontSize="21" FontWeight="SemiBold"/>
    <TextBlock Text="直连官方接口，保留原生登录。" Foreground="#637481" Margin="0,5,0,22"/>
    <TextBlock Text="官方 API 地址" Margin="0,0,0,7"/>
    <TextBox x:Name="ProviderUrl" IsReadOnly="True" Background="#EEF2F5" Foreground="#5B6E7B"/>
    <Grid Margin="0,18,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="130"/></Grid.ColumnDefinitions>
      <StackPanel><TextBlock Text="模型" Margin="0,0,0,7"/><ComboBox x:Name="ModelBox"/></StackPanel>
      <StackPanel Grid.Column="2"><TextBlock Text="思考强度" Margin="0,0,0,7"/><ComboBox x:Name="EffortBox"/></StackPanel>
    </Grid>
    <TextBlock Text="API Key" Margin="0,18,0,7"/>
    <PasswordBox x:Name="KeyBox" Padding="10,8" FontSize="13" BorderBrush="#D7DFE5" BorderThickness="1"/>
    <TextBlock Text="已有密钥时留空即可保留，密钥仅写入本机配置。" Foreground="#637481" FontSize="12" Margin="0,9,0,0" TextWrapping="Wrap"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0">
      <Button x:Name="CancelButton" Style="{StaticResource ActionButton}" Content="取消" Width="82" IsCancel="True"/>
      <Button x:Name="SaveButton" Style="{StaticResource ActionButton}" Content="保存设置" MinWidth="102" Margin="10,0,0,0"
              Background="#1D6B4B" Foreground="White" BorderBrush="#1D6B4B" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
  </Border>
</Window>
'@
    $dialog.Owner = $script:MainForm
    $dialog.Title = $script:ModeNames[$Mode] + ' 设置'
    $dialog.FindName('DialogHeading').Text = $script:ModeNames[$Mode] + ' 设置'
    $dialog.FindName('ProviderUrl').Text = if ($Mode -eq 'glm') { 'https://open.bigmodel.cn/api/v1' } else { 'https://api.deepseek.com/' }
    $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:SwitcherAppDirectory ('catalogs\' + $Mode + '.json')) | ConvertFrom-Json
    $controls = @{ Model = $dialog.FindName('ModelBox'); Effort = $dialog.FindName('EffortBox'); Key = $dialog.FindName('KeyBox') }
    $dialog.Tag = [pscustomobject]@{ Mode = $Mode; Catalog = $catalog; Controls = $controls }
    foreach ($entry in $catalog.models) { if (@($entry.supported_reasoning_levels).Count -gt 0) { [void]$controls.Model.Items.Add($entry.slug) } }
    $controls.Model.Tag = $dialog
    $controls.Model.Add_SelectionChanged({ param($sender, $eventArgs) Update-ProviderEfforts -Dialog $sender.Tag })
    $controls.Model.SelectedItem = $profile.Model
    Update-ProviderEfforts -Dialog $dialog
    $controls.Effort.SelectedItem = $profile.Effort
    $dialog.FindName('SaveButton').Add_Click({ param($sender, $eventArgs) Invoke-ProviderSave -Dialog ([Windows.Window]::GetWindow($sender)) })
    $dialog.FindName('CancelButton').Add_Click({ param($sender, $eventArgs) ([Windows.Window]::GetWindow($sender)).DialogResult = $false })
    if ($PreviewOnly) { return $dialog }
    try { return ($dialog.ShowDialog() -eq $true) } finally { $controls.Key.Clear(); $dialog.Close() }
}

function Invoke-ProfileButton {
    param([string]$Mode)
    try {
        if ($Mode -ne 'native') {
            $provider = if ($Mode -eq 'glm') { 'ZAI' } else { 'DeepSeek' }
            if (-not (Test-ProviderConfigured -Text ([IO.File]::ReadAllText($script:SwitcherConfigPath)) -ProviderId $provider)) {
                if (-not (Show-ProviderSetup -Mode $Mode)) { return }
            }
        }
        Switch-CodexProfile -Mode $Mode -ConfigPath $script:SwitcherConfigPath -AppDirectory $script:SwitcherAppDirectory | Out-Null
        Update-SwitcherView
        $script:MainForm.FindName('NoticeText').Text = '已保存为 ' + $script:ModeNames[$Mode] + '，请完全退出并重新打开 Codex。'
        $script:MainForm.FindName('NoticeText').Foreground = Get-SwitcherBrush '#176846'
    } catch { Show-SwitcherError $_ }
}

function Show-ConfigurationCheck {
    try {
        $status = Get-SwitcherStatus -ConfigPath $script:SwitcherConfigPath
        $text = [IO.File]::ReadAllText($script:SwitcherConfigPath)
        Test-CodexConfiguration -Text $text
        $map = @(Get-TomlLineMap -Text $text)
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $lines.Add('Codex 配置解析：通过（未发送 API 请求）')
        $lines.Add('当前文件配置：' + $script:ModeNames[$status.Mode] + ' / ' + $status.Model)
        $lines.Add('强制 API 登录：' + $(if (@($map | Where-Object { $_.Section -eq '' -and $_.Key -ceq 'forced_login_method' -and (ConvertFrom-TomlScalar $_.Value) -eq 'api' }).Count) { '存在，请确认这是你的原生设置' } else { '未强制' }))
        foreach ($plugin in @('computer-use', 'chrome', 'browser', 'unified-computer-use')) {
            $enabled = @($map | Where-Object { $_.Section -match ('^plugins[.]"?' + [regex]::Escape($plugin) + '@') -and $_.Key -ceq 'enabled' -and $_.Value.Trim() -match '^true\b' }).Count -gt 0
            $lines.Add($plugin + ' 插件配置：' + $(if ($enabled) { '已启用' } else { '未找到启用项' }))
        }
        $lines.Add('')
        $lines.Add('插件启用不代表本次聊天已获得对应工具。js_repl 是已退役开关，程序不会强制开启。')
        $lines.Add('切换后请完全退出并重开 Codex；旧聊天的厂商绑定不会被迁移。')
        [Windows.MessageBox]::Show($script:MainForm, ($lines -join "`r`n"), '配置检查', 'OK', 'Information') | Out-Null
    } catch { Show-SwitcherError $_ }
}

function Save-UiPreview {
    param($Element, [double]$Scale, [string]$Path)
    $Element.UpdateLayout()
    $width = [int][Math]::Ceiling($Element.ActualWidth * $Scale)
    $height = [int][Math]::Ceiling($Element.ActualHeight * $Scale)
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($width, $height, (96 * $Scale), (96 * $Scale), [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Element)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

Initialize-Switcher -ConfigPath $script:SwitcherConfigPath -AppDirectory $script:SwitcherAppDirectory | Out-Null
$script:MainForm = New-SwitcherWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex 配置切换" Width="700" SizeToContent="Height" ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="13" Foreground="#22313C" Background="#F6F8FA"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType" RenderOptions.ClearTypeHint="Enabled">
  <!-- RESOURCES -->
  <Border x:Name="PreviewRoot" Background="#F6F8FA" Padding="26,24">
    <StackPanel>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="180"/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text="切换模型配置" FontSize="24" FontWeight="SemiBold"/>
          <TextBlock Text="选择配置，保存后重启 Codex 生效。" Foreground="#637481" FontSize="12" Margin="0,6,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border Background="#E9F3EE" CornerRadius="12" Padding="10,4" HorizontalAlignment="Right">
            <TextBlock x:Name="CurrentMode" FontSize="11" Foreground="#216A4C"/>
          </Border>
          <TextBlock x:Name="CurrentModel" FontSize="12" Foreground="#637481" HorizontalAlignment="Right" Margin="0,7,0,0"
                     MaxWidth="178" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </Grid>
      <Grid Margin="0,24,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Button x:Name="NativeButton" Tag="native" Style="{StaticResource ModeButton}" AutomationProperties.Name="切换到原生配置">
          <StackPanel>
            <TextBlock Text="原生" FontSize="20" FontWeight="SemiBold"/>
            <TextBlock Text="OpenAI · ChatGPT 账号" Foreground="#637481" FontSize="11" Margin="0,4,0,0"/>
            <TextBlock x:Name="NativeBadge" Text="当前配置" Foreground="#267552" FontSize="10" Margin="0,9,0,0"/>
          </StackPanel>
        </Button>
        <Button x:Name="DeepseekButton" Tag="deepseek" Grid.Column="2" Style="{StaticResource ModeButton}" AutomationProperties.Name="切换到 DeepSeek 配置">
          <StackPanel>
            <TextBlock Text="DeepSeek" FontSize="20" FontWeight="SemiBold"/>
            <TextBlock Text="DeepSeek 官方 API" Foreground="#637481" FontSize="11" Margin="0,4,0,0"/>
            <TextBlock x:Name="DeepseekBadge" Text="当前配置" Foreground="#267552" FontSize="10" Margin="0,9,0,0"/>
          </StackPanel>
        </Button>
        <Button x:Name="GlmButton" Tag="glm" Grid.Column="4" Style="{StaticResource ModeButton}" AutomationProperties.Name="切换到 GLM 配置">
          <StackPanel>
            <TextBlock Text="GLM" FontSize="20" FontWeight="SemiBold"/>
            <TextBlock Text="智谱官方 API" Foreground="#637481" FontSize="11" Margin="0,4,0,0"/>
            <TextBlock x:Name="GlmBadge" Text="当前配置" Foreground="#267552" FontSize="10" Margin="0,9,0,0"/>
          </StackPanel>
        </Button>
      </Grid>
      <TextBlock x:Name="NoticeText" Text="切换前自动备份，插件和 MCP 设置继续保留。" Foreground="#637481" FontSize="12" Margin="0,18,0,0" TextWrapping="Wrap"/>
      <Border BorderBrush="#E5EAEE" BorderThickness="0,1,0,0" Margin="0,20,0,0" Padding="0,12,0,0">
        <Grid>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="DeepseekSettings" Content="DeepSeek 设置" Style="{StaticResource LinkButton}"/>
            <Button x:Name="GlmSettings" Content="GLM 设置" Style="{StaticResource LinkButton}" Margin="22,0,0,0"/>
            <Button x:Name="CheckSettings" Content="检查配置" Style="{StaticResource LinkButton}" Margin="22,0,0,0"/>
          </StackPanel>
          <Button x:Name="BackupSettings" Content="配置备份" Style="{StaticResource LinkButton}" HorizontalAlignment="Right"/>
        </Grid>
      </Border>
    </StackPanel>
  </Border>
</Window>
'@
foreach ($pair in @(@('native','Native'), @('deepseek','Deepseek'), @('glm','Glm'))) {
    $script:ModeButtons[$pair[0]] = $script:MainForm.FindName($pair[1] + 'Button')
    $script:ModeBadges[$pair[0]] = $script:MainForm.FindName($pair[1] + 'Badge')
    $script:ModeButtons[$pair[0]].Add_Click({ param($sender, $eventArgs) Invoke-ProfileButton -Mode ([string]$sender.Tag) })
}
$script:MainForm.FindName('DeepseekSettings').Add_Click({ try { Show-ProviderSetup -Mode deepseek | Out-Null } catch { Show-SwitcherError $_ } })
$script:MainForm.FindName('GlmSettings').Add_Click({ try { Show-ProviderSetup -Mode glm | Out-Null } catch { Show-SwitcherError $_ } })
$script:MainForm.FindName('CheckSettings').Add_Click({ Show-ConfigurationCheck })
$script:MainForm.FindName('BackupSettings').Add_Click({
    $path = Join-Path ([IO.Path]::GetDirectoryName($script:SwitcherConfigPath)) 'config-switcher-backups'
    if (Test-Path -LiteralPath $path) { Start-Process explorer.exe -ArgumentList ('"' + $path + '"') }
})
Update-SwitcherView
if ($SmokeTest) {
    $script:MainForm.Opacity = 0
    $script:MainForm.ShowInTaskbar = $false
    $script:MainForm.ShowActivated = $false
    $script:MainForm.Show()
    $script:MainForm.UpdateLayout()
    $root = $script:MainForm.FindName('PreviewRoot')
    $records = @()
    foreach ($scale in @(1.0, 1.25, 1.5, 2.0)) {
        $name = 'preview-' + [int]($scale * 100) + '.png'
        Save-UiPreview -Element $root -Scale $scale -Path (Join-Path $PSScriptRoot $name)
        $records += [pscustomobject]@{ Scale = $scale; PixelWidth = [int][Math]::Ceiling($root.ActualWidth * $scale); PixelHeight = [int][Math]::Ceiling($root.ActualHeight * $scale) }
    }
    [IO.File]::Copy((Join-Path $PSScriptRoot 'preview-100.png'), (Join-Path $PSScriptRoot 'preview.png'), $true)
    foreach ($mode in @('glm','deepseek')) {
        $dialog = Show-ProviderSetup -Mode $mode -PreviewOnly
        $dialog.Opacity = 0; $dialog.ShowInTaskbar = $false; $dialog.ShowActivated = $false
        $dialog.Show(); $dialog.UpdateLayout()
        Save-UiPreview -Element $dialog.FindName('DialogContent') -Scale 2 -Path (Join-Path $PSScriptRoot ('preview-settings-' + $mode + '.png'))
        if ($dialog.Tag.Controls.Model.SelectedIndex -lt 0 -or $dialog.Tag.Controls.Effort.SelectedIndex -lt 0) { throw 'The settings dialog did not initialize its model and effort.' }
        # Exercise the selection callback without saving any configuration.
        if ($dialog.Tag.Controls.Model.Items.Count -gt 1) { $dialog.Tag.Controls.Model.SelectedIndex = 0; $dialog.Tag.Controls.Model.SelectedIndex = 1 }
        if ($dialog.Tag.Controls.Effort.SelectedIndex -lt 0) { throw 'The settings dialog selection callback failed.' }
        $dialog.Close()
    }
    $handle = (New-Object Windows.Interop.WindowInteropHelper($script:MainForm)).Handle
    $report = [pscustomobject]@{ Renderer = 'WPF'; PerMonitorV2 = [SwitcherDpi]::IsPerMonitorV2($handle); WindowDpi = [SwitcherDpi]::GetDpiForWindow($handle); Buttons = $script:ModeButtons.Count; Previews = $records; SettingsDialogs = 'glm,deepseek'; ConfigWritten = $false }
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'ui-validation.json'), ($report | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Write-Output ($report | ConvertTo-Json -Depth 5 -Compress)
    $script:MainForm.Close()
} else { [void]$script:MainForm.ShowDialog() }
