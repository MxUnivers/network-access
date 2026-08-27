@echo off
setlocal
cd /d "%~dp0"

echo Creation de l'environnement Python local...

if not exist ".venv\Scripts\python.exe" (
    py -3 -m venv .venv 2>nul || python -m venv .venv
)

if not exist ".venv\Scripts\python.exe" (
    echo [ERREUR] Impossible de creer .venv. Verifiez que Python est installe.
    pause
    exit /b 1
)

".venv\Scripts\python.exe" -m pip install --upgrade pip
".venv\Scripts\python.exe" -m pip install -r requirements-dev.txt

echo.
echo Environnement pret.
pause
