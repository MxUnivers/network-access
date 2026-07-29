<#!
.SYNOPSIS
Recupere les bibliotheques et les dossiers SharePoint jusqu'au niveau 3 sans requete RecursiveAll.
#>
param(
    [string]$ConfigFile,
    [string]$SiteUrl,
    [string]$OutputDir,
    [switch]$AvecPermissions
)

if ($PSVersionTable.PSVersion.Major -lt 7) { throw "PowerShell 7 est requis." }
$ErrorActionPreference = "Stop"
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($ConfigFile)) { $ConfigFile = Join-Path $ScriptRoot "PermissionsConfig.json" }
elseif (-not [IO.Path]::IsPathRooted($ConfigFile)) { $ConfigFile = Join-Path $ScriptRoot $ConfigFile }

function Info([string]$Message) { Write-Host "  $Message" -ForegroundColor Cyan }
function Ok([string]$Message) { Write-Host "  $Message" -ForegroundColor Green }
function Show-Progress {
    param([double]$Percent,[string]$Stage,[datetime]$StartedAt,[int]$LibraryIndex=0,[int]$LibraryTotal=0,[int]$Folders=0)
    $elapsed=(Get-Date)-$StartedAt
    $eta="calcul en cours"
    if($Percent -gt 0.5){$total=$elapsed.TotalSeconds/($Percent/100);$eta=(Get-Date).AddSeconds([math]::Max(0,$total-$elapsed.TotalSeconds)).ToString("HH:mm:ss")}
    Write-Host ("  [PROGRESSION] {0,6:N1}% | bibliotheque {1}/{2} | {3} | {4} dossier(s) | fin estimee: {5}" -f $Percent,$LibraryIndex,$LibraryTotal,$Stage,$Folders,$eta)
}

Write-Host "`n=== RECUPERATION DIRECTE DES 3 NIVEAUX ===`n" -ForegroundColor White
$started=Get-Date
Show-Progress 0 "demarrage" $started
Import-Module PnP.PowerShell -ErrorAction Stop

$config=Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
$auth=$config.Auth
if([string]::IsNullOrWhiteSpace($SiteUrl)){$SiteUrl=$config.SiteUrl}
$configDir=Split-Path -Parent $ConfigFile
if(-not $auth -or -not $auth.TenantId -or -not $auth.ClientId){throw "Configuration Auth incomplete."}
$params=@{Url=$SiteUrl;ClientId=$auth.ClientId;Tenant=$auth.TenantId;ErrorAction="Stop"}
if($auth.CertificateThumbprint){$params.Thumbprint=$auth.CertificateThumbprint}
elseif($auth.CertificatePath){
    $cert=$auth.CertificatePath
    if(-not [IO.Path]::IsPathRooted($cert)){$cert=Join-Path $configDir $cert}
    $params.CertificatePath=$cert
    $params.CertificatePassword=ConvertTo-SecureString ([string]$auth.CertificatePassword) -AsPlainText -Force
}else{throw "CertificateThumbprint ou CertificatePath manquant."}
Connect-PnPOnline @params
$web=Get-PnPWeb -ErrorAction Stop
Ok "Connecte : $($web.Title) [$($web.Url)]"

function To-SiteRelative([string]$ServerRelativeUrl) {
    $root="$($web.ServerRelativeUrl)".TrimEnd('/')
    $value="$ServerRelativeUrl"
    if($root -and $value.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){return $value.Substring($root.Length).Trim('/')}
    return $value.TrimStart('/')
}
function Get-DirectFolders([string]$ServerRelativeUrl) {
    $relative=To-SiteRelative $ServerRelativeUrl
    @(Get-PnPFolderItem -FolderSiteRelativeUrl $relative -ItemType Folder -ErrorAction Stop |
        Where-Object {$_.Name -ne "Forms"} |
        ForEach-Object {
            [pscustomobject]@{
                Name="$($_.Name)"
                ServerRelativeUrl="$($_.ServerRelativeUrl)"
                ClientObject=$_
            }
        })
}
function Get-FolderItem($Folder) {
    try { Get-PnPProperty -ClientObject $Folder -Property ListItemAllFields -ErrorAction Stop }
    catch { $null }
}
function Get-Permissions($Item) {
    $unique=Get-PnPProperty -ClientObject $Item -Property HasUniqueRoleAssignments
    $list=@()
    if($unique){
        $assignments=Get-PnPProperty -ClientObject $Item -Property RoleAssignments
        foreach($assignment in $assignments){
            $member=Get-PnPProperty -ClientObject $assignment -Property Member
            $bindings=Get-PnPProperty -ClientObject $assignment -Property RoleDefinitionBindings
            $list += [ordered]@{Principal="$($member.Title)";Type="$($member.PrincipalType)";Roles=@($bindings | ForEach-Object {$_.Name});Members=@()}
        }
    }
    [ordered]@{HeritageRompu=[bool]$unique;Permissions=$list}
}

$skip=@("Style Library","Form Templates","Site Assets","Site Pages")
$libs=@(Get-PnPList | Where-Object {$_.BaseTemplate -eq 101 -and -not $_.Hidden -and $skip -notcontains $_.Title})
$allLibraries=@()
$libraryIndex=0
foreach($lib in $libs){
    $libraryIndex++
    $rootUrl="$($lib.RootFolder.ServerRelativeUrl)"
    $root=[ordered]@{Name=$lib.Title;NomInterne=$rootUrl.TrimEnd('/').Split('/')[-1];Type="Bibliotheque";ServerRelativeUrl=$rootUrl;Dossiers=@();Fichiers=@()}
    if($AvecPermissions){$p=Get-Permissions $lib;$root.HeritageRompu=$p.HeritageRompu;$root.Permissions=$p.Permissions}

    $records=[System.Collections.Generic.List[object]]::new()
    $frontier=@(Get-DirectFolders $rootUrl | ForEach-Object {[pscustomobject]@{Folder=$_;Depth=1}})
    while($frontier.Count -gt 0){
        $next=@()
        foreach($record in $frontier){
            [void]$records.Add($record)
            if($record.Depth -lt 3){
                foreach($child in @(Get-DirectFolders "$($record.Folder.ServerRelativeUrl)")){
                    $next += [pscustomobject]@{Folder=$child;Depth=$record.Depth+1}
                }
            }
        }
        $frontier=$next
        Show-Progress (12+($libraryIndex/[math]::Max(1,$libs.Count))*78) "decouverte directe des niveaux 1 a 3" $started $libraryIndex $libs.Count $records.Count
    }

    $nodes=@{$rootUrl=$root}
    $done=0
    foreach($record in $records){
        $folder=$record.Folder
        $url="$($folder.ServerRelativeUrl)"
        $node=[ordered]@{Name="$($folder.Name)";Type="Dossier";ServerRelativeUrl=$url;Dossiers=@();Fichiers=@()}
        if($AvecPermissions){
            $item=Get-FolderItem $folder.ClientObject
            if($item){$p=Get-Permissions $item;$node.HeritageRompu=$p.HeritageRompu;$node.Permissions=$p.Permissions}
        }
        $nodes[$url]=$node
        $parent=$url.Substring(0,$url.LastIndexOf('/'))
        if($nodes.ContainsKey($parent)){$nodes[$parent].Dossiers += $node}else{$root.Dossiers += $node}
        $done++
        Show-Progress (12+($libraryIndex/[math]::Max(1,$libs.Count))*78) "dossier niveau $($record.Depth) traite" $started $libraryIndex $libs.Count $done
    }
    Ok "$($lib.Title) : $($records.Count) dossier(s), 0 fichier"
    $allLibraries += $root
}

$architecture=[ordered]@{
    Mode="Bibliotheque -> dossier niveau 1 -> dossier niveau 2 -> dossier niveau 3"
    ProfondeurMax=3
    FichiersInclus=$false
    PermissionsInclus=[bool]$AvecPermissions
    Site=[ordered]@{Titre=$web.Title;Url=$web.Url;CaptureLe=(Get-Date -Format "yyyy-MM-dd HH:mm:ss")}
    Bibliotheques=$allLibraries
}
if([string]::IsNullOrWhiteSpace($OutputDir)){$OutputDir=Join-Path $ScriptRoot "architecture\$($SiteUrl.TrimEnd('/').Split('/')[-1])"}
if(-not [IO.Path]::IsPathRooted($OutputDir)){$OutputDir=Join-Path $ScriptRoot $OutputDir}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$json=$architecture | ConvertTo-Json -Depth 30
$stamp=Get-Date -Format "yyyyMMdd_HHmmss"
$dated=Join-Path $OutputDir "architecture-3-niveaux-direct_$stamp.json"
$latest=Join-Path $OutputDir "architecture-3-niveaux-direct-latest.json"
Set-Content -LiteralPath $dated -Value $json -Encoding UTF8
Set-Content -LiteralPath $latest -Value $json -Encoding UTF8
Disconnect-PnPOnline
Show-Progress 100 "export JSON termine" $started $libs.Count $libs.Count (($allLibraries | ForEach-Object {$_.Dossiers.Count} | Measure-Object -Sum).Sum)
Write-Host "`nJSON genere : $latest" -ForegroundColor Green

