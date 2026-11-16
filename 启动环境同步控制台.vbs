' Harness env-sync console launcher (no console window).
' Starts Windows PowerShell 5.1 hidden, and runs EnvSyncConsole.ps1 sitting next to this file.
Option Explicit
Dim fso, sh, ps, base, script
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
base = fso.GetParentFolderName(WScript.ScriptFullName)
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
script = base & "\EnvSyncConsole.ps1"
sh.Run """" & ps & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
