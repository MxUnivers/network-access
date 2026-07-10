# Architecture du projet — Automatisation des permissions SharePoint

## 1. Vue d'ensemble

Le projet applique des **droits d'accès sur des dossiers SharePoint Online** de façon
**automatique** (sans fenêtre de connexion), à partir d'un **fichier de configuration JSON**.
Il s'authentifie en mode **application + certificat** (app-only).

3 briques :
- des **lanceurs `.cmd`** (double-clic) qui trouvent PowerShell 7 et lancent le bon script ;
- des **scripts PowerShell `.ps1`** qui font le travail ;
- des **fichiers `.json`** qui décrivent QUOI faire (les droits), sans toucher au code.

---

## 2. Schéma de fonctionnement

```
   UTILISATEUR
      │  (double-clic)
      ▼
┌─────────────────────────┐     trouve PowerShell 7 (version MSI)
│   Lanceur  .cmd          │──────────────────────────────────────┐
│  (1- 2- 3- 4- 5-)        │                                       │
└─────────────────────────┘                                       ▼
                                                        ┌────────────────────┐
                                                        │   Script .ps1       │
                                                        └────────┬───────────┘
                                                                 │ lit
                                                                 ▼
                                                   ┌───────────────────────────┐
                                                   │  PermissionsConfig.json    │
                                                   │  (Auth + SiteUrl + droits) │
                                                   └────────────┬──────────────┘
                                                                │ certificat (app-only)
                                        ┌───────────────────────┴───────────────────────┐
                                        ▼                                                 ▼
                             ┌────────────────────┐                          ┌────────────────────┐
                             │  Microsoft Graph    │                          │  SharePoint (PnP)   │
                             │  (valide les groupes)│                         │  (applique les droits)│
                             └────────────────────┘                          └─────────┬──────────┘
                                                                                        │ écrit
                                                                                        ▼
                                                                        ┌──────────────────────────┐
                                                                        │  Logs\  +  *-log.txt      │
                                                                        │  (journal + bilan)        │
                                                                        └──────────────────────────┘
```

---

## 3. Les fichiers, par rôle

### 🟦 Scripts PowerShell (le moteur)

| Fichier | Rôle |
|---------|------|
| `Set-SPOFolderPermissions.ps1` | **Cœur du projet** : lit le JSON, se connecte, applique/retire les droits, écrit le bilan |
| `Test-SPOConnection.ps1` | **Test en lecture seule** : vérifie l'auth, les groupes et les dossiers, sans rien modifier |
| `New-SPOAppCertificate.ps1` | Génère le **certificat** (une seule fois) à téléverser dans Azure |
| `Get-SPOArchitecture.ps1` | Exporte l'**arborescence d'un site** (dossiers + permissions) en JSON |

### 🟩 Lanceurs `.cmd` (double-clic — évitent la ligne de commande)

| Fichier | Lance… | Sur quel JSON |
|---------|--------|---------------|
| `1-Tester-Connexion.cmd` | `Test-SPOConnection.ps1` | `PermissionsConfig.json` |
| `2-Appliquer-Permissions.cmd` | `Set-SPOFolderPermissions.ps1` | `PermissionsConfig.json` |
| `3-Tester-Config-Reelle.cmd` | `Set-SPOFolderPermissions.ps1` | `PermissionsConfig.TEST.json` |
| `4-Tester-Masquage.cmd` | `Set-SPOFolderPermissions.ps1` | `PermissionsConfig.MASQUAGE.json` |
| `5-Recuperer-Architecture.cmd` | `Get-SPOArchitecture.ps1` | `PermissionsConfig.json` (Auth) |

### 🟨 Configurations `.json` (le QUOI — sans toucher au code)

| Fichier | Usage |
|---------|-------|
| `PermissionsConfig.json` | **Le fichier de production** (celui qu'on applique vraiment) |
| `PermissionsConfig.EXEMPLE.json` | Modèle montrant tous les cas (Role / Deny / dossier privé) |
| `PermissionsConfig.TEST.json` | Jeu de test (plusieurs dossiers) |
| `PermissionsConfig.MASQUAGE.json` | Jeu de test « A visible / B masqué » |

### 🟪 Documentation

| Fichier | Contenu |
|---------|---------|
| `README-INSTALLATION.md` | Installation pas à pas (PS7, certificat, App Azure, exécution) |
| `MODELE-CONFIG.md` | Fiche mémo : tous les droits d'accès et comment les écrire |
| `ARCHITECTURE.md` | **Ce document** — la structure du code |

### ⚙️ Sorties (générées automatiquement)

| Élément | Contenu |
|---------|---------|
| `Logs\SPO_Permissions_*.log` | Journal détaillé de chaque exécution |
| `*-log.txt` (à la racine) | Copie de la sortie de chaque lanceur `.cmd` |
| `architecture\<Site>\*.json` | Inventaire d'architecture (via le script 5) |

---

## 4. Le flux détaillé (exemple : `2-Appliquer-Permissions.cmd`)

1. Le **lanceur `.cmd`** cherche `pwsh.exe` (priorité à la version MSI) puis lance le script.
2. Le script **vérifie PowerShell 7** (garde-fou) et **installe/charge** les modules
   (PnP + Graph) dans `AppData\Local` (pour contourner l'anti-rançongiciel Defender).
3. Il **lit `PermissionsConfig.json`** : bloc `Auth` + `SiteUrl` + liste `Permissions`.
4. Il se **connecte** à Microsoft Graph et à SharePoint via le **certificat** (aucune fenêtre).
5. Pour chaque **dossier** de la liste :
   - rupture d'héritage si besoin ;
   - pour chaque **groupe** : soit **attribution** d'un rôle, soit **retrait** (`Deny`) ;
   - **rapport « Accès effectifs »** (qui a accès après coup).
6. Il écrit un **bilan** (réussites / échecs) et un **journal** dans `Logs\`.

---

## 5. Les briques techniques clés

- **Authentification app-only + certificat** → 100 % automatisable, aucune fenêtre.
- **PowerShell 7 obligatoire** (PnP 3.x) → garde-fou + lanceurs qui le trouvent seuls.
- **Modules installés dans `AppData\Local`** → contourne « l'Accès contrôlé aux dossiers ».
- **Résolveur de rôle EN → FR** → on peut écrire `Full Control` ou `Contrôle total`.
- **3 actions** dans le JSON : `Role` (donner), `Access: Deny` (masquer),
  `ResetPermissions: true` (dossier privé).
- **Isolation des erreurs** (`try/catch` par dossier) → une ligne en échec n'arrête pas le reste.
- **Codes de sortie** : `0` = OK, `2` = échecs partiels, `1` = blocage.

---

## 6. Comment étendre

- **Nouveaux droits** → éditer `PermissionsConfig.json` (voir `MODELE-CONFIG.md`), sans toucher au code.
- **Nouveau site** → `Get-SPOArchitecture.ps1 -SiteUrl "..."`, ou dupliquer un fichier de config.
- **Nouvelle action** (ex. héritage, suppression de groupe) → à ajouter dans
  `Set-FolderPermission` de `Set-SPOFolderPermissions.ps1`.
