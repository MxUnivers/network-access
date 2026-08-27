# Developpement local

## Preparer l'environnement

Double-cliquez sur `Creer-Environnement-Dev.cmd`.

Le script cree `.venv` dans ce dossier puis installe les dependances de build.

## Lancer l'application

Double-cliquez sur `Lancer-Dev.cmd`.

L'application ouvre une console multi-sites avec jusqu'a 10 onglets. Chaque onglet garde ses propres parametres, son fichier JSON importe et sa console PowerShell.

## Construire l'executable

Depuis ce dossier :

```powershell
.venv\Scripts\python.exe -m PyInstaller SPO-Gestionnaire.spec
```
