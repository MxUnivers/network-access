@echo off
setlocal
echo Lancement du Gestionnaire de droits SharePoint...
start "" "%~dp0GestionnaireSP\GestionnaireSP.exe"
echo.
echo Si l'application ne se lance pas, executez ce fichier en administrateur.
timeout /t 3 /nobreak >nul
