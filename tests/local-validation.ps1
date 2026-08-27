[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('wwt-local-tests-' + [guid]::NewGuid().ToString('N'))
$originalUserProfile = $env:USERPROFILE
$originalLocalAppData = $env:LOCALAPPDATA

function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $scripts = @('bootstrap.ps1','bootstrap-dev.ps1','install.ps1','src\Win11WindowTiling.psm1','scripts\render-config.ps1')
    foreach ($relative in $scripts) {
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot $relative),[ref]$tokens,[ref]$errors) | Out-Null
        Assert (-not $errors) "PowerShell parse failed: $relative`n$($errors | Out-String)"
    }
    $bootstrapText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'bootstrap.ps1') -Raw
    Assert ($bootstrapText -notmatch '(?im)^\s*(git|gh)\s') 'Bootstrap must not require Git or GitHub CLI.'
    Assert ($bootstrapText -match 'resolvedCommit' -and $bootstrapText -match 'archiveHash' -and $bootstrapText -match 'snapshot.json') 'Bootstrap provenance recording is incomplete.'
    Assert ($bootstrapText -match "\[string\]\`$Ref = 'main'") 'Stable bootstrap must follow main by default.'
    $developmentBootstrapText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'bootstrap-dev.ps1') -Raw
    Assert ($developmentBootstrapText -match '/dev/bootstrap\.ps1') 'Development entrypoint must load the bootstrap implementation from dev.'
    Assert ($developmentBootstrapText -match "Ref = 'dev'") 'Development entrypoint must explicitly select dev.'

    $manifest = Get-Content -LiteralPath (Join-Path $repositoryRoot 'manifests\components.json') -Raw | ConvertFrom-Json
    $immutable = Get-Content -LiteralPath (Join-Path $repositoryRoot 'manifests\immutable-assets.json') -Raw | ConvertFrom-Json
    Assert ($manifest.schemaVersion -eq 2) 'Manifest schema 2 is required.'
    Assert ($manifest.dependencyPolicy.ordinaryPackages -eq 'skip-capable-or-install-latest-stable') 'Ordinary dependency policy is incorrect.'
    Assert (-not $manifest.dependencyPolicy.allowPrerelease) 'Prerelease dependencies must be disabled.'
    $ordinary = @($manifest.components | Where-Object installStrategy -eq 'winget-stable')
    Assert ($ordinary.Count -ge 6) 'The ordinary stable dependency set is incomplete.'
    Assert (-not @($ordinary | Where-Object { $_.PSObject.Properties.Name -contains 'version' })) 'Ordinary dependencies must not be exact-version locked.'
    foreach ($id in @('yasb','dwmblurglass')) {
        Assert (@($manifest.dependencyPolicy.immutableExceptions | Where-Object { $_ -eq $id }).Count -eq 1) "Missing immutable exception: $id"
    }
    $yasb = @($manifest.components | Where-Object id -eq 'yasb')[0]
    $yasbLock = @($immutable.assets | Where-Object component -eq 'yasb')[0]
    Assert ($yasb.asset.url -eq $yasbLock.url -and $yasb.asset.sha256 -eq $yasbLock.sha256) 'YASB manifest and immutable lock disagree.'
    $dwm = @($manifest.components | Where-Object id -eq 'dwmblurglass')[0]
    $dwmLock = @($immutable.assets | Where-Object component -eq 'dwmblurglass')[0]
    Assert ($dwm.compatibility[0].url -eq $dwmLock.url -and $dwm.compatibility[0].sha256 -eq $dwmLock.sha256) 'DWMBlurGlass manifest and immutable lock disagree.'
    $markerPath = Join-Path $temporaryRoot 'wwt-build.json'
    $marker = [ordered]@{ assetSha256=[string]$yasb.asset.sha256; version=[string]$yasb.asset.version } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($markerPath,$marker,(New-Object Text.UTF8Encoding($false)))
    Assert ((Get-FileHash $markerPath -Algorithm SHA256).Hash -eq $yasb.requiredFingerprint) 'Patched YASB fingerprint metadata does not match the manifest.'

    foreach ($modifier in @('Win','Caps')) {
        $renderRoot = Join-Path $temporaryRoot "render-$modifier"
        & (Join-Path $repositoryRoot 'scripts\render-config.ps1') -OutputRoot $renderRoot -MainModifier $modifier | Out-Null
        Assert (Test-Path -LiteralPath (Join-Path $renderRoot '.config\komorebi\komorebi.ahk')) "Renderer failed for $modifier."
    }

    Import-Module (Join-Path $repositoryRoot 'src\Win11WindowTiling.psm1') -Force
    Assert (-not (Test-WwtAutoHotkeyV2 -Path 'C:\Program Files\AutoHotkey\v1\AutoHotkey.exe' -Version '1.1.37')) 'AutoHotkey v1 was incorrectly accepted.'
    Assert (Test-WwtAutoHotkeyV2 -Path 'C:\Users\test\AppData\Local\Programs\AutoHotkey\v2\AutoHotkey64.exe' -Version $null) 'AutoHotkey v2 path was rejected.'
    Assert (Test-WwtAutoHotkeyV2 -Path 'C:\tools\AutoHotkey64.exe' -Version '2.0.19') 'AutoHotkey v2 version was rejected.'

    # Isolated complete-target backup, purge, and rollback.
    $env:USERPROFILE = Join-Path $temporaryRoot 'profile'
    $env:LOCALAPPDATA = Join-Path $temporaryRoot 'local'
    $komorebi = Join-Path $env:USERPROFILE '.config\komorebi'
    $yasb = Join-Path $env:USERPROFILE '.config\yasb'
    New-Item -ItemType Directory -Path $komorebi,$yasb -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $komorebi 'original.txt'),'komorebi-before')
    [IO.File]::WriteAllText((Join-Path $yasb 'original.txt'),'yasb-before')
    $backup = Backup-WwtStack -RepositoryRoot $repositoryRoot -OperationId 'rollback-test'
    Remove-WwtManagedTargets
    Assert (-not (Test-Path -LiteralPath $komorebi)) 'Managed target purge failed.'
    Restore-WwtStack -BackupRecordPath $backup.RecordPath
    Assert ((Get-Content -LiteralPath (Join-Path $komorebi 'original.txt') -Raw) -eq 'komorebi-before') 'Komorebi rollback failed.'
    Assert ((Get-Content -LiteralPath (Join-Path $yasb 'original.txt') -Raw) -eq 'yasb-before') 'YASB rollback failed.'
    foreach ($failureStage in @('before-purge','dependency-installation','config-deployment','startup-registration')) {
        [IO.File]::WriteAllText((Join-Path $komorebi 'original.txt'),("before-" + $failureStage))
        $transactionBackup = Backup-WwtStack -RepositoryRoot $repositoryRoot -OperationId ("failure-" + $failureStage)
        try {
            if ($failureStage -ne 'before-purge') {
                Remove-WwtManagedTargets
                New-Item -ItemType Directory -Path $komorebi -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $komorebi 'partial.txt'),'partial-new-state')
            }
            throw "Injected $failureStage"
        } catch {
            Remove-WwtManagedTargets
            Restore-WwtStack -BackupRecordPath $transactionBackup.RecordPath
        }
        Assert (Test-Path -LiteralPath (Join-Path $komorebi 'original.txt')) "Rollback omitted the original file for injected stage: $failureStage"
        Assert ((Get-Content -LiteralPath (Join-Path $komorebi 'original.txt') -Raw) -eq ("before-" + $failureStage)) "Rollback content failed for injected stage: $failureStage"
        Assert (-not (Test-Path -LiteralPath (Join-Path $komorebi 'partial.txt'))) "Partial state survived rollback: $failureStage"
    }

    # Existing-install N must exit before creating product/cache/source state.
    $declineRoot = Join-Path $temporaryRoot 'decline-profile'
    $declineLocal = Join-Path $temporaryRoot 'decline-local'
    New-Item -ItemType Directory -Path (Join-Path $declineRoot '.config\komorebi') -Force | Out-Null
    $inputPath = Join-Path $temporaryRoot 'decline.txt'
    [IO.File]::WriteAllText($inputPath,"n`r`n")
    $oldProfile=$env:USERPROFILE; $oldLocal=$env:LOCALAPPDATA
    $env:USERPROFILE=$declineRoot; $env:LOCALAPPDATA=$declineLocal
    $process = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $repositoryRoot 'bootstrap.ps1')) -RedirectStandardInput $inputPath -Wait -PassThru -WindowStyle Hidden
    $env:USERPROFILE=$oldProfile; $env:LOCALAPPDATA=$oldLocal
    Assert ($process.ExitCode -eq 0) 'Declined reinstall did not exit successfully.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $declineLocal 'Win11WindowTilling'))) 'Declined reinstall changed product state or downloaded a snapshot.'

    $installText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'install.ps1') -Raw
    foreach ($stage in @('prepare-new','inventory','backup','stop','purge','dependencies','configuration','doctor')) {
        Assert ($installText -match [regex]::Escape("'$stage'")) "Reinstall stage is missing: $stage"
    }
    Assert ($installText -match 'Restore-WwtStack') 'Automatic rollback hook is missing.'
    Assert ($installText -match 'Non-interactive reinstall requires -ForceReinstall') 'Destructive unattended guard is missing.'
    Assert ($installText -match "Read-Host 'Press Enter to close this installer window'") 'Interactive elevated failures do not remain visible.'
    Assert ($installText -match 'Write-Error[^\r\n]+-ErrorAction Continue') 'Failure reporting can terminate before the interactive pause.'
    Assert ($installText -notmatch "'download'[^\r\n]+--architecture") 'WinGet download must allow mixed-architecture dependency graphs.'
    $bootstrapText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'bootstrap.ps1') -Raw
    Assert ($bootstrapText -notmatch 'if \(\$LASTEXITCODE -ne 0\) \{ exit') 'Bootstrap must not close the caller PowerShell session on installer failure.'
    Assert ($bootstrapText -match "previousOperation\.status -in @\('failed','running'\)") 'Bootstrap does not continue failed and interrupted installs through repair.'
    Assert ($installText -match 'function Remove-WwtOperationCaches') 'Bounded operation-cache cleanup is missing.'
    Assert ($installText -match 'Remove-WwtOperationCaches -KeepOperationIds @\(\$operationId\)') 'Failed-operation cache retention is not bounded to the current operation.'
    Assert ($installText -match 'if \(\$Name -eq ''complete''\) \{ ''complete'' \}') 'Completed operations remain marked as running.'
    $moduleText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\Win11WindowTiling.psm1') -Raw
    Assert ($moduleText -notmatch 'Select-Object\s+-Reverse') 'Module uses Select-Object -Reverse, which is unavailable in Windows PowerShell 5.1.'
    Assert ($moduleText -notmatch '\$missing\.Name') 'Missing dependency reporting must use the inventory id property.'
    Assert ($installText.IndexOf("Installed DWMBlurGlass '") -gt $installText.IndexOf("installStrategy -eq 'guarded-dwm'")) 'DWM recovery validation is outside the guarded DWM preparation block.'
    foreach ($failure in @('before-purge','dependency-installation','config-deployment','startup-registration')) {
        Assert ($installText -match [regex]::Escape($failure)) "Failure injection hook is missing: $failure"
    }

    [pscustomobject]@{
        Status='PASS'; PowerShell51Parsing=$true; ModifierVariants=2; AutoHotkeyV1Rejected=$true
        AutoHotkeyV2Accepted=$true; DeclineWasZeroChange=$true; BackupRollback=$true
        InjectedRollbackScenarios=4; RemoteCI=$false
    }
}
finally {
    $env:USERPROFILE=$originalUserProfile
    $env:LOCALAPPDATA=$originalLocalAppData
    Remove-Module Win11WindowTiling -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
