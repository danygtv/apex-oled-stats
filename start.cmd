@echo off
rem Startet OledStats.ps1 mit Adminrechten (noetig fuer CPU-Sensoren).
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath cmd -ArgumentList '/c \"%~f0\"'"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0OledStats.ps1"
pause
