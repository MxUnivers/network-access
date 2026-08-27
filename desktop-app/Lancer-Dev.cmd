@echo off
setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    call "%~dp0Creer-Environnement-Dev.cmd"
)

".venv\Scripts\python.exe" app.py
