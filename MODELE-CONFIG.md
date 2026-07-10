# Modèle de configuration — droits d'accès (fiche mémo)

Ce fichier explique **comment écrire** vos droits d'accès dans `PermissionsConfig.json`.
Un exemple complet et prêt à copier se trouve dans **`PermissionsConfig.EXEMPLE.json`**.

---

## 1. Les niveaux d'accès disponibles (à écrire dans `Role`)

Ce sont les niveaux réels de votre site (français) :

| À écrire dans `Role`  | Ce que la personne peut faire |
|-----------------------|-------------------------------|
| `Contrôle total`      | Tout : gérer, supprimer, changer les permissions |
| `Conception`          | Créer/personnaliser + modifier |
| `Modification`        | Ajouter, modifier, supprimer le contenu |
| `Collaboration`       | Ajouter/modifier **ses propres** éléments |
| `Lecture`             | Voir et ouvrir seulement |
| `Affichage restreint` | Voir sans télécharger |

> Les noms anglais marchent aussi (le script traduit) : `Full Control`, `Design`,
> `Edit`, `Contribute`, `Read`, `Restricted View`.

---

## 2. Les 3 actions possibles sur un dossier

### a) DONNER un accès → `Role`
```json
{ "GroupName": "G_INVITE", "Role": "Modification" }
```

### b) RETIRER / MASQUER un accès → `Access: Deny`
Le groupe ne verra plus le dossier (rupture d'héritage + retrait) :
```json
{ "GroupName": "G_INVITE", "Access": "Deny" }
```

### c) DOSSIER PRIVÉ → `ResetPermissions: true` (au niveau du dossier)
Le dossier n'est visible **que** par les groupes listés (retire même « Membres » /
« Visiteurs » du site) :
```json
{
  "Library": "Documents",
  "FolderPath": "Dossier Direction",
  "ResetPermissions": true,
  "Assignments": [
    { "GroupName": "G_DIRECTION", "Role": "Contrôle total" }
  ]
}
```

---

## 3. Comment est structuré le fichier

```
Permissions            = LA LISTE des dossiers à configurer
  └─ Library           = la bibliothèque (ex : "Documents")
  └─ FolderPath        = le nom du dossier (ex : "Dossier A")
  └─ ResetPermissions  = (optionnel) true = dossier privé
  └─ Assignments       = LA LISTE des groupes pour ce dossier
        └─ GroupName   = nom du groupe Entra ID (ex : "G_INVITE")
        └─ Role        = un niveau d'accès (voir tableau §1)   ← pour DONNER
        └─ Access      = "Deny"                                ← pour RETIRER
```

**Règle :** dans une ligne d'`Assignments`, on met **soit** `Role` (donner)
**soit** `Access: "Deny"` (retirer) — pas les deux.

---

## 4. Exemple complet (voir `PermissionsConfig.EXEMPLE.json`)

```json
"Permissions": [
  {
    "Library": "Documents",
    "FolderPath": "Dossier A",
    "Assignments": [
      { "GroupName": "G_INVITE", "Role": "Contrôle total" }
    ]
  },
  {
    "Library": "Documents",
    "FolderPath": "Dossier B",
    "Assignments": [
      { "GroupName": "G_INVITE", "Role": "Modification" },
      { "GroupName": "G_COMPTA", "Role": "Lecture" }
    ]
  },
  {
    "Library": "Documents",
    "FolderPath": "Dossier C",
    "Assignments": [
      { "GroupName": "G_INVITE", "Access": "Deny" }
    ]
  },
  {
    "Library": "Documents",
    "FolderPath": "Dossier Direction",
    "ResetPermissions": true,
    "Assignments": [
      { "GroupName": "G_DIRECTION", "Role": "Contrôle total" }
    ]
  }
]
```

**Ce que ça donne :**
- **Dossier A** : G_INVITE = Contrôle total
- **Dossier B** : G_INVITE = Modification, et G_COMPTA = Lecture
- **Dossier C** : G_INVITE = aucun accès (masqué)
- **Dossier Direction** : privé — visible **uniquement** par G_DIRECTION

---

## 5. Règles importantes

- Chaque **`GroupName`** doit exister dans Entra ID (sinon la ligne = `ECHEC`).
- Chaque **`FolderPath`** doit exister dans la bibliothèque (sinon = `ECHEC`).
  Les autres lignes continuent quand même (chaque erreur est isolée).
- Le **masquage** (`Deny`) ne cache le dossier que si le groupe **n'est pas membre
  du site** (« Membres » / « Visiteurs »). Sinon, utilisez `ResetPermissions: true`.
- Après exécution, le log affiche **« Accès effectifs »** pour chaque dossier :
  la liste réelle de qui a accès → votre preuve de vérification.

---

## 6. Pour appliquer

Double-cliquez sur **`2-Appliquer-Permissions.cmd`** (il lit `PermissionsConfig.json`).
Puis vérifiez le log `appliquer-permissions-log.txt`.
