[CmdletBinding()]
param(
    [ValidateSet('Install','Reinstall','Repair','Doctor','Uninstall')]
    [string]$Action = 'Install',
    [ValidateSet('Win','Caps')]
    [string]$MainModifier = 'Win',
    [switch]$NonInteractive,
    [switch]$ForceReinstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$bootstrapUri = 'https://raw.githubusercontent.com/reggieaalbios/Win11-window-tilling/dev/bootstrap.ps1'

try {
    $bootstrapSource = Invoke-RestMethod -UseBasicParsing -Uri $bootstrapUri
} catch {
    throw "Could not download bootstrap script from '$bootstrapUri': $($_.Exception.Message)"
}
if ([string]::IsNullOrWhiteSpace([string]$bootstrapSource)) {
    throw "Bootstrap script at '$bootstrapUri' was empty. Refusing to execute."
}

$bootstrap = [scriptblock]::Create([string]$bootstrapSource)
$bootstrapArguments = @{
    Action = $Action
    MainModifier = $MainModifier
    Ref = 'dev'
}
if ($NonInteractive) { $bootstrapArguments.NonInteractive = $true }
if ($ForceReinstall) { $bootstrapArguments.ForceReinstall = $true }

& $bootstrap @bootstrapArguments