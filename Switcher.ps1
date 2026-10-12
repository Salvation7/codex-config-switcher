param([switch]$SmokeTest)
& (Join-Path $PSScriptRoot 'Switcher.UI.ps1') -SmokeTest:$SmokeTest
