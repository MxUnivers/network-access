@echo off
setlocal
REM ============================================================
REM  L'AGENCE X - recupere bibliotheques + dossiers niveaux 1 a 3.
REM  Aucun fichier n'est inclus dans cette architecture allegee.
REM  Ecrit les resultats dans le sous-dossier resultats.
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
echo Recuperation de l'architecture a 3 niveaux L'AGENCE X... patientez.
echo Limite : bibliotheque - dossier niveau 1 - dossier niveau 2 - dossier niveau 3.
echo Les fichiers ne sont pas recuperes.
echo Progression affichee en direct : pourcentage, restant, duree ecoulee, estimation.
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -Command "& { & ""%~dp0..\..\..\Get-SPOArchitecture-3Levels.ps1"" -ConfigFile ""%~dp0config.json"" -OutputDir ""%~dp0resultats"" *>&1 | Tee-Object -FilePath ""%~dp0resultats\recuperation-3-niveaux-log.txt"" }"
set "CODE=%ERRORLEVEL%"

echo ================= RESULTAT =================
type "%~dp0resultats\recuperation-3-niveaux-log.txt"
echo ===========================================
echo.

if "%CODE%"=="0" (
    if exist "%~dp0resultats\architecture-3-niveaux-latest.html" (
        echo Ouverture du resultat visualise...
        start "" "%~dp0resultats\architecture-3-niveaux-latest.html"
        if exist "%~dp0Visualiseur-Architecture.html" (
            echo Ouverture de l'editeur de droits...
            start "" "%~dp0Visualiseur-Architecture.html"
        )
    ) else (
        echo [INFO] Ouvrez Visualiseur-Architecture.html puis choisissez architecture-3-niveaux-latest.json.
    )
) else (
    echo [ERREUR] Recuperation 3 niveaux non terminee. Voir resultats\recuperation-3-niveaux-log.txt.
)
echo.
pause
exit /b %CODE%
