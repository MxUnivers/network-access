@echo off
setlocal
cd /d "%~dp0"

echo ==========================================
echo  Construction de SPO-Gestionnaire.exe
echo ==========================================
echo.

if not exist ".venv\Scripts\python.exe" (
    call "%~dp0Creer-Environnement-Dev.cmd"
)

if not exist ".venv\Scripts\python.exe" (
    echo [ERREUR] Environnement Python introuvable.
    pause
    exit /b 1
)

".venv\Scripts\python.exe" -m pip install -r requirements-dev.txt

echo.
echo Nettoyage ancienne construction...
if exist "build" rmdir /s /q "build"
if exist "dist" rmdir /s /q "dist"

echo.
echo Compilation PyInstaller...
".venv\Scripts\python.exe" -m PyInstaller --clean --noconfirm SPO-Gestionnaire.spec

if errorlevel 1 (
    echo.
    echo [ERREUR] La construction a echoue.
    pause
    exit /b 1
)

echo.
echo ==========================================
echo  Executable genere :
echo  %~dp0dist\SPO-Gestionnaire.exe
echo ==========================================
echo.
pause