@echo off
REM VMPilot - GUI launcher
REM Auto-elevates and starts the WPF GUI with no console window.

set "GUI=%~dp0VMPilot.GUI.ps1"

REM Prefer pwsh (PowerShell 7+); fall back to Windows PowerShell.
where pwsh >nul 2>nul
if %errorlevel% == 0 (
    start "" /b pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%GUI%"
) else (
    start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%GUI%"
)
exit /b
