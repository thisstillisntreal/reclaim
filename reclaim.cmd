@echo off
rem Reclaim entry point: runs reclaim.ps1 under Windows PowerShell 5.1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0reclaim.ps1" %*
exit /b %ERRORLEVEL%
