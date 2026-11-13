#requires -Version 5.1
<#
    uninstall.ps1 - stop the watcher and remove the Startup shortcut.
    Leaves the script files in place (delete this folder yourself if you want).
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$ps1  = Join-Path $root 'TaskbarContrast.ps1'

if (Test-Path -LiteralPath $ps1) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 -Stop | Out-Null
}

$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'TaskbarContrast.lnk'
if (Test-Path -LiteralPath $lnk) {
    Remove-Item -LiteralPath $lnk -Force
    Write-Host "Removed autostart shortcut: $lnk"
}

Remove-Item -LiteralPath (Join-Path $root 'taskbar-contrast.pid') -Force -ErrorAction SilentlyContinue
Write-Host "Uninstalled. Your Windows theme setting is left exactly as it is now."
