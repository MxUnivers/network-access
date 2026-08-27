<#
.SYNOPSIS
Gestion automatisee des permissions SharePoint Online
sur bibliotheques, dossiers et sous-dossiers.

.DESCRIPTION
Version NON INTERACTIVE (app-only / certificat).
Aucune fenetre navigateur : le script s'authentifie via une
App Registration Entra ID + certificat, en lisant TenantId,
ClientId et empreinte du certificat depuis PermissionsConfig.json.
Concu pour une execution automatique (tache planifiee).

.REQUIREMENTS

- PowerShell 7.4 ou superieur (obligatoire pour PnP.PowerShell 3.x)
- Modules : PnP.PowerShell, Microsoft.Graph.Authentication, Microsoft.Graph.Groups
- Une App Registration Entra ID avec certificat (voir README-INSTALLATION.md)

.AUTHOR
Template Entreprise
#>

# Fichier de configuration a utiliser (optionnel).
# Par defaut : PermissionsConfig.json. Permet de tester un fichier separe,
# ex : pwsh -File Set-SPOFolderPermissions.ps1 -ConfigFile PermissionsConfig.TEST.json
param(
    [string]$ConfigFile
)

#------------------------------------------------------
# GARDE-FOU : PowerShell 7 obligatoire (PnP.PowerShell 3.x)
#------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Red
    Write-Host "  Ce script exige PowerShell 7 (vous etes en $($PSVersionTable.PSVersion))." -ForegroundColor Red
    Write-Host "  N'ouvrez PAS 'Windows PowerShell' (icone BLEUE = 5.1)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  --> Fermez cette fenetre et DOUBLE-CLIQUEZ sur le fichier :" -ForegroundColor Green
    Write-Host "        2-Appliquer-Permissions.cmd" -ForegroundColor Green
    Write-Host "      (il ouvre PowerShell 7 tout seul)" -ForegroundColor Green
    Write-Host "  ============================================================" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# Force l'UTF-8 en sortie (evite les accents casses quand la sortie est
# redirigee/capturee par un autre programme, ex: l'appli de bureau Python).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Toute erreur non geree stoppe le script (evite les faux "reussi")
$ErrorActionPreference = "Stop"

#------------------------------------------------------
# PARAMETRES (chemins relatifs au script, pas au repertoire courant)
#------------------------------------------------------

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }

# Config : parametre -ConfigFile si fourni (chemin relatif = relatif au script), sinon defaut
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $ConfigFile = Join-Path $ScriptRoot "PermissionsConfig.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile = Join-Path $ScriptRoot $ConfigFile
}
$LogDir     = Join-Path $ScriptRoot "Logs"
$LogFile    = Join-Path $LogDir ("SPO_Permissions_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

# Compteurs pour le bilan final
$script:CountOk    = 0
$script:CountError = 0

#------------------------------------------------------
# JOURNALISATION
#------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $Date     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "$Date [$Level] $Message"

    switch ($Level) {
        "ERROR"   { Write-Host $LogEntry -ForegroundColor Red }
        "WARN"    { Write-Host $LogEntry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $LogEntry -ForegroundColor Green }
        default   { Write-Host $LogEntry }
    }

    # Le dossier Logs peut ne pas exister au tout debut : on protege l'ecriture
    if (Test-Path $LogDir) {
        Add-Content -Path $LogFile -Value $LogEntry
    }
}

#------------------------------------------------------
# CREATION DOSSIER LOG (avant tout, pour tracer l'installation)
#------------------------------------------------------

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

Write-Log "=== Demarrage du script (PowerShell $($PSVersionTable.PSVersion)) ==="

#------------------------------------------------------
# INSTALLATION / IMPORT DES MODULES
#------------------------------------------------------

$RequiredModules = @(
    "PnP.PowerShell",
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Groups",
    "Microsoft.Graph.Users"
)

# IMPORTANT : les modules sont installes dans AppData\Local (dossier NON protege),
# et surtout PAS dans Documents (bloque par Controlled Folder Access / anti-rancongiciel).
$ModulesDir = Join-Path $env:LOCALAPPDATA "SPO-Automation\Modules"
if (-not (Test-Path $ModulesDir)) {
    New-Item -ItemType Directory -Path $ModulesDir -Force | Out-Null
}
# Rend ce dossier visible pour Get-Module / Import-Module
if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $ModulesDir) {
    $env:PSModulePath = $ModulesDir + [IO.Path]::PathSeparator + $env:PSModulePath
}

# Telecharge un module dans $ModulesDir (sans droits admin, hors dossiers proteges).
function Install-RequiredModule {
    param([string]$Name)

    if (Get-Module -ListAvailable -Name $Name) { return }

    Write-Log "Installation du module $Name dans $ModulesDir (hors dossiers proteges) ..."

    if (-not (Get-Command Save-PSResource -ErrorAction SilentlyContinue)) {
        throw "Save-PSResource indisponible : PowerShell 7.4+ requis (module Microsoft.PowerShell.PSResourceGet)"
    }

    $SaveParams = @{
        Name                = $Name
        Path                = $ModulesDir
        TrustRepository     = $true
        IncludeXml          = $true
        SkipDependencyCheck = $true
        ErrorAction         = "Stop"
    }

    # Tous les sous-modules Microsoft.Graph.* exigent EXACTEMENT la meme version que
    # Microsoft.Graph.Authentication (deja installe) : sinon Import-Module echoue avec
    # "required module ... is not loaded". On aligne donc la version a installer.
    if ($Name -like "Microsoft.Graph.*" -and $Name -ne "Microsoft.Graph.Authentication") {
        $AuthModule = Get-Module -ListAvailable -Name "Microsoft.Graph.Authentication" | Select-Object -First 1
        if ($AuthModule) { $SaveParams.Version = $AuthModule.Version.ToString() }
    }

    # Save-PSResource ecrit directement dans un dossier cible, sans passer par Documents.
    # -SkipDependencyCheck : les dependances sont deja listees dans $RequiredModules (ordre : Authentication
    # avant Groups/Users), on evite ainsi de reecrire un module deja importe et verrouille.
    Save-PSResource @SaveParams
}

foreach ($Module in $RequiredModules) {
    try {
        Install-RequiredModule -Name $Module
        Import-Module $Module -ErrorAction Stop
        Write-Log "Module charge : $Module"
    }
    catch {
        Write-Log "Erreur module $Module : $($_.Exception.Message)" "ERROR"
        exit 1
    }
}

#------------------------------------------------------
# CHARGEMENT ET VALIDATION DE LA CONFIGURATION
#------------------------------------------------------

try {
    if (-not (Test-Path $ConfigFile)) {
        throw "Fichier de configuration introuvable : $ConfigFile"
    }

    $Config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    Write-Log "Configuration chargee : $ConfigFile"
    $ConfigDir = Split-Path -Parent $ConfigFile

    # Validation des champs obligatoires
    if (-not $Config.SiteUrl)          { throw "Champ 'SiteUrl' manquant dans la configuration" }
    if (-not $Config.Auth)             { throw "Section 'Auth' manquante dans la configuration" }
    if (-not $Config.Auth.TenantId)    { throw "Champ 'Auth.TenantId' manquant" }
    if (-not $Config.Auth.ClientId)    { throw "Champ 'Auth.ClientId' manquant" }

    $HasThumbprint = -not [string]::IsNullOrWhiteSpace($Config.Auth.CertificateThumbprint)
    $HasCertPath   = -not [string]::IsNullOrWhiteSpace($Config.Auth.CertificatePath)

    if ($HasCertPath -and -not [System.IO.Path]::IsPathRooted($Config.Auth.CertificatePath)) {
        $Config.Auth.CertificatePath = Join-Path $ConfigDir $Config.Auth.CertificatePath
    }

    if (-not $HasThumbprint -and -not $HasCertPath) {
        throw "Aucun certificat : renseignez 'CertificateThumbprint' OU 'CertificatePath' dans la section Auth"
    }

    if (-not $HasThumbprint -and $HasCertPath -and -not (Test-Path $Config.Auth.CertificatePath)) {
        throw "Fichier certificat introuvable : $($Config.Auth.CertificatePath)"
    }
}
catch {
    Write-Log "Erreur lecture configuration : $($_.Exception.Message)" "ERROR"
    exit 1
}

#------------------------------------------------------
# CONNEXION MICROSOFT GRAPH (app-only, sans fenetre)
#------------------------------------------------------

try {
    $GraphParams = @{
        TenantId    = $Config.Auth.TenantId
        ClientId    = $Config.Auth.ClientId
        NoWelcome   = $true
        ErrorAction = "Stop"
    }

    if ($HasThumbprint) {
        $GraphParams.CertificateThumbprint = $Config.Auth.CertificateThumbprint
    }
    else {
        $SecurePwd = ConvertTo-SecureString $Config.Auth.CertificatePassword -AsPlainText -Force
        $GraphParams.Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $Config.Auth.CertificatePath,
            $SecurePwd
        )
    }

    Connect-MgGraph @GraphParams

    # Verification REELLE de la connexion (evite le faux "reussi" du log initial)
    $ctx = Get-MgContext
    if (-not $ctx -or -not $ctx.ClientId) {
        throw "Contexte Graph vide apres connexion"
    }

    Write-Log "Connexion Graph reussie (app $($ctx.ClientId), tenant $($ctx.TenantId))" "SUCCESS"
}
catch {
    Write-Log "Erreur connexion Graph : $($_.Exception.Message)" "ERROR"
    exit 1
}

#------------------------------------------------------
# CONNEXION SHAREPOINT (app-only, sans fenetre)
#------------------------------------------------------

try {
    $PnpParams = @{
        Url         = $Config.SiteUrl
        ClientId    = $Config.Auth.ClientId
        Tenant      = $Config.Auth.TenantId
        ErrorAction = "Stop"
    }

    if ($HasThumbprint) {
        $PnpParams.Thumbprint = $Config.Auth.CertificateThumbprint
    }
    else {
        $PnpParams.CertificatePath     = $Config.Auth.CertificatePath
        $PnpParams.CertificatePassword = (ConvertTo-SecureString $Config.Auth.CertificatePassword -AsPlainText -Force)
    }

    Connect-PnPOnline @PnpParams

    # Verification reelle de la connexion
    $web = Get-PnPWeb -ErrorAction Stop
    Write-Log "Connexion SharePoint reussie : $($web.Title) [$($web.Url)]" "SUCCESS"
}
catch {
    Write-Log "Erreur connexion SharePoint : $($_.Exception.Message)" "ERROR"
    # On se deconnecte proprement de Graph avant de sortir
    try { Disconnect-MgGraph | Out-Null } catch { }
    exit 1
}

#------------------------------------------------------
# RESOLUTION DU NIVEAU D'AUTORISATION (gere EN/FR + casse + underscores)
#------------------------------------------------------

# Cache des niveaux d'autorisation reels du site
$script:RoleDefs = $null

function Resolve-RoleName {
    param([string]$Requested)

    if (-not $script:RoleDefs) {
        $script:RoleDefs = Get-PnPRoleDefinition -ErrorAction Stop
    }

    # Normalisation : underscores -> espaces, trim
    $norm = ($Requested -replace '_', ' ').Trim()

    # 1) Correspondance exacte (insensible a la casse) avec un niveau reel du site
    $hit = $script:RoleDefs | Where-Object { $_.Name -ieq $norm } | Select-Object -First 1
    if ($hit) { return $hit.Name }

    # 2) Equivalence anglais -> francais (sites SharePoint en francais)
    $map = @{
        'full control'    = 'Contrôle total'
        'edit'            = 'Modification'
        'contribute'      = 'Collaboration'
        'read'            = 'Lecture'
        'design'          = 'Création'
        'view only'       = 'Affichage seul'
        'restricted view' = 'Affichage restreint'
    }
    $key = $norm.ToLower()
    if ($map.ContainsKey($key)) {
        $hit = $script:RoleDefs | Where-Object { $_.Name -ieq $map[$key] } | Select-Object -First 1
        if ($hit) { return $hit.Name }
    }

    # 3) Introuvable : on affiche les niveaux reellement disponibles pour aider
    $dispo = ($script:RoleDefs | Select-Object -ExpandProperty Name) -join ' | '
    Write-Log "Niveaux d'autorisation disponibles sur ce site : $dispo" "WARN"
    return $null
}

#------------------------------------------------------
# HIERARCHIE DES ROLES (pour detecter les conflits d'heritage)
#------------------------------------------------------

# Rang de chaque niveau : plus le rang est grand, plus le droit est eleve.
# Utilise pour comparer le droit herite du parent avec le droit demande.
$script:RoleRank = @{
    'Accès limité'       = 1
    'Acces limite'       = 1
    'Limited Access'     = 1
    'Affichage restreint' = 2
    'Restricted View'    = 2
    'Affichage seul'     = 3
    'View Only'          = 3
    'Lecture'            = 4
    'Read'               = 4
    'Modification'       = 5
    'Edit'               = 5
    'Collaboration'      = 5
    'Contribute'         = 5
    'Création'           = 6
    'Creation'           = 6
    'Design'             = 6
    'Contrôle total'     = 7
    'Controle total'     = 7
    'Full Control'       = 7
}

function Get-RoleRank {
    param([string]$RoleName)
    $key = ([string]$RoleName).Trim()
    if ([string]::IsNullOrWhiteSpace($key)) { return 0 }
    if ($script:RoleRank.ContainsKey($key)) { return [int]$script:RoleRank[$key] }
    $hit = $script:RoleRank.Keys | Where-Object { $_ -ieq $key } | Select-Object -First 1
    if ($hit) { return [int]$script:RoleRank[$hit] }
    return 0
}

#------------------------------------------------------
# ANALYSE DU PARENT (pour la detection de conflit d'heritage)
#------------------------------------------------------

function Get-ParentFolderUrl {
    param([string]$ServerRelativeUrl)
    $url = ([string]$ServerRelativeUrl).TrimEnd('/')
    $idx = $url.LastIndexOf('/')
    if ($idx -le 0) { return $null }
    return $url.Substring(0, $idx)
}

function Get-MaxRoleLevelFromAssignments {
    param([object]$RoleAssignments)
    $ctx = Get-PnPContext
    $max = 0
    foreach ($ra in @($RoleAssignments)) {
        try {
            $ctx.Load($ra.RoleDefinitionBindings)
            $ctx.ExecuteQuery()
        }
        catch { continue }
        foreach ($rdb in @($ra.RoleDefinitionBindings)) {
            $level = Get-RoleRank -RoleName $rdb.Name
            if ($level -gt $max) { $max = $level }
        }
    }
    return $max
}

<#
.DESCRIPTION
Remonte la chaine d'heritage du dossier et renvoie le rang du droit le plus
eleve accorde au niveau du premier ancetre (ou de la racine du site) qui
possede des permissions uniques. C'est ce niveau que le sous-dossier herite
normalement. Rang 0 = inconnu / pas d'acces identifiable.
#>
function Get-EffectiveParentLevel {
    param([string]$FolderServerRelativeUrl)

    $url = Get-ParentFolderUrl -ServerRelativeUrl $FolderServerRelativeUrl
    $hops = 0
    while ($url -and $hops -lt 50) {
        $hops++
        try {
            $folder = Get-PnPFolder -Url $url -ErrorAction SilentlyContinue
            if ($folder) {
                $item = Get-PnPProperty -ClientObject $folder -Property ListItemAllFields
                $null = Get-PnPProperty -ClientObject $item -Property HasUniqueRoleAssignments
                if ($item.HasUniqueRoleAssignments) {
                    $ctx = Get-PnPContext
                    $ctx.Load($item.RoleAssignments)
                    try { $ctx.ExecuteQuery() } catch { }
                    return Get-MaxRoleLevelFromAssignments -RoleAssignments $item.RoleAssignments
                }
            }
        }
        catch { }
        $url = Get-ParentFolderUrl -ServerRelativeUrl $url
    }

    # Aucun ancetre avec permissions uniques : c'est la racine du site qui fixe le niveau
    try {
        $web = Get-PnPWeb -ErrorAction Stop
        $ctx = Get-PnPContext
        $ctx.Load($web.RoleAssignments)
        try { $ctx.ExecuteQuery() } catch { }
        return Get-MaxRoleLevelFromAssignments -RoleAssignments $web.RoleAssignments
    }
    catch { return 0 }
}

#------------------------------------------------------
# CREATION AUTOMATIQUE DES DOSSIERS MANQUANTS
#------------------------------------------------------

<#
.DESCRIPTION
Verifie que le dossier existe dans SharePoint et le cree si besoin (niveau par
niveau pour les chemins imbriques A/B/C). Necessaire pour les dossiers NOUVEAUX
(cree dans le visualiseur HTML ou ajoute a la configuration) : sans cela, le
script echouait avec "Dossier introuvable" et l'attribution ne partait pas.
#>
function Ensure-PnPFolder {
    param(
        [string]$LibraryName,
        [string]$FolderServerRelativeUrl
    )

    $Folder = Get-PnPFolder -Url $FolderServerRelativeUrl -ErrorAction SilentlyContinue
    if ($Folder) { return $Folder }

    Write-Log "Dossier '$FolderServerRelativeUrl' absent de SharePoint : creation automatique..." "WARN"

    $List = Get-PnPList $LibraryName -ErrorAction Stop
    $RootUrl = $List.RootFolder.ServerRelativeUrl.TrimEnd('/')
    $Relative = $FolderServerRelativeUrl.TrimEnd('/')
    if (-not $Relative.StartsWith($RootUrl, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Chemin hors de la bibliotheque '$LibraryName' : $FolderServerRelativeUrl"
    }

    $ParentUrl = $RootUrl
    foreach ($Segment in ($Relative.Substring($RootUrl.Length).TrimStart('/') -split '/')) {
        if ([string]::IsNullOrWhiteSpace($Segment)) { continue }
        $CurrentUrl = $ParentUrl.TrimEnd('/') + '/' + $Segment
        $Existing = Get-PnPFolder -Url $CurrentUrl -ErrorAction SilentlyContinue
        if (-not $Existing) {
            New-PnPFolder -Name $Segment -Folder $ParentUrl -ErrorAction Stop | Out-Null
            Write-Log "Dossier cree : $CurrentUrl" "SUCCESS"
        }
        $ParentUrl = $CurrentUrl
    }

    return (Get-PnPFolder -Url $FolderServerRelativeUrl -ErrorAction Stop)
}

#------------------------------------------------------
# FONCTION ATTRIBUTION PERMISSION
#------------------------------------------------------

function Set-FolderPermission {
    param(
        [string]$LibraryName,
        [string]$FolderPath,
        [string]$GroupName,
        [string]$RoleName,
        [string]$Access = "Grant"
    )

    try {
        # "Deny"/"Remove"/"None" = RETIRER tout acces du groupe -> le dossier devient masque pour lui
        $IsDeny = $Access -match '^(Deny|Remove|None|Refuser|Retirer|Masquer|Supprimer)$'
        $Label  = if ($IsDeny) { "RETRAIT d'acces (masquage)" } else { $RoleName }
        Write-Log "Traitement : $LibraryName / $FolderPath -> $GroupName [$Label]"

        $FolderServerRelativeUrl =
            ((Get-PnPList $LibraryName -ErrorAction Stop).RootFolder.ServerRelativeUrl) +
            "/" + $FolderPath

        $Folder = Ensure-PnPFolder -LibraryName $LibraryName -FolderServerRelativeUrl $FolderServerRelativeUrl

        $ListItem = Get-PnPProperty -ClientObject $Folder -Property ListItemAllFields
        $null = Get-PnPProperty -ClientObject $ListItem -Property HasUniqueRoleAssignments

        # La rupture d'heritage est geree SEPAREMENT pour chaque branche :
        # - branche Masquage (Deny) : rupture + copie pour pouvoir retirer l'acces ;
        # - branche Attribution : 3 phases de securite (conflit -> rupture -> application).

        #==================================
        # Validation du principal : groupe Entra ID D'ABORD, puis groupe SharePoint,
        # puis utilisateur Entra ID (dernier recours - exige User.Read.All)
        #==================================
        $AADGroup = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue
        $AADUser  = $null
        $SPGroup  = $null
        # Identite a transmettre a SharePoint : le nom du groupe SharePoint fonctionne
        # tel quel, le nom du groupe Entra aussi. Un utilisateur individuel doit etre
        # identifie par email/UPN (plus fiable qu'un simple nom affiche).
        $SharePointIdentity = $GroupName

        if ($AADGroup) {
            Write-Log "Groupe Entra ID valide : $GroupName ($($AADGroup.Id))"
        }
        else {
            # Groupe deja present dans le site SharePoint (ex : "Proprietaires de L'AGENCE X",
            # "Membres de ...", groupes personnalises) -> aucun appel Graph necessaire.
            try {
                $SPGroup = Get-PnPGroup | Where-Object { $_.Title -ieq $GroupName } | Select-Object -First 1
                if ($SPGroup) {
                    Write-Log "Groupe SharePoint valide (aucun appel Graph) : $GroupName"
                }
            }
            catch {
                $SPGroup = $null
            }

            if (-not $SPGroup) {
                try {
                    $AADUser = Get-MgUser -Filter "displayName eq '$GroupName'" -ErrorAction Stop | Select-Object -First 1
                    if (-not $AADUser) {
                        $AADUser = Get-MgUser -Filter "mail eq '$GroupName' or userPrincipalName eq '$GroupName'" -ErrorAction Stop | Select-Object -First 1
                    }
                }
                catch {
                    if ($_.Exception.Message -match 'Authorization_RequestDenied|Insufficient privileges') {
                        throw "Droits Graph insuffisants pour rechercher '$GroupName' comme utilisateur individuel : il manque la permission d'API 'User.Read.All' (Application, avec consentement admin) sur l'App Registration Entra ID. Voir README-INSTALLATION.md, etape 2b."
                    }
                    throw
                }
                if (-not $AADUser) { throw "Principal introuvable (ni groupe Entra, ni groupe SharePoint, ni utilisateur) : $GroupName" }
                $SharePointIdentity = if ($AADUser.Mail) { $AADUser.Mail } else { $AADUser.UserPrincipalName }
                Write-Log "Utilisateur Entra ID valide : $GroupName ($SharePointIdentity)"
            }
        }

        if ($IsDeny) {
            #==================================
            # RETRAIT : le principal ne doit PLUS avoir acces -> dossier masque
            #==================================
            # Rupture d'heritage (avec copie des droits existants) : indispensable
            # pour pouvoir retirer l'acces ici sans modifier le parent.
            if (-not $ListItem.HasUniqueRoleAssignments) {
                Write-Log "Masquage : rupture d'heritage sur $FolderPath (droits existants copies, le parent reste inchange)"
                $ListItem.BreakRoleInheritance($true, $true)
                Invoke-PnPQuery
            }
            # On retrouve le principal SharePoint : par nom affiche, par l'identifiant
            # Entra du groupe (present dans le LoginName base sur les claims), ou par
            # l'identifiant/email de l'utilisateur individuel.
            $spUser = Get-PnPUser | Where-Object {
                ($_.Title -ieq $GroupName) -or
                ($AADGroup.Id -and $_.LoginName -like "*$($AADGroup.Id)*") -or
                ($SPGroup.Id -and $_.LoginName -like "*$($SPGroup.Id)*") -or
                ($AADUser -and $_.LoginName -like "*$($AADUser.Id)*") -or
                ($AADUser -and $AADUser.Mail -and $_.Email -ieq $AADUser.Mail)
            } | Select-Object -First 1

            if ($spUser) {
                $ctx = Get-PnPContext
                try {
                    $ra = $ListItem.RoleAssignments.GetByPrincipalId($spUser.Id)
                    $ra.DeleteObject()
                    $ctx.ExecuteQuery()
                    Write-Log "OK : acces RETIRE pour '$GroupName' sur '$FolderPath' -> dossier MASQUE pour ce groupe" "SUCCESS"
                }
                catch {
                    Write-Log "OK : '$GroupName' n'avait deja aucun acces direct sur '$FolderPath' -> dossier MASQUE" "SUCCESS"
                }
            }
            else {
                Write-Log "OK : '$GroupName' absent des utilisateurs du site -> aucun acces sur '$FolderPath' (masque)" "SUCCESS"
            }
        }
        else {
            #==================================
            # ATTRIBUTION — 3 phases de securite
            #==================================
            $RealRole = Resolve-RoleName -Requested $RoleName
            if (-not $RealRole) {
                throw "Niveau d'autorisation introuvable : '$RoleName' (voir la liste ci-dessus)"
            }
            if ($RealRole -ne $RoleName) {
                Write-Log "Niveau '$RoleName' traduit en '$RealRole' (nom reel du site)"
            }

            $RequestedLevel = Get-RoleRank -RoleName $RealRole

            # PHASE 1 : verifier si l'element herite des permissions du parent
            if (-not $ListItem.HasUniqueRoleAssignments) {
                # PHASE 2 : detecter le conflit puis rompre l'heritage (rupture systematique)
                $ParentLevel = Get-EffectiveParentLevel -FolderServerRelativeUrl $FolderServerRelativeUrl

                if ($ParentLevel -gt 0 -and $ParentLevel -lt $RequestedLevel) {
                    Write-Log "CONFLIT D'HERITAGE DETECTE : le parent accorde un niveau inferieur (rang $ParentLevel) au droit demande '$RealRole' (rang $RequestedLevel) -> rupture d'heritage OBLIGATOIRE sur $FolderPath" "WARN"
                    Write-Log "Le droit du parent est conserve (copie des permissions) : la navigation jusqu'a $FolderPath reste possible." "INFO"
                }
                else {
                    Write-Log "Permissions heritees : rupture d'heritage systematique sur $FolderPath pour attribuer '$RealRole' (permissions du parent copiees)"
                }

                # Perimetre "minimum requis" : une personne doit au minimum lire le parent
                # (rang 4 = Lecture) pour pouvoir naviguer jusqu'au sous-dossier.
                if ($ParentLevel -lt 4) {
                    Write-Log "Attention : le parent est en dessous de la Lecture (rang $ParentLevel) - les utilisateurs pourraient ne pas voir ce dossier. Vérifiez l'acces au dossier parent." "WARN"
                }

                $ListItem.BreakRoleInheritance($true, $true)   # $true = COPIER les droits du parent (navigation conservee)
                Invoke-PnPQuery
                Write-Log "Rupture d'heritage effectuee : droits du parent copies sur $FolderPath (acces existants et navigation conserves)" "SUCCESS"
            }

            # Bloc d'application reutilise pour l'essai initial ET l'auto-correction
            $GrantBlock = {
                param($Library, $ItemId, $Group, $User, $Role)
                if ($Group) {
                    Set-PnPListItemPermission -List $Library -Identity $ItemId -Group $Group -AddRole $Role -ErrorAction Stop
                }
                else {
                    Set-PnPListItemPermission -List $Library -Identity $ItemId -User $User -AddRole $Role -ErrorAction Stop
                }
            }

            # PHASE 3 : appliquer le droit 'Write/Edit', avec auto-correction en cas d'echec
            try {
                & $GrantBlock -Library $LibraryName -ItemId $ListItem.Id -Group $SPGroup -User $SharePointIdentity -Role $RealRole
                Write-Log "OK : role '$RealRole' attribue a '$GroupName' sur '$FolderPath'" "SUCCESS"
            }
            catch {
                $GrantError = $_.Exception.Message
                Write-Log "Echec de l'attribution '$RealRole' pour '$GroupName' sur '$FolderPath' : $GrantError" "WARN"

                # AUTO-CORRECTION : verifier le statut d'heritage, rompre, puis RE-ESSAYER
                try {
                    $null = Get-PnPProperty -ClientObject $ListItem -Property HasUniqueRoleAssignments
                    if ($ListItem.HasUniqueRoleAssignments) {
                        throw "L'element possede deja des permissions uniques : cette erreur n'est pas liee a l'heritage ($GrantError)"
                    }
                    Write-Log "AUTO-CORRECTION : heritage encore actif sur $FolderPath -> rupture d'heritage puis nouvel essai d'attribution..." "WARN"
                    $ListItem.BreakRoleInheritance($true, $true)
                    Invoke-PnPQuery
                    & $GrantBlock -Library $LibraryName -ItemId $ListItem.Id -Group $SPGroup -User $SharePointIdentity -Role $RealRole
                    Write-Log "OK (apres auto-correction) : role '$RealRole' attribue a '$GroupName' sur '$FolderPath'" "SUCCESS"
                }
                catch {
                    throw   # l'echec final remonte au catch exterieur (ECHEC + compteur)
                }
            }
        }

        $script:CountOk++
    }
    catch {
        Write-Log "ECHEC sur '$FolderPath' / '$GroupName' : $($_.Exception.Message)" "ERROR"
        $script:CountError++
    }
}

#------------------------------------------------------
# MODE EXCLUSIF : rendre un dossier PRIVE (retire les groupes herites du site)
# Active par "ResetPermissions": true sur l'entree du dossier.
#------------------------------------------------------
function Reset-FolderToExclusive {
    param([string]$LibraryName, [string]$FolderPath)
    try {
        $url = ((Get-PnPList $LibraryName -ErrorAction Stop).RootFolder.ServerRelativeUrl) + "/" + $FolderPath
        $folder = Ensure-PnPFolder -LibraryName $LibraryName -FolderServerRelativeUrl $url
        $li = Get-PnPProperty -ClientObject $folder -Property ListItemAllFields
        $null = Get-PnPProperty -ClientObject $li -Property HasUniqueRoleAssignments
        $ctx = Get-PnPContext
        # Repartir propre : restaurer l'heritage puis rompre SANS copier
        if ($li.HasUniqueRoleAssignments) {
            $li.ResetRoleInheritance()
            $ctx.ExecuteQuery()
        }
        $li.BreakRoleInheritance($false, $true)   # $false = ne PAS copier -> retire Membres/Visiteurs du site
        $ctx.ExecuteQuery()
        Write-Log "Mode EXCLUSIF sur '$FolderPath' : dossier remis a zero (seuls les groupes listes + admins auront acces)"
    }
    catch {
        Write-Log "Mode exclusif impossible sur '$FolderPath' : $($_.Exception.Message)" "WARN"
    }
}

#------------------------------------------------------
# RAPPORT : liste QUI a acces au dossier (pour verification depuis le log)
#------------------------------------------------------
function Show-FolderAccess {
    param([string]$LibraryName, [string]$FolderPath)
    try {
        $url = ((Get-PnPList $LibraryName -ErrorAction Stop).RootFolder.ServerRelativeUrl) + "/" + $FolderPath
        $folder = Ensure-PnPFolder -LibraryName $LibraryName -FolderServerRelativeUrl $url
        $li = Get-PnPProperty -ClientObject $folder -Property ListItemAllFields
        $null = Get-PnPProperty -ClientObject $li -Property HasUniqueRoleAssignments
        $ctx = Get-PnPContext
        $ctx.Load($li.RoleAssignments)
        $ctx.ExecuteQuery()
        Write-Log "Acces effectifs sur '$FolderPath' (herite=$(-not $li.HasUniqueRoleAssignments)) :"
        foreach ($ra in $li.RoleAssignments) {
            $ctx.Load($ra.Member)
            $ctx.Load($ra.RoleDefinitionBindings)
            $ctx.ExecuteQuery()
            $roles = ($ra.RoleDefinitionBindings | ForEach-Object { $_.Name }) -join ', '
            Write-Log "   - $($ra.Member.Title) [$($ra.Member.PrincipalType)] : $roles"
        }
    }
    catch {
        Write-Log "Lecture des acces de '$FolderPath' impossible : $($_.Exception.Message)" "WARN"
    }
}

#------------------------------------------------------
# NORMALISATION CONFIG / ARCHITECTURE
#------------------------------------------------------

function Get-JsonValue {
    param([object]$Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($Name in $Names) {
        $Prop = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
        if ($Prop -and $null -ne $Prop.Value) { return $Prop.Value }
    }
    return $null
}

function Test-DenyAccessValue {
    param([string]$Access)
    return $Access -match '^(Deny|Remove|None|Refuser|Retirer|Masquer|Supprimer)$'
}

function Test-GrantAccessValue {
    param([string]$Access)
    return ([string]::IsNullOrWhiteSpace($Access) -or $Access -match '^(Grant|Allow|Autoriser|Donner|Ajouter|Accorder)$')
}

function Get-FirstRoleFromPermission {
    param([object]$Permission)

    $Role = Get-JsonValue -Object $Permission -Names @('Role', 'role')
    if (-not [string]::IsNullOrWhiteSpace([string]$Role)) { return [string]$Role }

    $Roles = Get-JsonValue -Object $Permission -Names @('Roles', 'roles')
    foreach ($Item in @($Roles)) {
        $Value = [string]$Item
        if (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -notmatch '^(Acces limite|Accès limité|Limited Access)$') {
            return $Value
        }
    }

    return $null
}

function Resolve-AssignmentIntent {
    param([object]$Assignment)

    $GroupName = [string](Get-JsonValue -Object $Assignment -Names @('GroupName', 'Principal', 'Name', 'DisplayName'))
    $RoleName  = [string](Get-JsonValue -Object $Assignment -Names @('Role', 'role'))
    $Access    = [string](Get-JsonValue -Object $Assignment -Names @('Access', 'access'))

    if ([string]::IsNullOrWhiteSpace($Access)) {
        $Access = 'Grant'
    }
    elseif (Test-DenyAccessValue -Access $Access) {
        $Access = 'Deny'
        $RoleName = $null
    }
    elseif (Test-GrantAccessValue -Access $Access) {
        $Access = 'Grant'
    }
    elseif ([string]::IsNullOrWhiteSpace($RoleName)) {
        # Compatibilite avec les exports qui mettent directement le role dans access.
        $RoleName = $Access
        $Access = 'Grant'
    }
    else {
        $Access = 'Grant'
    }

    if ([string]::IsNullOrWhiteSpace($GroupName)) { return $null }
    if ($Access -ne 'Deny' -and [string]::IsNullOrWhiteSpace($RoleName)) { return $null }

    return [pscustomobject]@{
        GroupName = $GroupName.Trim()
        Role      = if ($RoleName) { $RoleName.Trim() } else { $null }
        Access    = $Access
    }
}

function Convert-ArchitectureToPermissionEntries {
    param([object]$Architecture)

    $Entries = [System.Collections.Generic.List[object]]::new()
    $ModifiedKeys = @{}
    foreach ($Modified in @($Architecture.PermissionEditor.ModifiedFolders)) {
        $Library = [string](Get-JsonValue -Object $Modified -Names @('Library', 'library'))
        $Path    = [string](Get-JsonValue -Object $Modified -Names @('FolderPath', 'folderPath', 'Path', 'path'))
        if (-not [string]::IsNullOrWhiteSpace($Library) -and -not [string]::IsNullOrWhiteSpace($Path)) {
            $ModifiedKeys[($Library.Trim().ToLowerInvariant() + '|' + $Path.Trim().ToLowerInvariant())] = $true
        }
    }
    $UseModifiedFilter = $ModifiedKeys.Count -gt 0

    function Visit-ArchitectureFolder {
        param([object]$Folder, [string]$LibraryName, [string]$ParentPath)

        $Name = [string](Get-JsonValue -Object $Folder -Names @('Name', 'name'))
        if ([string]::IsNullOrWhiteSpace($Name)) { return }

        $FolderPath = if ([string]::IsNullOrWhiteSpace($ParentPath)) { $Name.Trim() } else { $ParentPath + '/' + $Name.Trim() }
        $Key = $LibraryName.Trim().ToLowerInvariant() + '|' + $FolderPath.Trim().ToLowerInvariant()
        $RawPermissions = Get-JsonValue -Object $Folder -Names @('Permissions', 'permissions')
        $Permissions = if ($null -eq $RawPermissions) { @() } else { @($RawPermissions) }
        $HasExplicitAccess = $false
        foreach ($Permission in $Permissions) {
            if (-not [string]::IsNullOrWhiteSpace([string](Get-JsonValue -Object $Permission -Names @('Access', 'access')))) {
                $HasExplicitAccess = $true
                break
            }
        }

        $ShouldInclude = if ($UseModifiedFilter) { $ModifiedKeys.ContainsKey($Key) } else { $HasExplicitAccess }
        if ($ShouldInclude) {
            $Assignments = [System.Collections.Generic.List[object]]::new()
            foreach ($Permission in $Permissions) {
                $Principal = [string](Get-JsonValue -Object $Permission -Names @('Principal', 'GroupName', 'Name', 'DisplayName'))
                $Role = Get-FirstRoleFromPermission -Permission $Permission
                $Access = [string](Get-JsonValue -Object $Permission -Names @('Access', 'access'))
                $Intent = Resolve-AssignmentIntent -Assignment ([pscustomobject]@{ GroupName = $Principal; Role = $Role; Access = $Access })
                if ($Intent) { [void]$Assignments.Add($Intent) }
            }

            $Reset = [bool](Get-JsonValue -Object $Folder -Names @('ResetPermissions', 'resetPermissions'))
            # On conserve aussi les dossiers "reset" sans assignation (droits entierement retires)
            if ($Assignments.Count -gt 0 -or $Reset) {
                [void]$Entries.Add([pscustomobject]@{
                    Library          = $LibraryName
                    FolderPath       = $FolderPath
                    ResetPermissions = $Reset
                    Assignments      = @($Assignments)
                })
            }
        }

        foreach ($Child in @($Folder.Dossiers)) {
            Visit-ArchitectureFolder -Folder $Child -LibraryName $LibraryName -ParentPath $FolderPath
        }
    }

    foreach ($Library in @($Architecture.Bibliotheques)) {
        $LibraryName = [string](Get-JsonValue -Object $Library -Names @('Name', 'Title', 'Library'))
        if ([string]::IsNullOrWhiteSpace($LibraryName)) { $LibraryName = 'Documents' }
        foreach ($Folder in @($Library.Dossiers)) {
            Visit-ArchitectureFolder -Folder $Folder -LibraryName $LibraryName.Trim() -ParentPath ''
        }
    }

    return @($Entries)
}

function Normalize-PermissionConfig {
    param([object]$Config)

    $RawPermissions = Get-JsonValue -Object $Config -Names @('Permissions', 'permissions')
    $Permissions = if ($null -eq $RawPermissions) { @() } else { @($RawPermissions) }
    if (($Permissions.Count -eq 0) -and $Config.Bibliotheques) {
        $Permissions = Convert-ArchitectureToPermissionEntries -Architecture $Config
        Write-Log "JSON d'architecture detecte : $($Permissions.Count) dossier(s) converti(s) en configuration applicable."
    }

    $Normalized = [System.Collections.Generic.List[object]]::new()
    foreach ($Entry in $Permissions) {
        $Library = [string](Get-JsonValue -Object $Entry -Names @('Library', 'library'))
        $FolderPath = [string](Get-JsonValue -Object $Entry -Names @('FolderPath', 'folderPath', 'Path', 'path'))
        if ([string]::IsNullOrWhiteSpace($Library) -or [string]::IsNullOrWhiteSpace($FolderPath)) { continue }

        $Assignments = [System.Collections.Generic.List[object]]::new()
        foreach ($Assignment in @($Entry.Assignments)) {
            $Intent = Resolve-AssignmentIntent -Assignment $Assignment
            if ($Intent) { [void]$Assignments.Add($Intent) }
        }

        $Reset = [bool](Get-JsonValue -Object $Entry -Names @('ResetPermissions', 'resetPermissions'))
        # On conserve aussi les entrees "reset" sans assignation (dossier vide/remis a zero)
        if ($Assignments.Count -gt 0 -or $Reset) {
            [void]$Normalized.Add([pscustomobject]@{
                Library          = $Library.Trim()
                FolderPath       = $FolderPath.Trim()
                ResetPermissions = $Reset
                Assignments      = @($Assignments)
            })
        }
    }

    if ($Config.PSObject.Properties['Permissions']) {
        $Config.Permissions = @($Normalized)
    }
    else {
        $Config | Add-Member -NotePropertyName Permissions -NotePropertyValue @($Normalized)
    }

    return $Config
}

$Config = Normalize-PermissionConfig -Config $Config
if (-not $Config.Permissions -or @($Config.Permissions).Count -eq 0) {
    Write-Log "Aucune permission applicable trouvee dans le JSON. Exportez une configuration ou une architecture modifiee avec la cle Access." "ERROR"
    exit 1
}
#------------------------------------------------------
# TRAITEMENT
#------------------------------------------------------

foreach ($Entry in $Config.Permissions) {

    Write-Log "--------------------------------"
    Write-Log "Bibliotheque : $($Entry.Library) | Dossier : $($Entry.FolderPath)"

    # Option : rendre le dossier PRIVE (retire les groupes du site) avant d'ajouter les groupes listes
    if ($Entry.ResetPermissions) {
        Reset-FolderToExclusive -LibraryName $Entry.Library -FolderPath $Entry.FolderPath
    }

    foreach ($Assignment in $Entry.Assignments) {
        $access = if ($Assignment.Access) { $Assignment.Access } else { "Grant" }
        Set-FolderPermission `
            -LibraryName $Entry.Library `
            -FolderPath  $Entry.FolderPath `
            -GroupName   $Assignment.GroupName `
            -RoleName    $Assignment.Role `
            -Access      $access
    }

    # Rapport de verification : qui a acces a ce dossier apres traitement
    Show-FolderAccess -LibraryName $Entry.Library -FolderPath $Entry.FolderPath
}

#------------------------------------------------------
# DECONNEXION
#------------------------------------------------------

try { Disconnect-PnPOnline } catch { }
try { Disconnect-MgGraph | Out-Null } catch { }

#------------------------------------------------------
# BILAN FINAL (pour savoir si "ca a marche")
#------------------------------------------------------

Write-Log "================================"
Write-Log "BILAN : $script:CountOk attribution(s) reussie(s), $script:CountError echec(s)" $(if ($script:CountError -gt 0) { "WARN" } else { "SUCCESS" })
Write-Log "Journal complet : $LogFile"
Write-Log "Traitement termine"

# Code de sortie exploitable par une tache planifiee (0 = OK, 2 = erreurs partielles)
if ($script:CountError -gt 0) { exit 2 } else { exit 0 }
