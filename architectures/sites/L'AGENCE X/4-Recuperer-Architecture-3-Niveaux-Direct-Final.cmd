@echo off
setlocal
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
set "LOG=%~dp0resultats\recuperation-3-niveaux-direct-final-log.txt"
echo Recuperation directe des niveaux 1 a 3, sans RecursiveAll...
echo Les fichiers ne sont pas recuperes. Les groupes et roles explicites sont charges.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\..\Get-SPOArchitecture-3Levels-Direct-Bootstrap.ps1" -ConfigFile "%~dp0config.json" -OutputDir "%~dp0resultats" -AvecPermissions > "%LOG%" 2>&1
set "CODE=%ERRORLEVEL%"
echo ================= RESULTAT =================
type "%LOG%"
echo =============================================
if not "%CODE%"=="0" echo [ERREUR] Recuperation directe non terminee.
if "%CODE%"=="0" echo [OK] JSON : resultats\architecture-3-niveaux-direct-latest.json
echo.
pause
exit /b %CODE%

