@echo off
title MSI Stale Product Detector / Fixer
setlocal

REM ============================================================
REM  MSI stale product registration detector / fixer (launcher)
REM  Symptom: install/upgrade fails with "cannot access the network
REM  location ... <GUID>.msi" (error 1706/2203). Old product's
REM  source MSI is gone but its registration remains.
REM  Usage: double-click this file. Registry changes are backed up
REM  to the backup folder before deletion.
REM ============================================================

REM Elevate: relaunch with admin rights via UAC if not admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Need administrator privileges, requesting elevation...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

where powershell >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: PowerShell not found.
    pause
    exit /b 1
)

set SCRIPT=%~dp0msi-stale-fix.ps1

REM Pass through optional arguments (e.g. -Repair)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

echo.
echo Press any key to exit...
pause >nul