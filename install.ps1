#requires -Version 5.1
<#
    install.ps1 - install TaskbarContrast to start automatically at logon.
    No administrator rights required. Only touches the current user's Startup folder.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$vbs  = Join-Path $root 'start-hidden.vbs'
$ps1  = Join-Path $root 'TaskbarContrast.ps1'

if (-not (Test-Path -LiteralPath $vbs) -or -not (Test-Path -LiteralPath $ps1)) {
    throw "TaskbarContrast.ps1 / start-hidden.vbs not found next to install.ps1."
}

# Stop a previous instance so we start clean.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 -Stop | Out-Null

$startup = [Environment]::GetFolderPath('Startup')
$lnk     = Join-Path $startup 'TaskbarContrast.lnk'

$ws = New-Object -ComObject WScript.Shell
$shortcut = $ws.CreateShortcut($lnk)
$shortcut.TargetPath       = "$env:WINDIR\System32\wscript.exe"
$shortcut.Arguments        = '"' + $vbs + '"'
$shortcut.WorkingDirectory = $root
$shortcut.WindowStyle      = 7
$shortcut.Description      = 'Taskbar contrast - automatic black/white taskbar text'
$shortcut.Save()

Start-Process -FilePath "$env:WINDIR\System32\wscript.exe" -ArgumentList ('"' + $vbs + '"') -WorkingDirectory $root

Start-Sleep -Seconds 3
Write-Host "Installed."
Write-Host "  autostart : $lnk"
Write-Host "  log       : $(Join-Path $root 'taskbar-contrast.log')"
Write-Host "Stop with : powershell -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -Stop"
