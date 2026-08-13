@echo off
setlocal

rem Run intake.ps1 as one script file. Pasting/running selected PowerShell lines
rem breaks if/else blocks and leaves the automatic $PSCmdlet variable unset.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "if ($PSVersionTable.PSVersion.Major -lt 3) { Write-Host 'ERROR: Returns Intake requires PowerShell 3.0 or newer.' -ForegroundColor Red; exit 1 }"
if errorlevel 1 exit /b 1

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0intake.ps1" %*
exit /b %errorlevel%
