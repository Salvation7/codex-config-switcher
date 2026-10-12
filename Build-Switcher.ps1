param()
$ErrorActionPreference = 'Stop'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$automation = Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll'
$compiler = Join-Path $framework 'csc.exe'
$staging = Join-Path $PSScriptRoot 'CodexConfigSwitcher.build.exe'
$destination = Join-Path $PSScriptRoot 'CodexConfigSwitcher.exe'
$arguments = @(
    '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
    ('/out:' + $staging),
    ('/win32manifest:' + (Join-Path $PSScriptRoot 'app.manifest')),
    ('/reference:' + $automation),
    ('/reference:' + (Join-Path $framework 'WPF\PresentationFramework.dll')),
    ('/reference:' + (Join-Path $framework 'WPF\PresentationCore.dll')),
    ('/reference:' + (Join-Path $framework 'WPF\WindowsBase.dll')),
    ('/reference:' + (Join-Path $framework 'System.Xaml.dll')),
    (Join-Path $PSScriptRoot 'Launcher.cs')
)
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed; the installed executable was not replaced.' }
[IO.File]::Copy($staging, $destination, $true)
[IO.File]::Delete($staging)
Write-Output ('BUILT=' + $destination)
