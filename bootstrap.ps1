[CmdletBinding()]
param(
    [ValidateSet('Install','Reinstall','Repair','Doctor','Uninstall')]
    [string]$Action = 'Install',
    [ValidateSet('Win','Caps')]
    [string]$MainModifier = 'Win',
    [switch]$NonInteractive,
    [switch]$ForceReinstall,
    [string]$Repository = 'reggieaalbios/Win11-window-tilling',
    [string]$Ref = 'main'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$productRoot = Join-Path $env:LOCALAPPDATA 'Win11WindowTilling'
$statePath = Join-Path $productRoot 'install-state.json'

function Test-WwtExistingInstall {
    if (Test-Path -LiteralPath $statePath) { return $true }
    $targets = @(
        (Join-Path $env:USERPROFILE '.config\komorebi'),
        (Join-Path $env:USERPROFILE '.config\yasb'),
        (Join-Path $env:USERPROFILE '.config\theme-engine'),
        (Join-Path $env:USERPROFILE '.wezterm.lua'),
        (Join-Path $env:ProgramFiles 'komorebi\bin\komorebi.exe'),
        (Join-Path $env:ProgramFiles 'YASB\yasb.exe')
    )
    return [bool](@($targets | Where-Object { Test-Path -LiteralPath $_ }).Count)
}
function Ensure-WinGet {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) { return }
    Write-Host 'Windows Package Manager is missing; acquiring Microsoft App Installer...' -ForegroundColor Yellow
    $bundle = Join-Path $downloadRoot 'Microsoft.DesktopAppInstaller.msixbundle'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/getwinget' -OutFile $bundle
    $signature = Get-AuthenticodeSignature -LiteralPath $bundle
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
        throw 'Microsoft App Installer signature validation failed; the desktop was not changed.'
    }
    try { Add-AppxPackage -Path $bundle -ErrorAction Stop } catch { throw "Microsoft App Installer could not be installed safely: $($_.Exception.Message)" }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw 'WinGet remains unavailable after Microsoft App Installer repair.' }
}

if ($Action -eq 'Install' -and (Test-WwtExistingInstall)) {
    Write-Host 'Win11 Window Tiling is already installed.' -ForegroundColor Yellow
    if ($NonInteractive) {
        if (-not $ForceReinstall) { exit 0 }
        $Action = 'Reinstall'
    } else {
        $answer = Read-Host 'Do you wish to reinstall? [y/N]'
        if ($answer -notmatch '^[Yy]$') { exit 0 }
        $Action = 'Reinstall'
    }
}
if ($Action -eq 'Reinstall' -and $NonInteractive -and -not $ForceReinstall) {
    Write-Host 'Non-interactive reinstall requires -ForceReinstall; no changes were made.' -ForegroundColor Yellow
    exit 0
}

$operationId = [guid]::NewGuid().ToString('N')
$downloadRoot = Join-Path $productRoot (Join-Path 'cache' $operationId)
$archivePath = Join-Path $downloadRoot 'source.zip'
$extractRoot = Join-Path $downloadRoot 'extracted'
New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

try {
    $commitApi = "https://api.github.com/repos/$Repository/commits/$Ref"
    $headers = @{ 'User-Agent'='Win11WindowTilling-bootstrap' }
    $commit = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri $commitApi
    if ([string]::IsNullOrWhiteSpace([string]$commit.sha)) { throw "GitHub did not resolve '$Ref' to a commit." }
    $resolvedCommit = [string]$commit.sha
    $archiveUrl = "https://github.com/$Repository/archive/$resolvedCommit.zip"
    Write-Host "Downloading $Repository at $resolvedCommit..." -ForegroundColor Cyan
    Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $archiveUrl -OutFile $archivePath
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
    $sourceRoot = @(Get-ChildItem -LiteralPath $extractRoot -Directory)[0].FullName
    foreach ($required in @('install.ps1','src\Win11WindowTiling.psm1','manifests\components.json','scripts\render-config.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $required))) { throw "Downloaded snapshot is invalid: missing $required" }
    }
    Ensure-WinGet

    $snapshotRoot = Join-Path $productRoot (Join-Path 'source' $resolvedCommit)
    if (Test-Path -LiteralPath $snapshotRoot) { Remove-Item -LiteralPath $snapshotRoot -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $snapshotRoot) -Force | Out-Null
    Move-Item -LiteralPath $sourceRoot -Destination $snapshotRoot
    $provenance = [ordered]@{
        schemaVersion=1; repository=$Repository; ref=$Ref; commit=$resolvedCommit
        archiveUrl=$archiveUrl; archiveSha256=$archiveHash; acquiredAt=(Get-Date).ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $snapshotRoot 'snapshot.json'),($provenance | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    Write-Host "Snapshot verified (SHA-256 $archiveHash)." -ForegroundColor Green

    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $snapshotRoot 'install.ps1'),'-Action',$Action,'-MainModifier',$MainModifier,'-SnapshotCommit',$resolvedCommit,'-SnapshotSha256',$archiveHash)
    if ($NonInteractive) { $arguments += '-NonInteractive' }
    if ($ForceReinstall) { $arguments += '-ForceReinstall' }
    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    if (Test-Path -LiteralPath $downloadRoot) { Remove-Item -LiteralPath $downloadRoot -Recurse -Force }
}
