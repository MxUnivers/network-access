<#
.SYNOPSIS
Genere un certificat auto-signe pour l'authentification app-only
(Microsoft Graph + PnP PowerShell) et exporte la partie publique (.cer)
a televerser dans l'App Registration Entra ID.

.DESCRIPTION
A executer UNE SEULE FOIS, sur la machine qui lancera le script planifie
(le certificat prive reste dans le magasin de l'utilisateur courant).

.EXEMPLE
.\New-SPOAppCertificate.ps1
#>

$ErrorActionPreference = "Stop"

$Subject   = "CN=SPO-Permissions-Automation"
$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }
$CerPath   = Join-Path $ScriptRoot "SPO-Permissions-Automation.cer"

Write-Host "Creation du certificat auto-signe..." -ForegroundColor Cyan

$cert = New-SelfSignedCertificate `
    -Subject           $Subject `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy   Exportable `
    -KeySpec           Signature `
    -KeyAlgorithm      RSA `
    -KeyLength         2048 `
    -NotAfter          (Get-Date).AddYears(2)

# Export de la cle PUBLIQUE (.cer) a televerser dans Azure
Export-Certificate -Cert $cert -FilePath $CerPath | Out-Null

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host " Certificat cree avec succes." -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host " Empreinte (Thumbprint) a coller dans PermissionsConfig.json :" -ForegroundColor Yellow
Write-Host "   $($cert.Thumbprint)" -ForegroundColor White
Write-Host ""
Write-Host " Fichier public a televerser dans l'App Registration Azure :" -ForegroundColor Yellow
Write-Host "   $CerPath" -ForegroundColor White
Write-Host ""
Write-Host " Expiration du certificat : $($cert.NotAfter)" -ForegroundColor Gray
Write-Host ""
Write-Host " Prochaine etape : Azure Portal > App Registration > Certificates & secrets" -ForegroundColor Cyan
Write-Host " > Certificates > Upload certificate > selectionnez le fichier .cer ci-dessus." -ForegroundColor Cyan
