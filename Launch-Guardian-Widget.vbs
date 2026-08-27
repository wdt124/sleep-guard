Option Explicit

Dim shell, fso, scriptDir, widgetScript, powershellPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
widgetScript = fso.BuildPath(scriptDir, "Guardian-Widget.ps1")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
command = Chr(34) & powershellPath & Chr(34) & _
          " -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File " & _
          Chr(34) & widgetScript & Chr(34)

' Window style 0 is fully hidden. Waiting keeps Task Scheduler aware that the widget is alive.
shell.Run command, 0, True
