@echo off
setlocal
REM ============================================================
REM  L'AGENCE X - applique les droits definis dans config.json.
REM  A lancer seulement apres validation de l'architecture.
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

set "BASE_CONFIG=%~dp0config.json"
set "LATEST_CONFIG=%~dp0resultats\config-permissions-latest.json"
set "CONFIG="

echo.
echo Choix du fichier de configuration :
if exist "%LATEST_CONFIG%" (
    echo   1 - Configuration exportee par le visualiseur : resultats\config-permissions-latest.json
    echo   2 - Configuration de base : config.json
    echo   3 - Autre fichier JSON
    choice /C 123 /N /M "Votre choix : "
    if errorlevel 3 goto choose_other
    if errorlevel 2 set "CONFIG=%BASE_CONFIG%"
    if errorlevel 1 if not defined CONFIG set "CONFIG=%LATEST_CONFIG%"
) else (
    echo   1 - Configuration de base : config.json
    echo   2 - Autre fichier JSON
    choice /C 12 /N /M "Votre choix : "
    if errorlevel 2 goto choose_other
    if errorlevel 1 set "CONFIG=%BASE_CONFIG%"
)

goto config_chosen

:choose_other
echo.
set /P "CONFIG=Chemin complet du fichier JSON : "

:config_chosen
if not exist "%CONFIG%" (
    echo.
    echo [ERREUR] Fichier introuvable :
    echo "%CONFIG%"
    pause
    exit /b 1
)

echo.
echo ATTENTION : ce script applique les permissions du fichier :
echo "%CONFIG%"
echo Verifiez d'abord l'architecture avec 2-Recuperer-Architecture.cmd.
echo.
choice /C ON /N /M "Continuer ? O=oui, N=non : "
if errorlevel 2 (
    echo Annule.
    pause
    exit /b 0
)

echo PowerShell 7 detecte : "%PWSH%"
echo Application des droits L'AGENCE X... patientez.
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\..\Set-SPOFolderPermissions.ps1" -ConfigFile "%CONFIG%" > "%~dp0resultats\appliquer-droits-log.txt" 2>&1
set "CODE=%ERRORLEVEL%"

echo ================= RESULTAT =================
type "%~dp0resultats\appliquer-droits-log.txt"
echo ===========================================
echo.

if "%CODE%"=="0" (
    echo [OK] Droits appliques.
) else (
    echo [ERREUR] Voir resultats\appliquer-droits-log.txt.
)
echo.
pause
exit /b %CODE%
