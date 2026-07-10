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

#------------------------------------------------------
# EXPORT HTML autonome (arbre deroulant, donnees integrees, double-cliquable)
#------------------------------------------------------
$HtmlTemplate = @'
<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Architecture SharePoint</title>
<style>
:root{--bg:#f6f8fa;--card:#fff;--text:#1f2328;--muted:#656d76;--line:#d0d7de;--accent:#0969da;--sg:#1a7f37;--spg:#8250df;--usr:#bf3989;--deny:#cf222e;--chipbg:#eef2f6}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--card:#161b22;--text:#e6edf3;--muted:#8b949e;--line:#30363d;--accent:#4493f8;--sg:#3fb950;--spg:#a371f7;--usr:#f778ba;--deny:#f85149;--chipbg:#21262d}}
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
.file{display:flex;align-items:center;gap:8px;padding:3px 8px;color:var(--muted)}.file .name{font-weight:400;color:var(--text)}
.hidden{display:none}.legend{color:var(--muted);font-size:12px;margin-top:10px}
</style></head><body>
<header><h1 id="site">Architecture</h1><div class="sub" id="url"></div>
<div class="toolbar"><button id="expand">Tout derouler</button><button id="collapse">Tout replier</button>
<input type="search" id="filter" placeholder="Filtrer par nom de dossier..."></div></header>
<main><div id="tree"></div><div class="legend" id="legend"></div></main>
<script>
const DATA = /*__ARCH_DATA__*/;
const $=s=>document.querySelector(s);
const el=(t,c,x)=>{const e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e;};
const tc=t=>t==='SecurityGroup'?'sg':(t==='SharePointGroup'?'spg':'usr');
function perms(f){const w=el('div','perms');if(f.HeritageRompu===false){w.appendChild(el('span','badge inherit','heritage conserve'));return w;}
const l=f.Permissions||[];if(!l.length){w.appendChild(el('span','badge none','unique - aucun groupe explicite'));return w;}
l.forEach(p=>{const b=el('span','badge '+tc(p.Type));b.textContent='🔐 '+p.Principal+' · '+((p.Roles||[]).join(', ')||'-');w.appendChild(b);});return w;}
function folder(f){const d=el('details','folder');const s=el('summary');s.appendChild(el('span','caret','▶'));s.appendChild(el('span','ico','📁'));s.appendChild(el('span','name',f.Name));
s.appendChild(el('span','count',' - '+((f.Dossiers||[]).length)+' dossier(s), '+((f.Fichiers||[]).length)+' fichier(s)'));d.appendChild(s);
const b=el('div','body');b.appendChild(perms(f));(f.Dossiers||[]).forEach(x=>b.appendChild(folder(x)));
(f.Fichiers||[]).forEach(fi=>{const r=el('div','file');r.appendChild(el('span','ico','📄'));r.appendChild(el('span','name',fi.Name));if(fi.Modifie)r.appendChild(el('span','count',' · '+fi.Modifie));b.appendChild(r);});
d.appendChild(b);d.dataset.name=(f.Name||'').toLowerCase();return d;}
function lib(l){const d=el('details','lib');d.open=true;const s=el('summary');s.appendChild(el('span','caret','▶'));s.appendChild(el('span','ico','📚'));s.appendChild(el('span','name',l.Name));
s.appendChild(el('span','count',' - '+((l.Dossiers||[]).length)+' dossier(s)'));d.appendChild(s);const b=el('div','body');
(l.Dossiers||[]).forEach(f=>b.appendChild(folder(f)));(l.Fichiers||[]).forEach(fi=>{const r=el('div','file');r.appendChild(el('span','ico','📄'));r.appendChild(el('span','name',fi.Name));b.appendChild(r);});d.appendChild(b);return d;}
$('#site').textContent='📊 '+(DATA.Site&&DATA.Site.Titre||'Architecture');
$('#url').textContent=((DATA.Site&&DATA.Site.Url)||'')+((DATA.Site&&DATA.Site.CaptureLe)?'  •  capture le '+DATA.Site.CaptureLe:'');
const tree=$('#tree');(DATA.Bibliotheques||[]).forEach(l=>tree.appendChild(lib(l)));
$('#legend').textContent='Legende : 📚 bibliotheque · 📁 dossier · 📄 fichier · 🔐 groupe ayant un droit (vert=groupe Entra, violet=groupe SharePoint).';
$('#expand').onclick=()=>document.querySelectorAll('details').forEach(d=>d.open=true);
$('#collapse').onclick=()=>document.querySelectorAll('#tree details').forEach(d=>d.open=false);
$('#filter').oninput=e=>{const q=e.target.value.toLowerCase();document.querySelectorAll('#tree details.folder').forEach(d=>{const m=!q||(d.dataset.name||'').includes(q);d.classList.toggle('hidden',q&&!m);if(m&&q){let p=d.parentElement;while(p){if(p.tagName==='DETAILS'){p.open=true;p.classList.remove('hidden');}p=p.parentElement;}d.open=true;}});};
</script></body></html>
'@
$HtmlFile = Join-Path $OutDir "architecture-latest.html"
$html = $HtmlTemplate.Replace('/*__ARCH_DATA__*/', $json)
Set-Content -Path $HtmlFile -Value $html -Encoding UTF8

Disconnect-PnPOnline

Write-Host ""
Ok "Architecture exportee :"
Write-Host "   $OutFile" -ForegroundColor White
Write-Host "   $LastFile (copie 'derniere version')" -ForegroundColor White
Write-Host "   $HtmlFile (visualisation - double-cliquez pour ouvrir)" -ForegroundColor White
Write-Host ""
Write-Host "=== TERMINE ===`n" -ForegroundColor White
