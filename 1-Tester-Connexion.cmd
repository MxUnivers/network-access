@echo off
setlocal
REM ============================================================
REM  Test de connexion (lecture seule) - trouve PowerShell 7 tout seul
REM  et enregistre la sortie dans test-connexion-log.txt
REM ============================================================

set "PWSH="
REM 1) version MSI stable (prioritaire - evite la version Store/MSIX qui bloque l'install des modules)
if not defined PWSH if exist "C:\Program Files\PowerShell\7\pwsh.exe" set "PWSH=C:\Program Files\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
REM 2) sinon, pwsh dans le PATH
for %%P in (pwsh.exe) do if not defined PWSH if exist "%%~$PATH:P" set "PWSH=%%~$PATH:P"
REM 3) en dernier recours, version Store
if not defined PWSH if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"

if not defined PWSH (
    echo.
    echo [ERREUR] PowerShell 7 est introuvable sur cette machine.
    echo Installez-le puis relancez ce fichier.
    echo.
    pause
    exit /b 1
)

echo PowerShell 7 detecte : "%PWSH%"
echo.
echo Test en cours...
echo La 1re fois, l'installation des modules peut durer plusieurs MINUTES.
echo Ne fermez pas cette fenetre, patientez jusqu'au message RESULTAT.
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-SPOConnection.ps1" > "%~dp0test-connexion-log.txt" 2>&1

echo.
echo ================= RESULTAT =================
type "%~dp0test-connexion-log.txt"
echo ===========================================
echo (Sortie aussi enregistree dans : test-connexion-log.txt)
echo.
pause
