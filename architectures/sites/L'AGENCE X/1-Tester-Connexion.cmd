@echo off
setlocal
REM ============================================================
REM  L'AGENCE X - test de connexion lecture seule.
REM  Ne modifie aucune permission.
REM ============================================================

cd /d "%~dp0"

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
echo Test de connexion L'AGENCE X...
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\..\Test-SPOConnection.ps1" -ConfigFile "%~dp0config.json" > "%~dp0resultats\test-connexion-log.txt" 2>&1
set "CODE=%ERRORLEVEL%"

echo ================= RESULTAT =================
type "%~dp0resultats\test-connexion-log.txt"
echo ===========================================
echo.

if "%CODE%"=="0" (
    echo [OK] Connexion validee. Vous pouvez lancer 2-Recuperer-Architecture.cmd.
) else (
    echo [ERREUR] Connexion non validee. Voir resultats\test-connexion-log.txt.
)
echo.
pause
exit /b %CODE%
