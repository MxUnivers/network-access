# Installation — Automatisation des permissions SharePoint

Ce dossier automatise l'attribution de droits d'accès à des groupes Entra ID
sur des dossiers SharePoint Online, **sans intervention humaine** (aucune fenêtre
de connexion). L'authentification se fait par **certificat** (mode « app-only »).

## Pourquoi l'ancienne version échouait

L'ancien script utilisait `Connect-MgGraph` et `Connect-PnPOnline -Interactive`,
qui ouvrent une **fenêtre navigateur**. En exécution automatique, personne ne
clique → erreur `User canceled authentication`. De plus, depuis PnP.PowerShell 2.2+,
`-Interactive` **exige un ClientId** (erreur `Please specify a valid client id`).

La nouvelle version s'authentifie avec une **App Registration + certificat**,
100 % automatisable.

---

## Étape 0 — Installer PowerShell 7 (une seule fois, par machine)

PnP.PowerShell 3.x **exige PowerShell 7.4+**. Windows PowerShell 5.1 (console bleue)
ne suffit pas. Préférez la **version MSI** (installée dans `C:\Program Files\PowerShell\7`),
et non la version du Microsoft Store (qui bloque l'installation des modules).

Téléchargez le MSI stable : https://github.com/PowerShell/PowerShell/releases/latest
→ fichier `PowerShell-7.x.x-win-x64.msi` → double-clic → Next → Install (UAC).

⚠️ Ne pas lancer les scripts dans **Git Bash** (`MINGW64`) ni dans **Windows
PowerShell 5.1** : utilisez les lanceurs `.cmd` fournis (double-clic), qui trouvent
PowerShell 7 automatiquement.

---

## Étape 1 — Générer le certificat (une seule fois)

Dans **PowerShell 7** (`pwsh`), depuis ce dossier :

```powershell
.\New-SPOAppCertificate.ps1
```

Le script affiche :
- **l'empreinte (Thumbprint)** → à coller dans `PermissionsConfig.json`
- le fichier **`SPO-Permissions-Automation.cer`** → à téléverser dans Azure (étape 2)

Le certificat privé reste dans `Cert:\CurrentUser\My` de la machine qui exécutera
la tâche planifiée.

---

## Étape 2 — Créer l'App Registration Entra ID (une seule fois)

Portail Azure → **Microsoft Entra ID** → **App registrations** → **New registration**
- Nom : `SPO-Permissions-Automation`
- Supported account types : *Single tenant*
- **Register**

Notez le **Application (client) ID** et le **Directory (tenant) ID**.

### 2a. Téléverser le certificat
App registration → **Certificates & secrets** → onglet **Certificates** →
**Upload certificate** → sélectionnez `SPO-Permissions-Automation.cer` (étape 1).

### 2b. Ajouter les permissions d'API (type **Application**)
App registration → **API permissions** → **Add a permission** :

| API | Permission | Type |
|-----|-----------|------|
| Microsoft Graph | `Group.Read.All` | Application |
| SharePoint | `Sites.FullControl.All` | Application |

Puis cliquez sur **Grant admin consent for <votre tenant>** (bouton en haut).
⚠️ Sans le consentement admin, les connexions échoueront avec une erreur `403`.

---

## Étape 3 — Renseigner `PermissionsConfig.json`

```json
{
  "Auth": {
    "TenantId": "infosolucesivoire.onmicrosoft.com",
    "ClientId": "<Application (client) ID de l'étape 2>",
    "CertificateThumbprint": "<Thumbprint de l'étape 1>",
    "CertificatePath": "",
    "CertificatePassword": ""
  },
  "SiteUrl": "https://infosolucesivoire.sharepoint.com/sites/Site_temp",
  "Permissions": [
    {
      "Library": "Documents",
      "FolderPath": "Dossier A",
      "Assignments": [
        { "GroupName": "G_INVITE", "Role": "Full Control" }
      ]
    }
  ]
}
```

- `TenantId` : le domaine `xxx.onmicrosoft.com` (ou le GUID du tenant).
- `CertificateThumbprint` : **prioritaire**. Si vous préférez un fichier `.pfx`,
  laissez le thumbprint vide et renseignez `CertificatePath` + `CertificatePassword`.
- Ajoutez autant de blocs `Permissions` / `Assignments` que nécessaire.
- Rôles acceptés (le script traduit tout seul EN → FR sur un site français) :
  `Full Control`/`Contrôle total`, `Edit`/`Modification`, `Contribute`/`Collaboration`,
  `Read`/`Lecture`.

---

## Étape 4 — Exécuter (double-clic)

- **`1-Tester-Connexion.cmd`** → test en lecture seule (ne modifie rien)
- **`2-Appliquer-Permissions.cmd`** → applique réellement les droits de `PermissionsConfig.json`
- **`3-Tester-Config-Reelle.cmd`** → applique les droits du fichier de test `PermissionsConfig.TEST.json`

À la fin, un **bilan** indique le nombre d'attributions réussies / échouées, et un
journal complet est écrit dans `.\Logs\`. Codes de sortie :
- `0` = tout est OK
- `2` = terminé avec des échecs (voir le log)
- `1` = échec bloquant (config ou connexion)

---

## Étape 5 (optionnel) — Planifier l'exécution automatique

Planificateur de tâches Windows → **Créer une tâche** :
- Action → Démarrer un programme :
  - Programme : `C:\Program Files\PowerShell\7\pwsh.exe`
  - Arguments : `-NoProfile -ExecutionPolicy Bypass -File "A:\Projets\network-connect\Set-SPOFolderPermissions.ps1"`
- Exécuter avec le compte utilisateur **propriétaire du certificat** (étape 1),
  option « Exécuter même si l'utilisateur n'est pas connecté ».

---

## Vérifier que « ça a marché »

1. **Sortie console** : lignes vertes `SUCCESS` (connexions + attributions).
2. **Bilan final** : `BILAN : X attribution(s) reussie(s), 0 echec(s)`.
3. **Journal** : fichier dans `.\Logs\SPO_Permissions_*.log`.
4. **Côté SharePoint** : sur le dossier ciblé → *Gérer l'accès* → le groupe apparaît
   avec le rôle attendu.

---

## Notes de dépannage (spécifique à cette machine)

- **PowerShell 7** doit être la version **MSI** (`C:\Program Files\PowerShell\7`),
  pas celle du Store.
- Les modules PnP/Graph s'installent dans `AppData\Local\SPO-Automation\Modules`
  (et **pas** dans `Documents`, bloqué par l'**Accès contrôlé aux dossiers** de
  Windows Defender).
- Le site étant en **français**, les niveaux d'autorisation réels s'appellent
  « Contrôle total », « Modification », « Lecture »… Le script fait la traduction
  automatiquement.
