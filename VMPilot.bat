@echo off
REM VMPilot - GUI launcher
REM Auto-elevates and starts the WPF GUI with no console window.
REM
REM VM-Pilot requires PowerShell 7 (pwsh.exe). Windows PowerShell 5.1 is NOT
REM supported and is deliberately not used as a fallback -- silently running
REM the GUI under 5.1 produces failures far from their cause.

set "GUI=%~dp0VMPilot.GUI.ps1"

where pwsh >nul 2>nul
if %errorlevel% neq 0 (
    echo.
    echo   VM-Pilot requires PowerShell 7, which was not found on this machine.
    echo.
    echo   Install it with:  winget install --id Microsoft.PowerShell
    echo   or download from: https://aka.ms/powershell
    echo.
    pause
    exit /b 1
)

start "" /b pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%GUI%"
exit /b
