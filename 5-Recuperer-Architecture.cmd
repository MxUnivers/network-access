@echo off
setlocal
REM ============================================================
REM  Recupere l'architecture du site (bibliotheques/dossiers + permissions)
REM  et l'exporte dans architecture\<NomDuSite>\architecture_*.json
REM ============================================================

set "PWSH="
if not defined PWSH if exist "C:\Program Files\PowerShell\7\pwsh.exe" set "PWSH=C:\Program Files\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
for %%P in (pwsh.exe) do if not defined PWSH if exist "%%~$PATH:P" set "PWSH=%%~$PATH:P"
if not defined PWSH if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"

if not defined PWSH (
    echo.
    echo [ERREUR] PowerShell 7 est introuvable sur cette machine.
    pause
    exit /b 1
)

echo PowerShell 7 detecte : "%PWSH%"
echo.
echo Recuperation de l'architecture en cours... patientez.
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-SPOArchitecture.ps1" > "%~dp0recuperer-architecture-log.txt" 2>&1

echo.
echo ================= RESULTAT =================
type "%~dp0recuperer-architecture-log.txt"
echo ===========================================
echo (Sortie aussi enregistree dans : recuperer-architecture-log.txt)
echo.
pause
