@echo off
setlocal
title Focusrite Doctor
cd /d "%~dp0"

if not exist "%~dp0Focusrite-Doctor.ps1" (
    echo.
    echo  Focusrite-Doctor.ps1 is missing.
    echo  Right-click the zip file, choose "Extract All", then run this file from the extracted folder.
    echo.
    pause
    exit /b 1
)

rem ---- Ask Windows for Administrator rights once (some fixes need them) ----
fltmc >nul 2>&1 && goto run
if /i "%~1"=="/elevated" goto run
echo.
echo  Windows will ask for permission - click "Yes".
set "SELF=%~f0"
set "SELF=%SELF:'=''%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '/elevated' -Verb RunAs" >nul 2>&1
if errorlevel 1 (
    echo  No Administrator permission - running the checks anyway, some fixes will be skipped.
    goto run
)
exit /b 0

:run
set "FOCUSRITE_DOCTOR_BAT=1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Focusrite-Doctor.ps1"
echo.
pause
