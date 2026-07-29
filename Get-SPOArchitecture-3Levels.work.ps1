<#
.SYNOPSIS
Recupere une architecture SharePoint limitee a trois niveaux de dossiers,
sans recuperer les fichiers.

.DESCRIPTION
Authentification app-only par certificat (memes infos que PermissionsConfig.json).
Le resultat reste compatible avec le visualiseur : Site + Bibliotheques + Dossiers.
Les sorties portent le prefixe architecture-3-niveaux pour ne pas ecraser
l'architecture complete.

.EXEMPLE
.\Get-SPOArchitecture-3Levels.ps1
.\Get-SPOArchitecture-3Levels.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/AutreSite"
#>

param(
    [string]$ConfigFile,
    [string]$SiteUrl,
    [string]$OutputDir,        # dossier de sortie (par defaut : architecture\<NomDuSite>)
    [switch]$SansPermissions   # plus rapide : n'exporte pas les permissions par dossier
)

#------------------------------------------------------
# GARDE-FOU : PowerShell 7 obligatoire
#------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ""
    Write-Host "  Ce script exige PowerShell 7. Double-cliquez sur 4-Recuperer-Architecture-3-Niveaux.cmd" -ForegroundColor Red
    Write-Host ""
    exit 1
}

$ErrorActionPreference = "Stop"

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $ConfigFile = Join-Path $ScriptRoot "PermissionsConfig.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile = Join-Path $ScriptRoot $ConfigFile
}

function Info ($m) { Write-Host "  $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "  $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Format-Duration {
    param([TimeSpan]$Duration)

    if ($Duration.TotalHours -ge 1) {
        return "{0}h {1}min" -f [math]::Floor($Duration.TotalHours), $Duration.Minutes
    }
    if ($Duration.TotalMinutes -ge 1) {
        return "{0}min {1}s" -f [math]::Floor($Duration.TotalMinutes), $Duration.Seconds
    }
    return "{0}s" -f [math]::Max(0, [math]::Round($Duration.TotalSeconds))
}
function Show-ArchitectureProgress {
    param(
        [double]$Percent,
        [string]$Stage,
        [int]$LibraryIndex = 0,
        [int]$LibraryTotal = 0,
        [int]$RemainingFolders = 0,
        [int]$RemainingFiles = 0,
        [datetime]$StartedAt
    )

    $Percent = [math]::Max(0, [math]::Min(100, $Percent))
    $Elapsed = (Get-Date) - $StartedAt
    $RemainingText = "calcul en cours"
    $EtaText = "calcul en cours"

    if ($Percent -gt 0.5) {
        $TotalSeconds = $Elapsed.TotalSeconds / ($Percent / 100)
        $Remaining = [TimeSpan]::FromSeconds([math]::Max(0, $TotalSeconds - $Elapsed.TotalSeconds))
        $FinishAt = (Get-Date).Add($Remaining)
        $RemainingText = Format-Duration $Remaining
        $EtaText = $FinishAt.ToString("HH:mm:ss")
    }

    $LibText = if ($LibraryTotal -gt 0) { "bibliotheque $LibraryIndex/$LibraryTotal" } else { "initialisation" }
    $RestText = if ($LibraryTotal -gt 0) {
        $RemainingLibraries = [math]::Max(0, $LibraryTotal - $LibraryIndex)
        "reste: $RemainingLibraries bibliotheque(s), $RemainingFolders dossier(s), $RemainingFiles fichier(s)"
    }
    else {
        "reste: estimation apres lecture des bibliotheques"
    }

    Write-Output ("  [PROGRESSION] {0,6:N1}% | {1} | {2} | {3} | ecoule: {4} | restant estime: {5} | fin estimee: {6}" -f `
        $Percent, $LibText, $Stage, $RestText, (Format-Duration $Elapsed), $RemainingText, $EtaText)
}

Write-Host "`n=== RECUPERATION DE L'ARCHITECTURE ===`n" -ForegroundColor White
$ProgressStartedAt = Get-Date
Show-ArchitectureProgress -Percent 0 -Stage "demarrage" -StartedAt $ProgressStartedAt

#------------------------------------------------------
# MODULES (hors dossiers proteges par Controlled Folder Access)
#------------------------------------------------------
$ModulesDir = Join-Path $env:LOCALAPPDATA "SPO-Automation\Modules"
if (-not (Test-Path $ModulesDir)) { New-Item -ItemType Directory -Path $ModulesDir -Force | Out-Null }
if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $ModulesDir) {
    $env:PSModulePath = $ModulesDir + [IO.Path]::PathSeparator + $env:PSModulePath
}
if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    Info "Installation du module PnP.PowerShell ..."
    Save-PSResource -Name PnP.PowerShell -Path $ModulesDir -TrustRepository -IncludeXml -SkipDependencyCheck -ErrorAction Stop
}
Import-Module PnP.PowerShell -ErrorAction Stop
Ok "Module PnP.PowerShell charge"
Show-ArchitectureProgress -Percent 5 -Stage "module charge" -StartedAt $ProgressStartedAt

#------------------------------------------------------
# CONFIGURATION + CONNEXION
#------------------------------------------------------
$Config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
$Auth   = $Config.Auth
if ([string]::IsNullOrWhiteSpace($SiteUrl)) { $SiteUrl = $Config.SiteUrl }
$ConfigDir = Split-Path -Parent $ConfigFile

if (-not $Config.SiteUrl -and [string]::IsNullOrWhiteSpace($SiteUrl)) { throw "Champ 'SiteUrl' manquant dans la configuration" }
if (-not $Auth)          { throw "Section 'Auth' manquante dans la configuration" }
if (-not $Auth.TenantId) { throw "Champ 'Auth.TenantId' manquant" }
if (-not $Auth.ClientId) { throw "Champ 'Auth.ClientId' manquant" }

$HasThumbprint = -not [string]::IsNullOrWhiteSpace($Auth.CertificateThumbprint)
$HasCertPath   = -not [string]::IsNullOrWhiteSpace($Auth.CertificatePath)

if ($HasCertPath -and -not [System.IO.Path]::IsPathRooted($Auth.CertificatePath)) {
    $Auth.CertificatePath = Join-Path $ConfigDir $Auth.CertificatePath
}

if (-not $HasThumbprint -and -not $HasCertPath) {
    throw "Aucun certificat : renseignez 'CertificateThumbprint' OU 'CertificatePath' dans la section Auth"
}

if (-not $HasThumbprint -and $HasCertPath -and -not (Test-Path $Auth.CertificatePath)) {
    throw "Fichier certificat introuvable : $($Auth.CertificatePath)"
}

try {
    $PnpParams = @{
        Url         = $SiteUrl
        ClientId    = $Auth.ClientId
        Tenant      = $Auth.TenantId
        ErrorAction = "Stop"
    }

    if ($HasThumbprint) {
        $PnpParams.Thumbprint = $Auth.CertificateThumbprint
    }
    else {
        $PnpParams.CertificatePath     = $Auth.CertificatePath
        $PnpParams.CertificatePassword = (ConvertTo-SecureString ([string]$Auth.CertificatePassword) -AsPlainText -Force)
    }

    Connect-PnPOnline @PnpParams
    $web = Get-PnPWeb -ErrorAction Stop
    Ok "Connecte : $($web.Title) [$($web.Url)]"
    Show-ArchitectureProgress -Percent 10 -Stage "connexion SharePoint reussie" -StartedAt $ProgressStartedAt
}
catch {
    Warn "Connexion impossible : $($_.Exception.Message)"
    exit 1
}

#------------------------------------------------------
# HELPER : permissions d'un element (dossier)
#------------------------------------------------------
$script:PrincipalMembersCache = @{}

function Convert-PrincipalMember {
    param($Member)
    [ordered]@{
        Name              = if ($Member.Title) { "$($Member.Title)" } elseif ($Member.DisplayName) { "$($Member.DisplayName)" } else { "" }
        Email             = if ($Member.Email) { "$($Member.Email)" } elseif ($Member.UserPrincipalName) { "$($Member.UserPrincipalName)" } else { "" }
        LoginName         = if ($Member.LoginName) { "$($Member.LoginName)" } else { "" }
        UserPrincipalName = if ($Member.UserPrincipalName) { "$($Member.UserPrincipalName)" } else { "" }
        Type              = if ($Member.PrincipalType) { "$($Member.PrincipalType)" } elseif ($Member.'@odata.type') { "$($Member.'@odata.type')" } else { "" }
    }
}

function Get-PrincipalMembers {
    param(
        [string]$PrincipalTitle,
        [string]$PrincipalType
    )
    if ([string]::IsNullOrWhiteSpace($PrincipalTitle)) { return @() }

    $cacheKey = "$PrincipalType|$PrincipalTitle"
    if ($script:PrincipalMembersCache.ContainsKey($cacheKey)) {
        return $script:PrincipalMembersCache[$cacheKey]
    }

    $members = @()
    try {
        if ($PrincipalType -like "*SharePointGroup*" -and (Get-Command Get-PnPGroupMember -ErrorAction SilentlyContinue)) {
            $members = @(Get-PnPGroupMember -Identity $PrincipalTitle -ErrorAction Stop | ForEach-Object { Convert-PrincipalMember $_ })
        }
        elseif ($PrincipalType -like "*SecurityGroup*" -and
            (Get-Command Get-PnPAzureADGroup -ErrorAction SilentlyContinue) -and
            (Get-Command Get-PnPAzureADGroupMember -ErrorAction SilentlyContinue)) {
            $group = Get-PnPAzureADGroup -Identity $PrincipalTitle -ErrorAction Stop
            if ($group) {
                $groupId = if ($group.Id) { $group.Id } else { $PrincipalTitle }
                $members = @(Get-PnPAzureADGroupMember -Identity $groupId -ErrorAction Stop | ForEach-Object { Convert-PrincipalMember $_ })
            }
        }
    }
    catch {
        $members = @()
    }

    $script:PrincipalMembersCache[$cacheKey] = $members
    return $members
}

function Get-ItemPermissions {
    param($Item)
    $ctx = Get-PnPContext
    $unique = Get-PnPProperty -ClientObject $Item -Property HasUniqueRoleAssignments
    $perms = @()
    if ($unique) {
        $ras = Get-PnPProperty -ClientObject $Item -Property RoleAssignments
        foreach ($ra in $ras) {
            $ctx.Load($ra.Member)
            $ctx.Load($ra.RoleDefinitionBindings)
            $ctx.ExecuteQuery()
            $roles = @($ra.RoleDefinitionBindings | ForEach-Object { $_.Name })
            $principalType = "$($ra.Member.PrincipalType)"
            $principalTitle = "$($ra.Member.Title)"
            $perms += [ordered]@{
                Principal = $principalTitle
                Type      = $principalType
                Roles     = $roles
                Members   = @(Get-PrincipalMembers -PrincipalTitle $principalTitle -PrincipalType $principalType)
            }
        }
    }
    return [ordered]@{ HeritageRompu = [bool]$unique; Permissions = $perms }
}

$SitePermissionsInfo = [ordered]@{ HeritageRompu = $null; Permissions = @() }
if (-not $SansPermissions) {
    try {
        $SitePermissionsInfo = Get-ItemPermissions -Item $web
    }
    catch {
        Warn "Permissions du site non recuperees : $($_.Exception.Message)"
    }
}

#------------------------------------------------------
# PARCOURS DES BIBLIOTHEQUES : DOSSIERS NIVEAUX 1 A 3, SANS FICHIERS
#------------------------------------------------------
$MaxFolderDepth = 3

function Get-FolderDepth {
    param(
        [string]$LibraryRootUrl,
        [string]$FolderUrl
    )

    if ([string]::IsNullOrWhiteSpace($LibraryRootUrl) -or [string]::IsNullOrWhiteSpace($FolderUrl)) {
        return -1
    }

    $root = $LibraryRootUrl.TrimEnd('/')
    $folder = $FolderUrl.TrimEnd('/')
    if (-not ($folder.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or $folder.StartsWith($root + '/', [System.StringComparison]::OrdinalIgnoreCase))) {
        return -1
    }

    $relative = $folder.Substring($root.Length).Trim('/')
    if ([string]::IsNullOrWhiteSpace($relative)) { return 0 }
    return @($relative -split '/').Count
}

# La requete SharePoint filtre les fichiers cote serveur. Les dossiers plus
# profonds sont ensuite exclus avant la construction de l'objet exporte.
$FolderOnlyCaml = @"
<View Scope='RecursiveAll'>
  <ViewFields>
    <FieldRef Name='FileRef'/>
    <FieldRef Name='FileLeafRef'/>
    <FieldRef Name='Created'/>
    <FieldRef Name='Author'/>
    <FieldRef Name='Modified'/>
    <FieldRef Name='Editor'/>
    <FieldRef Name='FSObjType'/>
  </ViewFields>
  <Query>
    <Where>
      <Eq>
        <FieldRef Name='FSObjType'/>
        <Value Type='Integer'>1</Value>
      </Eq>
    </Where>
  </Query>
</View>
"@

$SkipLibs = @("Style Library", "Form Templates", "Site Assets", "Site Pages")
$libs = @(Get-PnPList | Where-Object { $_.BaseTemplate -eq 101 -and -not $_.Hidden -and ($SkipLibs -notcontains $_.Title) })
$TotalLibraries = $libs.Count
Show-ArchitectureProgress -Percent 12 -Stage "$TotalLibraries bibliotheque(s) a lire" -LibraryIndex 0 -LibraryTotal $TotalLibraries -StartedAt $ProgressStartedAt

$LibrariesOut = @()

$LibIndex = 0
foreach ($lib in $libs) {
    $LibIndex++
    $LibraryBasePercent = 12 + ((($LibIndex - 1) / [math]::Max(1, $TotalLibraries)) * 78)
    Info "Bibliotheque : $($lib.Title)"
    Show-ArchitectureProgress -Percent $LibraryBasePercent -Stage "lecture de '$($lib.Title)'" -LibraryIndex $LibIndex -LibraryTotal $TotalLibraries -StartedAt $ProgressStartedAt
    $rootUrl = $lib.RootFolder.ServerRelativeUrl

    Show-ArchitectureProgress -Percent $LibraryBasePercent -Stage "chargement des dossiers de '$($lib.Title)'" -LibraryIndex $LibIndex -LibraryTotal $TotalLibraries -StartedAt $ProgressStartedAt
    $folderCandidates = @(Get-PnPListItem -List $lib -PageSize 500 -Query $FolderOnlyCaml)

    $nodes = @{}
    # Name = titre AFFICHE actuel (change si on renomme la bibliotheque).
    # NomInterne = nom d'URL interne (ne change JAMAIS, ex "Documents partages").
    $libInterne = $rootUrl.TrimEnd('/').Split('/')[-1]
    $rootNode = [ordered]@{ Name = $lib.Title; NomInterne = $libInterne; Type = "Bibliotheque"; ServerRelativeUrl = $rootUrl; Dossiers = @(); Fichiers = @() }
    if (-not $SansPermissions) {
        try {
            $p = Get-ItemPermissions -Item $lib
            $rootNode.HeritageRompu = $p.HeritageRompu
            $rootNode.Permissions   = $p.Permissions
        }
        catch {
            Warn "  Permissions de la bibliotheque '$($lib.Title)' non recuperees : $($_.Exception.Message)"
            $rootNode.HeritageRompu = $null
            $rootNode.Permissions   = @()
        }
    }
    $nodes[$rootUrl] = $rootNode

    # Dossiers niveaux 1 a 3, traites du moins profond au plus profond.
    $folderItems = @($folderCandidates |
        Where-Object {
            $url = "$($_['FileRef'])"
            $depth = Get-FolderDepth -LibraryRootUrl $rootUrl -FolderUrl $url
            $depth -ge 1 -and $depth -le $MaxFolderDepth -and "$($_['FileLeafRef'])" -ne "Forms"
        } |
        Sort-Object { Get-FolderDepth -LibraryRootUrl $rootUrl -FolderUrl "$($_['FileRef'])" })

    $FolderTotal = $folderItems.Count
    $WorkTotal = [math]::Max(1, $FolderTotal)
    $WorkDone = 0
    Show-ArchitectureProgress -Percent $LibraryBasePercent -Stage "$FolderTotal dossier(s) des niveaux 1 a $MaxFolderDepth trouves, 0 fichier" -LibraryIndex $LibIndex -LibraryTotal $TotalLibraries -RemainingFolders $FolderTotal -RemainingFiles 0 -StartedAt $ProgressStartedAt

    foreach ($fi in $folderItems) {
        $url  = $fi["FileRef"]
        $name = $fi["FileLeafRef"]

        $modPar  = if ($fi["Editor"]) { "$($fi["Editor"].LookupValue)" } else { "" }
        $creePar = if ($fi["Author"]) { "$($fi["Author"].LookupValue)" } else { "" }
        $node = [ordered]@{ Name = $name; Type = "Dossier"; ServerRelativeUrl = $url;
            Cree = "$($fi["Created"])"; CreePar = $creePar; Modifie = "$($fi["Modified"])"; ModifiePar = $modPar }
        if (-not $SansPermissions) {
            $p = Get-ItemPermissions -Item $fi
            $node.HeritageRompu = $p.HeritageRompu
            $node.Permissions   = $p.Permissions
        }
        $node.Dossiers = @()
        $node.Fichiers = @()
        $nodes[$url] = $node

        $parentUrl = $url.Substring(0, $url.LastIndexOf('/'))
        if ($nodes.ContainsKey($parentUrl)) { $nodes[$parentUrl].Dossiers += $node }
        else { $rootNode.Dossiers += $node }

        $WorkDone++
        $LocalPercent = $WorkDone / $WorkTotal
        $OverallPercent = 12 + ((($LibIndex - 1 + $LocalPercent) / [math]::Max(1, $TotalLibraries)) * 78)
        $depth = Get-FolderDepth -LibraryRootUrl $rootUrl -FolderUrl $url
        Show-ArchitectureProgress -Percent $OverallPercent -Stage "dossier niveau $depth '$name' traite" -LibraryIndex $LibIndex -LibraryTotal $TotalLibraries -RemainingFolders ([math]::Max(0, $FolderTotal - $WorkDone)) -RemainingFiles 0 -StartedAt $ProgressStartedAt
    }

    $nbDossiers = $FolderTotal
    Ok "  -> $nbDossiers dossier(s) niveaux 1 a $MaxFolderDepth, 0 fichier"
    $LibraryEndPercent = 12 + (($LibIndex / [math]::Max(1, $TotalLibraries)) * 78)
    Show-ArchitectureProgress -Percent $LibraryEndPercent -Stage "bibliotheque '$($lib.Title)' terminee" -LibraryIndex $LibIndex -LibraryTotal $TotalLibraries -RemainingFolders 0 -RemainingFiles 0 -StartedAt $ProgressStartedAt

    $LibrariesOut += $rootNode
}

Show-ArchitectureProgress -Percent 92 -Stage "preparation de l'export JSON/HTML" -LibraryIndex $TotalLibraries -LibraryTotal $TotalLibraries -StartedAt $ProgressStartedAt

#------------------------------------------------------
# OBJET FINAL
#------------------------------------------------------
$Architecture = [ordered]@{
    Mode = "Bibliotheque -> dossier niveau 1 -> dossier niveau 2 -> dossier niveau 3"
    ProfondeurMax = $MaxFolderDepth
    FichiersInclus = $false
    Site = [ordered]@{
        Titre       = $web.Title
        Url         = $web.Url
        CaptureLe   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        HeritageRompu = $SitePermissionsInfo.HeritageRompu
        Permissions = $SitePermissionsInfo.Permissions
    }
    Bibliotheques = $LibrariesOut
}

#------------------------------------------------------
# EXPORT : architecture-3-niveaux_<horodatage>.json + architecture-3-niveaux-latest.json
#------------------------------------------------------
$SiteName = ($SiteUrl -replace '/+$', '').Split('/')[-1]
if ([string]::IsNullOrWhiteSpace($SiteName)) { $SiteName = "Site" }

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    # Defaut : architecture\<NomDuSite> a cote du script
    $OutDir = Join-Path (Join-Path $ScriptRoot "architecture") $SiteName
}
else {
    # Dossier impose (ex : le dossier du site) ; chemin relatif = relatif au script
    if (-not [System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir = Join-Path $ScriptRoot $OutputDir }
    $OutDir = $OutputDir
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$Stamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$OutFile  = Join-Path $OutDir "architecture-3-niveaux_$Stamp.json"
$LastFile = Join-Path $OutDir "architecture-3-niveaux-latest.json"

$json = $Architecture | ConvertTo-Json -Depth 30
Set-Content -Path $OutFile  -Value $json -Encoding UTF8
Set-Content -Path $LastFile -Value $json -Encoding UTF8

#------------------------------------------------------
# EXPORT HTML autonome (arbre deroulant, donnees integrees, double-cliquable)
#------------------------------------------------------
$HtmlTemplate = @'
<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Architecture SharePoint</title>
<style>
:root{--bg:#f6f8fa;--card:#fff;--text:#1f2328;--muted:#656d76;--line:#d0d7de;--accent:#0969da;--sg:#1a7f37;--spg:#8250df;--usr:#bf3989;--deny:#cf222e;--chipbg:#eef2f6;--hit:#fff3cd}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--card:#161b22;--text:#e6edf3;--muted:#8b949e;--line:#30363d;--accent:#4493f8;--sg:#3fb950;--spg:#a371f7;--usr:#f778ba;--deny:#f85149;--chipbg:#21262d;--hit:#3d3212}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,Segoe UI,Roboto,Arial,sans-serif}
header{padding:18px 22px;border-bottom:1px solid var(--line);background:var(--card);position:sticky;top:0}
h1{margin:0 0 4px;font-size:18px}.sub{color:var(--muted);font-size:13px;word-break:break-all}
.toolbar{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}
button{cursor:pointer;border:1px solid var(--line);background:var(--card);color:var(--text);padding:7px 12px;border-radius:8px;font-size:13px}
button:hover{border-color:var(--accent);color:var(--accent)}
input[type=search]{flex:1;min-width:160px;padding:7px 10px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text)}
main{padding:16px 22px;max-width:1100px;margin:0 auto}
details{margin:2px 0}summary{list-style:none;cursor:pointer;display:flex;align-items:center;gap:8px;padding:5px 8px;border-radius:8px}
summary::-webkit-details-marker{display:none}summary:hover{background:var(--chipbg)}
.caret{width:12px;color:var(--muted);transition:transform .15s}details[open]>summary .caret{transform:rotate(90deg)}
.ico{font-size:15px}.name{font-weight:600}.count{color:var(--muted);font-weight:400;font-size:12px}
.body{margin-left:20px;border-left:1px solid var(--line);padding-left:12px}
.perms{display:flex;flex-wrap:wrap;gap:6px;margin:4px 0 6px}
.badge{font-size:12px;padding:2px 8px;border-radius:999px;background:var(--chipbg);border:1px solid var(--line)}
.badge.sg{color:var(--sg)}.badge.spg{color:var(--spg)}.badge.usr{color:var(--usr)}.badge.inherit{color:var(--muted)}.badge.none{color:var(--deny)}
.file{display:flex;align-items:center;gap:8px;padding:3px 8px;color:var(--muted);border-radius:6px}.file .name{font-weight:400;color:var(--text)}.file.match{background:var(--hit)}
.hidden{display:none}.legend{color:var(--muted);font-size:12px;margin-top:10px}
@media print{.toolbar,#legend{display:none!important}header{position:static}.body{border:none}details{break-inside:avoid}}
</style></head><body>
<header><h1 id="site">Architecture</h1><div class="sub" id="url"></div>
<div class="toolbar"><button id="expand">Tout derouler</button><button id="collapse">Tout replier</button>
<button id="pdf">Extraire PDF</button><button id="word">Extraire Word</button><button id="excel">Extraire Excel</button>
<input type="search" id="filter" placeholder="Rechercher un dossier ou un fichier..."></div></header>
<main><div id="tree"></div><div class="legend" id="legend"></div></main>
<script>
const DATA = /*__ARCH_DATA__*/;
const $=s=>document.querySelector(s);
const el=(t,c,x)=>{const e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e;};
const tc=t=>t==='SecurityGroup'?'sg':(t==='SharePointGroup'?'spg':'usr');
function perms(f){const w=el('div','perms');if(f.HeritageRompu===false){w.appendChild(el('span','badge inherit','heritage conserve'));return w;}
const l=f.Permissions||[];if(!l.length){w.appendChild(el('span','badge none','unique - aucun groupe explicite'));return w;}
l.forEach(p=>{const b=el('span','badge '+tc(p.Type));b.textContent='🔐 '+p.Principal+' · '+((p.Roles||[]).join(', ')||'-');w.appendChild(b);});return w;}
function fr(fi){var r=el('div','file');r.appendChild(el('span','ico','📄'));r.appendChild(el('span','name',fi.Name));var m=[];if(fi.Modifie||fi.ModifiePar)m.push('modifie'+(fi.Modifie?' le '+fi.Modifie:'')+(fi.ModifiePar?' par '+fi.ModifiePar:''));if(m.length)r.appendChild(el('span','count',' · '+m.join(' · ')));if(fi.Cree||fi.CreePar)r.title='Cree'+(fi.Cree?' le '+fi.Cree:'')+(fi.CreePar?' par '+fi.CreePar:'');r.dataset.name=(fi.Name||'').toLowerCase();return r;}
function folder(f){const d=el('details','folder');const s=el('summary');s.appendChild(el('span','caret','▶'));s.appendChild(el('span','ico','📁'));s.appendChild(el('span','name',f.Name));
s.appendChild(el('span','count',' - '+((f.Dossiers||[]).length)+' dossier(s), '+((f.Fichiers||[]).length)+' fichier(s)'+(f.ModifiePar?' · modifie par '+f.ModifiePar:'')));d.appendChild(s);
const b=el('div','body');b.appendChild(perms(f));(f.Dossiers||[]).forEach(x=>b.appendChild(folder(x)));
(f.Fichiers||[]).forEach(fi=>b.appendChild(fr(fi)));
d.appendChild(b);d.dataset.name=(f.Name||'').toLowerCase();return d;}
function lib(l){const d=el('details','lib');d.open=true;const s=el('summary');s.appendChild(el('span','caret','▶'));s.appendChild(el('span','ico','📚'));s.appendChild(el('span','name',l.Name));
var lc=' - '+((l.Dossiers||[]).length)+' dossier(s)';if(l.NomInterne&&l.NomInterne.toLowerCase()!==(l.Name||'').toLowerCase())lc+='  ·  nom interne : '+l.NomInterne;s.appendChild(el('span','count',lc));d.appendChild(s);const b=el('div','body');
(l.Dossiers||[]).forEach(f=>b.appendChild(folder(f)));(l.Fichiers||[]).forEach(fi=>b.appendChild(fr(fi)));d.appendChild(b);return d;}
$('#site').textContent='📊 '+(DATA.Site&&DATA.Site.Titre||'Architecture');
$('#url').textContent=((DATA.Site&&DATA.Site.Url)||'')+((DATA.Site&&DATA.Site.CaptureLe)?'  •  capture le '+DATA.Site.CaptureLe:'');
const tree=$('#tree');(DATA.Bibliotheques||[]).forEach(l=>tree.appendChild(lib(l)));
$('#legend').textContent='Legende : 📚 bibliotheque · 📁 dossier · 📄 fichier · 🔐 groupe ayant un droit (vert=groupe Entra, violet=groupe SharePoint).';
$('#expand').onclick=()=>document.querySelectorAll('details').forEach(d=>d.open=true);
$('#collapse').onclick=()=>document.querySelectorAll('#tree details').forEach(d=>d.open=false);
$('#filter').oninput=e=>{var q=(e.target.value||'').toLowerCase();var T=$('#tree');var all=[].slice.call(T.querySelectorAll('details.folder, .file'));all.forEach(n=>{n.classList.remove('hidden');n.classList.remove('match');});if(!q){T.querySelectorAll('details.folder').forEach(d=>d.open=false);T.querySelectorAll('details.lib').forEach(d=>d.open=true);return;}all.forEach(n=>n.classList.add('hidden'));var reveal=function(n){n.classList.remove('hidden');var p=n.parentElement;while(p&&p!==T){if(p.tagName==='DETAILS'){p.classList.remove('hidden');p.open=true;}p=p.parentElement;}};all.forEach(n=>{if((n.dataset.name||'').includes(q)){reveal(n);if(n.classList.contains('file'))n.classList.add('match');if(n.tagName==='DETAILS'){n.querySelectorAll('details.folder, .file').forEach(x=>x.classList.remove('hidden'));n.querySelectorAll('details').forEach(d=>d.open=true);}}});};
const esc=s=>String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
const safe=s=>(s||'site').replace(/[^\w\-]+/g,'_');
function dl(blob,name){const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=name;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(a.href),1500);}
$('#pdf').onclick=()=>{document.querySelectorAll('details').forEach(d=>d.open=true);window.print();};
function rep(f,depth){var pad=depth*20;var pt=(f.HeritageRompu===false)?'<i>heritage conserve</i>':(!(f.Permissions||[]).length?'<i>unique - aucun groupe explicite</i>':(f.Permissions||[]).map(p=>'<b>'+esc(p.Principal)+'</b> ('+esc(p.Type)+') : '+esc((p.Roles||[]).join(', '))).join(' &nbsp;|&nbsp; '));var h='<p style="margin:6px 0 2px '+pad+'px">📁 <b>'+esc(f.Name)+'</b>'+(f.ModifiePar?' <span style="color:#777">- modifie par '+esc(f.ModifiePar)+'</span>':'')+'<br><span style="margin-left:18px;color:#333">'+pt+'</span></p>';(f.Dossiers||[]).forEach(s=>h+=rep(s,depth+1));return h;}
$('#word').onclick=()=>{var h='<html xmlns:w="urn:schemas-microsoft-com:office:word"><head><meta charset="utf-8"><style>body{font-family:Calibri,Arial;font-size:11pt}h1{font-size:18pt}h2{font-size:14pt;color:#0969da;border-bottom:1px solid #ccc}</style></head><body>';h+='<h1>Architecture SharePoint - '+esc(DATA.Site&&DATA.Site.Titre||'')+'</h1><p>'+esc(DATA.Site&&DATA.Site.Url||'')+'<br>Capture le '+esc(DATA.Site&&DATA.Site.CaptureLe||'')+'</p>';(DATA.Bibliotheques||[]).forEach(l=>{h+='<h2>📚 '+esc(l.Name)+'</h2>';(l.Dossiers||[]).forEach(f=>h+=rep(f,0));});h+='</body></html>';dl(new Blob(['﻿'+h],{type:'application/msword'}),'architecture-'+safe(DATA.Site&&DATA.Site.Titre)+'.doc');};
function walk(n,lib,par,rows){(n.Dossiers||[]).forEach(f=>{var path=par?par+'/'+f.Name:f.Name;if(f.HeritageRompu===false){rows.push([lib,path,'non (herite)','','','',f.ModifiePar||'']);}else if(!(f.Permissions||[]).length){rows.push([lib,path,'oui','(aucun groupe explicite)','','',f.ModifiePar||'']);}else (f.Permissions||[]).forEach(p=>rows.push([lib,path,'oui',p.Principal,p.Type,(p.Roles||[]).join(', '),f.ModifiePar||'']));walk(f,lib,path,rows);});}
$('#excel').onclick=()=>{var rows=[['Bibliotheque','Dossier (chemin)','Heritage rompu','Groupe / Principal','Type','Roles','Modifie par']];(DATA.Bibliotheques||[]).forEach(l=>walk(l,l.Name,'',rows));var csv=rows.map(r=>r.map(c=>'"'+String(c==null?'':c).replace(/"/g,'""')+'"').join(';')).join('\r\n');dl(new Blob(['﻿'+csv],{type:'text/csv;charset=utf-8'}),'architecture-'+safe(DATA.Site&&DATA.Site.Titre)+'.csv');};
</script></body></html>
'@
$HtmlFile = Join-Path $OutDir "architecture-3-niveaux-latest.html"
$html = $HtmlTemplate.Replace('/*__ARCH_DATA__*/', $json)
Set-Content -Path $HtmlFile -Value $html -Encoding UTF8

Disconnect-PnPOnline
Show-ArchitectureProgress -Percent 100 -Stage "export termine" -LibraryIndex $TotalLibraries -LibraryTotal $TotalLibraries -StartedAt $ProgressStartedAt

Write-Host ""
Ok "Architecture exportee :"
Write-Host "   $OutFile" -ForegroundColor White
Write-Host "   $LastFile (copie 'derniere version')" -ForegroundColor White
Write-Host "   $HtmlFile (visualisation - double-cliquez pour ouvrir)" -ForegroundColor White
Write-Host ""
Write-Host "=== TERMINE ===`n" -ForegroundColor White
