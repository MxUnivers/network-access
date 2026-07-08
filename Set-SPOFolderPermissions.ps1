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
    "Microsoft.Graph.Groups"
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

    # Save-PSResource ecrit directement dans un dossier cible, sans passer par Documents.
    # -SkipDependencyCheck : les dependances sont deja listees dans $RequiredModules (ordre : Authentication
    # avant Groups), on evite ainsi de reecrire un module deja importe et verrouille.
    Save-PSResource -Name $Name -Path $ModulesDir -TrustRepository -IncludeXml -SkipDependencyCheck -ErrorAction Stop
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

    # Validation des champs obligatoires
    if (-not $Config.SiteUrl)          { throw "Champ 'SiteUrl' manquant dans la configuration" }
    if (-not $Config.Auth)             { throw "Section 'Auth' manquante dans la configuration" }
    if (-not $Config.Auth.TenantId)    { throw "Champ 'Auth.TenantId' manquant" }
    if (-not $Config.Auth.ClientId)    { throw "Champ 'Auth.ClientId' manquant" }

    $HasThumbprint = -not [string]::IsNullOrWhiteSpace($Config.Auth.CertificateThumbprint)
    $HasCertPath   = -not [string]::IsNullOrWhiteSpace($Config.Auth.CertificatePath)

    if (-not $HasThumbprint -and -not $HasCertPath) {
        throw "Aucun certificat : renseignez 'CertificateThumbprint' OU 'CertificatePath' dans la section Auth"
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
# FONCTION ATTRIBUTION PERMISSION
#------------------------------------------------------

function Set-FolderPermission {
    param(
        [string]$LibraryName,
        [string]$FolderPath,
        [string]$GroupName,
        [string]$RoleName
    )

    try {
        Write-Log "Traitement : $LibraryName / $FolderPath -> $GroupName ($RoleName)"

        $FolderServerRelativeUrl =
            ((Get-PnPList $LibraryName -ErrorAction Stop).RootFolder.ServerRelativeUrl) +
            "/" + $FolderPath

        $Folder = Get-PnPFolder -Url $FolderServerRelativeUrl -ErrorAction Stop
        if (-not $Folder) { throw "Dossier introuvable : $FolderPath" }

        $ListItem = Get-PnPProperty -ClientObject $Folder -Property ListItemAllFields

        #==================================
        # Rupture d'heritage
        #==================================
        if (-not $ListItem.HasUniqueRoleAssignments) {
            Write-Log "Rupture d'heritage des permissions sur $FolderPath"
            $ListItem.BreakRoleInheritance($true, $true)
            Invoke-PnPQuery
        }

        #==================================
        # Validation du groupe Entra ID
        #==================================
        $AADGroup = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction Stop
        if (-not $AADGroup) { throw "Groupe Entra ID introuvable : $GroupName" }
        Write-Log "Groupe Entra ID valide : $GroupName ($($AADGroup.Id))"

        #==================================
        # Resolution du niveau d'autorisation
        #==================================
        $RealRole = Resolve-RoleName -Requested $RoleName
        if (-not $RealRole) {
            throw "Niveau d'autorisation introuvable : '$RoleName' (voir la liste ci-dessus)"
        }
        if ($RealRole -ne $RoleName) {
            Write-Log "Niveau '$RoleName' traduit en '$RealRole' (nom reel du site)"
        }

        #==================================
        # Attribution de la permission
        #==================================
        Set-PnPListItemPermission `
            -List $LibraryName `
            -Identity $ListItem.Id `
            -User $GroupName `
            -AddRole $RealRole `
            -ErrorAction Stop

        Write-Log "OK : role '$RealRole' attribue a '$GroupName' sur '$FolderPath'" "SUCCESS"
        $script:CountOk++
    }
    catch {
        Write-Log "ECHEC sur '$FolderPath' / '$GroupName' : $($_.Exception.Message)" "ERROR"
        $script:CountError++
    }
}

#------------------------------------------------------
# TRAITEMENT
#------------------------------------------------------

foreach ($Entry in $Config.Permissions) {

    Write-Log "--------------------------------"
    Write-Log "Bibliotheque : $($Entry.Library) | Dossier : $($Entry.FolderPath)"

    foreach ($Assignment in $Entry.Assignments) {
        Set-FolderPermission `
            -LibraryName $Entry.Library `
            -FolderPath  $Entry.FolderPath `
            -GroupName   $Assignment.GroupName `
            -RoleName    $Assignment.Role
    }
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
