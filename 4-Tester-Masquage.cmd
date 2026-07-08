@echo off
setlocal
REM ============================================================
REM  Test de MASQUAGE : G_INVITE voit Dossier A, PAS Dossier B.
REM  Applique PermissionsConfig.MASQUAGE.json
REM   - Dossier A -> acces Lecture pour G_INVITE (visible)
REM   - Dossier B -> retrait de l'acces de G_INVITE (masque)
REM  Sortie enregistree dans test-masquage-log.txt
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
echo TEST DE MASQUAGE (Dossier A visible / Dossier B masque) ... patientez.
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-SPOFolderPermissions.ps1" -ConfigFile "PermissionsConfig.MASQUAGE.json" > "%~dp0test-masquage-log.txt" 2>&1

echo.
echo ================= RESULTAT =================
type "%~dp0test-masquage-log.txt"
echo ===========================================
echo (Sortie aussi enregistree dans : test-masquage-log.txt)
echo.
pause
