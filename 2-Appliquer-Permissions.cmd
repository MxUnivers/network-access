@echo off
setlocal
REM ============================================================
REM  Application REELLE des permissions - trouve PowerShell 7 tout seul
REM  et enregistre la sortie dans appliquer-permissions-log.txt
REM  A lancer seulement apres un test de connexion tout vert.
REM ============================================================

set "PWSH="
REM version MSI stable en priorite (evite la version Store/MSIX qui bloque l'install des modules)
if not defined PWSH if exist "C:\Program Files\PowerShell\7\pwsh.exe" set "PWSH=C:\Program Files\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
for %%P in (pwsh.exe) do if not defined PWSH if exist "%%~$PATH:P" set "PWSH=%%~$PATH:P"
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
echo Application des permissions en cours... patientez.
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-SPOFolderPermissions.ps1" > "%~dp0appliquer-permissions-log.txt" 2>&1

echo.
echo ================= RESULTAT =================
type "%~dp0appliquer-permissions-log.txt"
echo ===========================================
echo (Sortie aussi enregistree dans : appliquer-permissions-log.txt)
echo.
pause
