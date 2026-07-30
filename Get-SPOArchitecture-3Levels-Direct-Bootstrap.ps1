param(
    [string]$ConfigFile,
    [string]$SiteUrl,
    [string]$OutputDir,
    [string]$LibraryName,
    [switch]$SansSitePermissions,
    [switch]$AvecPermissions
)

$ModulesDir=Join-Path $env:LOCALAPPDATA "SPO-Automation\Modules"
if(-not (Test-Path $ModulesDir)){New-Item -ItemType Directory -Path $ModulesDir -Force | Out-Null}
if(($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $ModulesDir){
    $env:PSModulePath=$ModulesDir+[IO.Path]::PathSeparator+$env:PSModulePath
}
if(-not (Get-Module -ListAvailable -Name PnP.PowerShell)){
    Save-PSResource -Name PnP.PowerShell -Path $ModulesDir -TrustRepository -IncludeXml -SkipDependencyCheck -ErrorAction Stop
}

$target=Join-Path $PSScriptRoot "Get-SPOArchitecture-3Levels-Direct.ps1"
& $target @PSBoundParameters
exit $LASTEXITCODE


