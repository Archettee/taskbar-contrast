' 静默启动 TaskbarContrast.ps1（不弹黑框）
Option Explicit
Dim fso, sh, base
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = base
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\TaskbarContrast.ps1""", 0, False
