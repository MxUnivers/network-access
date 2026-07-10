# Site : L'AGENCE X

Ce dossier est le kit de production pour le site SharePoint de l'agence X.

## Ordre d'execution

1. `1-Tester-Connexion.cmd` : verifie la connexion Graph + SharePoint en lecture seule.
2. `2-Recuperer-Architecture.cmd` : exporte l'architecture et les permissions dans `resultats\`, puis ouvre le resultat et l'editeur visuel.
3. Dans `Visualiseur-Architecture.html`, charger `resultats\architecture-latest.json`, choisir les droits par dossier, puis exporter `config-permissions-latest.json`.
4. `3-Appliquer-Droits-Acces.cmd` : choisir `resultats\config-permissions-latest.json`, `config.json`, ou un autre fichier JSON, puis appliquer les droits.

## Fichiers importants

- `config.json` : URL du site, authentification, dossiers et groupes a configurer.
- `cle.cer` : deposer ici le certificat public du site si vous voulez le conserver avec le dossier.
- `Visualiseur-Architecture.html` : visualiseur + editeur des droits ; il exporte une configuration compatible avec le script PowerShell.
- `resultats\architecture-latest.html` : visualisation automatique creee par `2-Recuperer-Architecture.cmd`.
- `resultats\config-permissions-latest.json` : configuration exportee par le visualiseur et utilisable directement par `3-Appliquer-Droits-Acces.cmd` quand elle est enregistree dans `resultats\`.

## Points a verifier avant production

- Corriger `SiteUrl` dans `config.json` si l'URL reelle n'est pas `https://lagencexci.sharepoint.com/sites/LAGENCEX`.
- Adapter les blocs `Permissions` a l'architecture reelle recuperee.
- Dans l'editeur, seuls les dossiers explicitement configures sont exportes : les autres dossiers ne sont pas modifies.
- L'option `Remplacer les droits actuels avant appliquer` exporte `ResetPermissions: true` pour le dossier choisi.
- `CertificateThumbprint` est prioritaire pour la connexion. Si vous voulez utiliser un fichier `.pfx`, laissez `CertificateThumbprint` vide et renseignez `CertificatePath` + `CertificatePassword`.
- Un fichier `.cer` seul est normalement public : il sert surtout a Azure/Entra ID. Pour se connecter sans empreinte installee, il faut generalement un `.pfx` contenant la cle privee.

## Authentification production

- `TenantId` doit correspondre au tenant du site `lagencexci.sharepoint.com` : `lagencexci.onmicrosoft.com`.
- `cle.cer` est le certificat public a televerser dans l'App Registration `4fd0a256-1ab4-4984-b9b3-9860da2cfaf3`.
- Portail Azure/Entra ID : App registrations > l'application > Certificates & secrets > Certificates > Upload certificate > choisir `cle.cer`.
- Ensuite verifier les permissions d'application et le consentement admin :
  - Microsoft Graph : `Group.Read.All`
  - SharePoint : `Sites.FullControl.All`
