[CmdletBinding()]
param(
    [ValidateSet('Install','Reinstall','Repair','Doctor','Uninstall')]
    [string]$Action = 'Install',
    [ValidateSet('Win','Caps')]
    [string]$MainModifier = 'Caps',
    [switch]$NonInteractive,
    [switch]$ForceReinstall,
    [switch]$ForceUninstall,
    [switch]$RemoveDependencies
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = 'reggieaalbios/Win11-window-tilling'
$headers = @{ 'User-Agent'='Win11WindowTilling-bootstrap-dev' }

try {
    $commit = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri "https://api.github.com/repos/$repository/commits/dev"
    $resolvedCommit = [string]$commit.sha
    if ($resolvedCommit -notmatch '^[0-9a-fA-F]{40}$') { throw 'GitHub returned an invalid commit identifier for dev.' }
    $bootstrapUri = "https://raw.githubusercontent.com/$repository/$resolvedCommit/bootstrap.ps1"
    $bootstrapSource = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri $bootstrapUri
} catch {
    throw "Could not resolve and download the dev bootstrap: $($_.Exception.Message)"
}
if ([string]::IsNullOrWhiteSpace([string]$bootstrapSource)) {
    throw "Bootstrap script at '$bootstrapUri' was empty. Refusing to execute."
}

$bootstrap = [scriptblock]::Create([string]$bootstrapSource)
$bootstrapParameterNames = @($bootstrap.Ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
})
foreach ($requiredParameter in @('Ref','ExpectedCommit')) {
    if ($bootstrapParameterNames -notcontains $requiredParameter) {
        throw "Remote dev commit '$resolvedCommit' contains an older bootstrap.ps1 without -$requiredParameter. The local working-tree fixes are not available remotely yet. Run '.\install.ps1 -Action $Action -MainModifier $MainModifier -PauseOnFailure' for the local test, or commit and push the fixes before using bootstrap-dev.ps1."
    }
}
$bootstrapArguments = @{
    Action = $Action
    MainModifier = $MainModifier
    Ref = 'dev'
    ExpectedCommit = $resolvedCommit
}
if ($NonInteractive) { $bootstrapArguments.NonInteractive = $true }
if ($ForceReinstall) { $bootstrapArguments.ForceReinstall = $true }
if ($ForceUninstall) { $bootstrapArguments.ForceUninstall = $true }
if ($RemoveDependencies) { $bootstrapArguments.RemoveDependencies = $true }

try {
    & $bootstrap @bootstrapArguments
} catch {
    throw "Development bootstrap failed: $($_.Exception.Message)"
}
