@echo off
setlocal

rem Safe launcher for batch-status.ps1. Pass -Path and -BatchPath after this
rem command. The archive contents are never rewritten and existing files are
rem never overwritten.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "if ($PSVersionTable.PSVersion.Major -lt 5) { Write-Host 'ERROR: Batch Status Filing requires Windows PowerShell 5.1 or newer.' -ForegroundColor Red; exit 1 }"
if errorlevel 1 exit /b 1

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0batch-status.ps1" %*
exit /b %errorlevel%
