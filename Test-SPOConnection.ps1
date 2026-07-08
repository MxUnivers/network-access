<#
.SYNOPSIS
Test de connexion NON destructif (lecture seule) pour valider
l'authentification app-only par certificat, avant d'executer
Set-SPOFolderPermissions.ps1.

Ne modifie AUCUNE permission. Verifie :
  1. Connexion Microsoft Graph (certificat)
  2. Lecture des groupes Entra ID cibles
  3. Connexion SharePoint Online (certificat)
  4. Existence de la bibliotheque et du dossier cible

.EXEMPLE
.\Test-SPOConnection.ps1
#>

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Red
    Write-Host "  Ce script exige PowerShell 7 (vous etes en $($PSVersionTable.PSVersion))." -ForegroundColor Red
    Write-Host "  N'ouvrez PAS 'Windows PowerShell' (icone BLEUE = 5.1)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  --> Fermez cette fenetre et DOUBLE-CLIQUEZ sur le fichier :" -ForegroundColor Green
    Write-Host "        1-Tester-Connexion.cmd" -ForegroundColor Green
    Write-Host "      (il ouvre PowerShell 7 tout seul)" -ForegroundColor Green
    Write-Host "  ============================================================" -ForegroundColor Red
    Write-Host ""
    exit 1
}

$ErrorActionPreference = "Stop"

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }
$ConfigFile = Join-Path $ScriptRoot "PermissionsConfig.json"

function Ok   ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Info ($m) { Write-Host "  [INFO] $m" -ForegroundColor Cyan }
function Fail ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }

Write-Host "`n=== TEST DE CONNEXION (lecture seule) ===`n" -ForegroundColor White

# --- Config ---
try {
    $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Ok "Configuration lue : $ConfigFile"
} catch {
    Fail "Lecture config : $($_.Exception.Message)"; exit 1
}

$Auth = $Config.Auth

# --- Installation + import des modules, hors dossiers proteges (Controlled Folder Access) ---
# Les modules vont dans AppData\Local (NON protege), pas dans Documents (bloque par l'anti-rancongiciel).
$ModulesDir = Join-Path $env:LOCALAPPDATA "SPO-Automation\Modules"
if (-not (Test-Path $ModulesDir)) { New-Item -ItemType Directory -Path $ModulesDir -Force | Out-Null }
if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $ModulesDir) {
    $env:PSModulePath = $ModulesDir + [IO.Path]::PathSeparator + $env:PSModulePath
}

function Install-RequiredModule {
    param([string]$Name)
    if (Get-Module -ListAvailable -Name $Name) { return }
    Info "Installation du module $Name dans $ModulesDir (hors dossiers proteges) ..."
    if (-not (Get-Command Save-PSResource -ErrorAction SilentlyContinue)) {
        throw "Save-PSResource indisponible : PowerShell 7.4+ requis"
    }
    Save-PSResource -Name $Name -Path $ModulesDir -TrustRepository -IncludeXml -SkipDependencyCheck -ErrorAction Stop
}

try {
    foreach ($m in @("PnP.PowerShell", "Microsoft.Graph.Authentication", "Microsoft.Graph.Groups")) {
        Install-RequiredModule -Name $m
        Import-Module $m -ErrorAction Stop
    }
    Ok "Modules charges"
} catch {
    Fail "Import modules : $($_.Exception.Message)"; exit 1
}

# --- 1. Graph ---
try {
    Connect-MgGraph -TenantId $Auth.TenantId -ClientId $Auth.ClientId `
        -CertificateThumbprint $Auth.CertificateThumbprint -NoWelcome -ErrorAction Stop
    $ctx = Get-MgContext
    if (-not $ctx.ClientId) { throw "Contexte Graph vide" }
    Ok "Graph connecte (app $($ctx.ClientId))"
    Info "Scopes accordes : $($ctx.Scopes -join ', ')"
} catch {
    Fail "Connexion Graph : $($_.Exception.Message)"
    Info "Cause frequente : consentement admin non accorde, ou propagation Azure (attendre 2-5 min)."
    exit 1
}

# --- 2. Groupes Entra ID cibles ---
$groupes = $Config.Permissions.Assignments.GroupName | Select-Object -Unique
foreach ($g in $groupes) {
    try {
        $grp = Get-MgGroup -Filter "displayName eq '$g'" -ErrorAction Stop
        if ($grp) { Ok "Groupe Entra ID trouve : $g ($($grp.Id))" }
        else      { Fail "Groupe Entra ID INTROUVABLE : $g" }
    } catch {
        Fail "Recherche groupe '$g' : $($_.Exception.Message)"
    }
}

# --- 3. SharePoint ---
try {
    Connect-PnPOnline -Url $Config.SiteUrl -ClientId $Auth.ClientId `
        -Tenant $Auth.TenantId -Thumbprint $Auth.CertificateThumbprint -ErrorAction Stop
    $web = Get-PnPWeb -ErrorAction Stop
    Ok "SharePoint connecte : $($web.Title) [$($web.Url)]"
} catch {
    Fail "Connexion SharePoint : $($_.Exception.Message)"
    Info "Cause frequente : permission Sites.FullControl.All non accordee/consentie."
    try { Disconnect-MgGraph | Out-Null } catch {}
    exit 1
}

# --- 4. Bibliotheque + dossier cible ---
foreach ($Entry in $Config.Permissions) {
    try {
        $list = Get-PnPList $Entry.Library -ErrorAction Stop
        Ok "Bibliotheque trouvee : $($Entry.Library)"

        $folderUrl = $list.RootFolder.ServerRelativeUrl + "/" + $Entry.FolderPath
        $folder = Get-PnPFolder -Url $folderUrl -ErrorAction SilentlyContinue
        if ($folder) { Ok "Dossier trouve : $($Entry.FolderPath)" }
        else         { Fail "Dossier INTROUVABLE : $folderUrl (a creer, ou verifier le nom)" }
    } catch {
        Fail "Bibliotheque '$($Entry.Library)' : $($_.Exception.Message)"
    }
}

# --- Nettoyage ---
try { Disconnect-PnPOnline } catch {}
try { Disconnect-MgGraph | Out-Null } catch {}

Write-Host "`n=== TEST TERMINE ===" -ForegroundColor White
Write-Host "Si toutes les lignes sont [OK], lancez : 2-Appliquer-Permissions.cmd`n" -ForegroundColor Yellow
