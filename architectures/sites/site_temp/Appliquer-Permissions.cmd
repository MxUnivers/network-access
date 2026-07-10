@echo off
setlocal
REM ============================================================
REM  Applique les permissions de CE site (config.json de ce dossier).
REM  Pour un autre site : DUPLIQUER ce dossier et modifier config.json.
REM ============================================================

set "PWSH="
if not defined PWSH if exist "C:\Program Files\PowerShell\7\pwsh.exe" set "PWSH=C:\Program Files\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
for %%P in (pwsh.exe) do if not defined PWSH if exist "%%~$PATH:P" set "PWSH=%%~$PATH:P"
if not defined PWSH if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"

if not defined PWSH (
    echo [ERREUR] PowerShell 7 introuvable.
    pause
    exit /b 1
)

if not exist "%~dp0resultats" mkdir "%~dp0resultats"

echo PowerShell 7 detecte : "%PWSH%"
echo Application des permissions de ce site... patientez.
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\..\Set-SPOFolderPermissions.ps1" -ConfigFile "%~dp0config.json" > "%~dp0resultats\appliquer-log.txt" 2>&1

echo ================= RESULTAT =================
type "%~dp0resultats\appliquer-log.txt"
echo ===========================================
echo.
pause
