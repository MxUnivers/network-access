@echo off
setlocal
REM L'AGENCE X - bibliotheques + dossiers jusqu'au niveau 3.
REM Aucun fichier n'est charge; groupes et roles explicites inclus.
cd /d "%~dp0"
set "PWSH="
if exist "C:\Program Files\PowerShell\7\pwsh.exe" set "PWSH=C:\Program Files\PowerShell\7\pwsh.exe"
if not defined PWSH for %%P in (pwsh.exe) do if exist "%%~$PATH:P" set "PWSH=%%~$PATH:P"
if not defined PWSH (
  echo [ERREUR] PowerShell 7 introuvable.
  pause
  exit /b 1
)
if not exist "%~dp0resultats" mkdir "%~dp0resultats"
set "LOG=%~dp0resultats\recuperation-3-niveaux-direct-log.txt"
echo Recuperation directe des niveaux 1 a 3, sans RecursiveAll...
echo Les fichiers ne sont pas recuperes; groupes et roles explicites inclus.
echo.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\..\Get-SPOArchitecture-3Levels-Direct-Bootstrap.ps1" -ConfigFile "%~dp0config.json" -OutputDir "%~dp0resultats" -AvecPermissions > "%LOG%" 2>&1
set "CODE=%ERRORLEVEL%"
echo ================= RESULTAT =================
type "%LOG%"
echo =============================================
if "%CODE%"=="0" (
  echo [OK] JSON : resultats\architecture-3-niveaux-direct-latest.json
  echo [INFO] Chargez ce JSON dans Visualiseur-Architecture.html.
) else (
  echo [ERREUR] Recuperation non terminee. Voir %LOG%.
)
echo.
pause
exit /b %CODE%

