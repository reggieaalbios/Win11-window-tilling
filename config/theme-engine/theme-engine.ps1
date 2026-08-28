[CmdletBinding()]
param(
    [ValidateSet('Apply','Generate','RestoreLastGood','ApplySafe','Doctor','Startup')]
    [string]$Mode = 'Doctor',
    [string]$Image,
    [string]$TargetUserProfile = $env:USERPROFILE,
    [string]$TargetLocalAppData = $env:LOCALAPPDATA,
    [string]$StateRoot,
    [switch]$NoReload,
    [switch]$NoSystemAccent
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AdaptiveTheme.psm1') -Force

try {
    $parameters = @{
        Mode = $Mode
        TargetUserProfile = $TargetUserProfile
        TargetLocalAppData = $TargetLocalAppData
        NoReload = $NoReload
        NoSystemAccent = $NoSystemAccent
    }
    if ($Image) { $parameters.Image = $Image }
    if ($StateRoot) { $parameters.StateRoot = $StateRoot }
    $result = Invoke-AdaptiveTheme @parameters
    if ($null -ne $result) { $result | ConvertTo-Json -Depth 20 }
    if ($Mode -eq 'RestoreLastGood') { exit 20 }
    if ($result -and $result.PSObject.Properties.Name -contains 'fallback' -and $result.fallback) { exit 10 }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if ($Mode -eq 'Apply') {
        try {
            $recovery = Invoke-AdaptiveTheme -Mode RestoreLastGood -TargetUserProfile $TargetUserProfile -TargetLocalAppData $TargetLocalAppData -StateRoot $StateRoot -NoReload:$NoReload -NoSystemAccent:$NoSystemAccent
            $recovery | ConvertTo-Json -Depth 20
            exit 20
        }
        catch {
            try {
                $safe = Invoke-AdaptiveTheme -Mode ApplySafe -TargetUserProfile $TargetUserProfile -TargetLocalAppData $TargetLocalAppData -StateRoot $StateRoot -NoReload:$NoReload -NoSystemAccent:$NoSystemAccent
                $safe | ConvertTo-Json -Depth 20
                exit 10
            }
            catch { [Console]::Error.WriteLine("Safe-theme recovery failed: $($_.Exception.Message)") }
        }
    }
    exit 1
}
