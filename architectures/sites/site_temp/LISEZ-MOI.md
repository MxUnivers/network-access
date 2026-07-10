# Dossier du site : site_temp

Ce dossier contient **tout ce qu'il faut pour UN site**. Il est autonome :
il suffit de le **dupliquer** pour gérer un autre site.

## Contenu

| Fichier | Rôle |
|---------|------|
| `config.json` | La configuration DE CE SITE : authentification, URL du site, droits d'accès |
| `Recuperer-Architecture.cmd` | Double-clic → exporte l'arborescence + permissions du site dans `resultats\` |
| `Appliquer-Permissions.cmd` | Double-clic → applique les droits décrits dans `config.json` |
| `resultats\` | Créé automatiquement : contient les exports JSON et les journaux |

> Les **scripts moteur** (`.ps1`) restent centralisés à la racine du projet
> (`..\..\..\`). Ici, on ne garde que **la config + les lanceurs** de ce site.

## Ajouter un NOUVEAU site (2 minutes)

1. **Copier-coller** le dossier `site_temp` dans `architectures\sites\`.
2. **Renommer** la copie (ex. `site_compta`).
3. Ouvrir `config.json` de la copie et modifier :
   - `SiteUrl` → l'URL du nouveau site
   - `Permissions` → les dossiers / groupes / droits de ce site
   - *(`Auth` reste identique tant que c'est le même tenant / certificat)*
4. Double-cliquer `Recuperer-Architecture.cmd` ou `Appliquer-Permissions.cmd`.

## Arborescence

```
architectures\
  └─ sites\
       ├─ site_temp\
       │    ├─ config.json
       │    ├─ Recuperer-Architecture.cmd
       │    ├─ Appliquer-Permissions.cmd
       │    └─ resultats\   (exports + logs)
       └─ site_compta\      (une copie, pour un autre site)
            └─ ...
```
