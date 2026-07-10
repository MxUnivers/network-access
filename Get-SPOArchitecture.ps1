<#
.SYNOPSIS
Recupere l'ARCHITECTURE complete d'un site SharePoint Online
(bibliotheques -> dossiers -> sous-dossiers) AVEC les permissions
de chaque dossier, et l'exporte en JSON.

.DESCRIPTION
Authentification app-only par certificat (memes infos que PermissionsConfig.json).
Le resultat est ecrit dans :  architecture\<NomDuSite>\architecture_<horodatage>.json
Concu pour etre relance sur plusieurs sites (parametre -SiteUrl).

.EXEMPLE
.\Get-SPOArchitecture.ps1
.\Get-SPOArchitecture.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/AutreSite"
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
    Write-Host "  Ce script exige PowerShell 7. Double-cliquez sur 5-Recuperer-Architecture.cmd" -ForegroundColor Red
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

Write-Host "`n=== RECUPERATION DE L'ARCHITECTURE ===`n" -ForegroundColor White

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

#------------------------------------------------------
# CONFIGURATION + CONNEXION
#------------------------------------------------------
$Config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
$Auth   = $Config.Auth
if ([string]::IsNullOrWhiteSpace($SiteUrl)) { $SiteUrl = $Config.SiteUrl }

try {
    Connect-PnPOnline -Url $SiteUrl -ClientId $Auth.ClientId -Tenant $Auth.TenantId `
        -Thumbprint $Auth.CertificateThumbprint -ErrorAction Stop
    $web = Get-PnPWeb -ErrorAction Stop
    Ok "Connecte : $($web.Title) [$($web.Url)]"
}
catch {
    Warn "Connexion impossible : $($_.Exception.Message)"
    exit 1
}

#------------------------------------------------------
# HELPER : permissions d'un element (dossier)
#------------------------------------------------------
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
            $perms += [ordered]@{
                Principal = $ra.Member.Title
                Type      = "$($ra.Member.PrincipalType)"
                Roles     = $roles
            }
        }
    }
    return [ordered]@{ HeritageRompu = [bool]$unique; Permissions = $perms }
}

#------------------------------------------------------
# PARCOURS DES BIBLIOTHEQUES DE DOCUMENTS
#------------------------------------------------------
$SkipLibs = @("Style Library", "Form Templates", "Site Assets", "Site Pages")
$libs = Get-PnPList | Where-Object { $_.BaseTemplate -eq 101 -and -not $_.Hidden -and ($SkipLibs -notcontains $_.Title) }

$LibrariesOut = @()

foreach ($lib in $libs) {
    Info "Bibliotheque : $($lib.Title)"
    $rootUrl = $lib.RootFolder.ServerRelativeUrl

    # Un seul appel : tous les elements (dossiers + fichiers) de la bibliotheque
    $items = Get-PnPListItem -List $lib -PageSize 500 -Fields "FileRef", "FileLeafRef", "Modified"

    $nodes = @{}
    $rootNode = [ordered]@{ Name = $lib.Title; Type = "Bibliotheque"; ServerRelativeUrl = $rootUrl; Dossiers = @(); Fichiers = @() }
    $nodes[$rootUrl] = $rootNode

    # 1) Dossiers (traites du moins profond au plus profond pour que le parent existe)
    $folderItems = $items | Where-Object { $_.FileSystemObjectType -eq "Folder" } |
        Sort-Object { ($_["FileRef"] -split '/').Count }

    foreach ($fi in $folderItems) {
        $url  = $fi["FileRef"]
        $name = $fi["FileLeafRef"]
        if ($name -eq "Forms") { continue }   # dossier systeme

        $node = [ordered]@{ Name = $name; Type = "Dossier"; ServerRelativeUrl = $url }
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
    }

    # 2) Fichiers (rattaches a leur dossier parent)
    $fileItems = $items | Where-Object { $_.FileSystemObjectType -eq "File" }
    foreach ($fi in $fileItems) {
        $url  = $fi["FileRef"]
        $name = $fi["FileLeafRef"]
        $parentUrl = $url.Substring(0, $url.LastIndexOf('/'))
        $fileNode = [ordered]@{ Name = $name; Modifie = "$($fi["Modified"])" }
        if ($nodes.ContainsKey($parentUrl)) { $nodes[$parentUrl].Fichiers += $fileNode }
        else { $rootNode.Fichiers += $fileNode }
    }

    $nbDossiers = ($folderItems | Measure-Object).Count
    $nbFichiers = ($fileItems | Measure-Object).Count
    Ok "  -> $nbDossiers dossier(s), $nbFichiers fichier(s)"

    $LibrariesOut += $rootNode
}

#------------------------------------------------------
# OBJET FINAL
#------------------------------------------------------
$Architecture = [ordered]@{
    Site = [ordered]@{
        Titre       = $web.Title
        Url         = $web.Url
        CaptureLe   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    Bibliotheques = $LibrariesOut
}

#------------------------------------------------------
# EXPORT : architecture\<NomDuSite>\architecture_<horodatage>.json
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
$OutFile  = Join-Path $OutDir "architecture_$Stamp.json"
$LastFile = Join-Path $OutDir "architecture-latest.json"

$json = $Architecture | ConvertTo-Json -Depth 30
Set-Content -Path $OutFile  -Value $json -Encoding UTF8
Set-Content -Path $LastFile -Value $json -Encoding UTF8

Disconnect-PnPOnline

Write-Host ""
Ok "Architecture exportee :"
Write-Host "   $OutFile" -ForegroundColor White
Write-Host "   $LastFile (copie 'derniere version')" -ForegroundColor White
Write-Host ""
Write-Host "=== TERMINE ===`n" -ForegroundColor White
