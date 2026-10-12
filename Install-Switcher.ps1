param(
    [string]$ConfigPath = (Join-Path $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }) 'config.toml'),
    [switch]$DesktopShortcut
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Engine.ps1')
foreach ($mode in @('glm','deepseek')) {
    $path = Join-Path $PSScriptRoot ('catalogs\' + $mode + '.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Missing model catalog: ' + $mode + '. Keep the entire application folder together.') }
    $null = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
}
Initialize-Switcher -ConfigPath $ConfigPath -AppDirectory $PSScriptRoot | Out-Null
if ($DesktopShortcut) {
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex 配置切换.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $PSScriptRoot 'CodexConfigSwitcher.exe'
    $shortcut.Arguments = ''
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = '切换 Codex 原生、DeepSeek 和 GLM 配置'
    $shortcut.IconLocation = (Join-Path $env:WINDIR 'System32\shell32.dll') + ',21'
    $shortcut.Save()
    Write-Output 'Desktop shortcut created.'
}
