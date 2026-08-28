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
    $scripts = @('bootstrap.ps1','bootstrap-dev.ps1','install.ps1','uninstall.ps1','src\Win11WindowTiling.psm1','scripts\render-config.ps1')
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
        $renderedYasb = Get-Content -LiteralPath (Join-Path $renderRoot '.config\yasb\config.yaml') -Raw
        $renderedKomorebi = Get-Content -LiteralPath (Join-Path $renderRoot '.config\komorebi\komorebi.json') -Raw
        $renderedShortcuts = Get-Content -LiteralPath (Join-Path $renderRoot '.config\yasb\shortcuts.json') -Raw | ConvertFrom-Json
        $renderedAhk = Get-Content -LiteralPath (Join-Path $renderRoot '.config\komorebi\komorebi.ahk') -Raw
        Assert ($renderedYasb -match 'data_path: "[A-Za-z]:/') "YASB shortcut data_path is not rendered as a YAML-safe Windows path for $modifier."
        Assert ($renderedYasb -notmatch 'data_path: "[A-Za-z]:\\') "YASB shortcut data_path contains unescaped backslashes for $modifier."
        foreach ($visibleWidget in @('quick_launch','wallpapers','power_menu')) {
            Assert ($renderedYasb -match "(?s)$visibleWidget\:.*label\: '<img src=") "YASB $visibleWidget does not render a visible image label for $modifier."
        }
        Assert ($renderedKomorebi -match '"app_specific_configuration_path": "[A-Za-z]:/.+/.config/komorebi/applications.json"') "Komorebi application config path is not rendered as an absolute path for $modifier."
        Assert ($renderedKomorebi -notmatch '\$Env:KOMOREBI_CONFIG_HOME|{{USER_PROFILE_URI}}') "Komorebi config contains unresolved environment or render tokens for $modifier."
        $komorebiObject = $renderedKomorebi | ConvertFrom-Json
        Assert (@($komorebiObject.monitors[0].workspaces).Count -eq 9) "Komorebi must render nine preconfigured workspaces for $modifier."
        foreach ($workspace in 6..9) {
            $zeroBased = $workspace - 1
            Assert ($renderedAhk -match "(?m)^$workspace::Komorebic\(`"focus-workspace $zeroBased`"\)") "AHK focus binding is missing for workspace $workspace with $modifier."
            Assert ($renderedAhk -match "(?m)^\+$workspace::MoveAndFollow\($zeroBased\)") "AHK move-and-follow binding is missing for workspace $workspace with $modifier."
        }
        Assert (@($renderedShortcuts.sections.items | Where-Object { $_.keys -contains '1-9' }).Count -ge 1) "Shortcut guide does not describe workspaces 1-9 for $modifier."
        if ($modifier -eq 'Win') {
            Assert (-not (@($renderedShortcuts.sections.items.keys) -contains 'Caps')) 'Win shortcut guide leaked Caps labels.'
        }
        foreach ($wallpaperName in @('wwt-mountain-dawn.png','jakoolit-anime-purple-eyes.png')) {
            Assert (Test-Path -LiteralPath (Join-Path $renderRoot "Pictures\Wallpapers\$wallpaperName")) "Renderer did not copy bundled wallpaper $wallpaperName for $modifier."
        }
    }
    $yasbStyle = Get-Content -LiteralPath (Join-Path $repositoryRoot 'config\yasb\styles.css') -Raw
    Assert ($yasbStyle -notmatch '\.komorebi-workspaces \.ws-btn\.button-[6-9]') 'YASB CSS hides workspace buttons 6-9.'
    foreach ($visibleClass in @('quick-launch-widget','wallpapers-widget','power-menu-widget')) {
        Assert ($yasbStyle -match "(?s)\.$visibleClass.*min-width:\s*22px") "YASB CSS does not keep $visibleClass visible."
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
    $bootstrapPath = Join-Path $repositoryRoot 'bootstrap.ps1'
    & cmd.exe /d /c "type `"$inputPath`" | powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$bootstrapPath`""
    $declineExitCode = $LASTEXITCODE
    $env:USERPROFILE=$oldProfile; $env:LOCALAPPDATA=$oldLocal
    Assert ($declineExitCode -eq 0) 'Declined reinstall did not exit successfully.'
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
    Assert ($moduleText -match "DWMBlurGlass_Extend'") 'DWMBlurGlass health must verify its logon task.'
    Assert ($moduleText -match 'dwmblurglass-state\.json') 'DWMBlurGlass health must verify deployment state.'
    Assert ($moduleText -match 'PreserveGuardedDwm') 'Full reinstall must preserve healthy guarded DWM components that Windows may lock.'
    Assert ($moduleText -match 'installStrategy -eq ''guarded-dwm'' -and \$current\.capable') 'Healthy guarded DWM components must be skipped during forced dependency reinstall.'
    Assert ($moduleText -match 'komorebi-config') 'Doctor must validate the rendered Komorebi config.'
    Assert ($moduleText -match 'yasb-config') 'Doctor must validate the rendered YASB config.'
    $startupText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'config\komorebi\start-komorebi.ps1') -Raw
    Assert ($startupText -match '\$env:ProgramFiles ''AutoHotkey\\v2\\AutoHotkey64\.exe''') 'Startup must find the Program Files AutoHotkey v2 install.'
    Assert ($startupText -match '\$env:LOCALAPPDATA ''Programs\\AutoHotkey\\v2\\AutoHotkey64\.exe''') 'Startup must retain the per-user AutoHotkey v2 fallback.'
    Assert ($installText.IndexOf("Installed DWMBlurGlass '") -gt $installText.IndexOf("installStrategy -eq 'guarded-dwm'")) 'DWM recovery validation is outside the guarded DWM preparation block.'
    $uninstallText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'uninstall.ps1') -Raw
    Assert ($uninstallText -match 'Non-interactive uninstall purge requires -Force') 'Uninstall purge must guard unattended destructive runs.'
    Assert ($uninstallText -match '\[switch\]\$ElevatedRelaunch') 'Uninstall purge must mark the elevated relaunch to prevent confusing loops.'
    Assert ($uninstallText -match 'UAC returned without administrator rights') 'Uninstall purge must clearly fail if elevation does not produce admin rights.'
    Assert ($uninstallText -match '\[string\]\$LogPath') 'Elevated uninstall failures must support a persistent transcript path.'
    Assert ($uninstallText -match 'Win11WindowTilling\\uninstall-logs') 'Uninstall diagnostics must survive product-cache removal.'
    Assert ($uninstallText -match 'Details: \$elevatedLogPath') 'The parent process must reveal the elevated uninstall log path.'
    $powerShellQuoteEscape = [regex]::Escape("-replace '`"','`"`"'")
    Assert ($uninstallText -match $powerShellQuoteEscape) 'Elevation arguments must use Windows PowerShell-compatible quote escaping.'
    Assert ($uninstallText -notmatch 'exit \$process\.ExitCode') 'Successful elevation must not close the caller PowerShell session.'
    Assert ($uninstallText -match 'Invoke-SelfElevation\s+return') 'The unelevated script must return after the elevated child completes.'
    Assert ($uninstallText -match 'cleanup warning\(s\)') 'Partial cleanup must not be reported as a complete purge.'
    Assert ($uninstallText -match 'komorebi,komorebic,yasb,yasbc,cava') 'Uninstall must stop every managed desktop process, including Cava.'
    Assert ($uninstallText -match 'MoveFileEx') 'Locked injected files must be scheduled for deletion after reboot.'
    Assert ($uninstallText -match "New-ScheduledTaskTrigger -AtStartup") 'MoveFileEx failures must fall back to an early-boot cleanup task.'
    Assert ($uninstallText -match "New-ScheduledTaskPrincipal -UserId 'SYSTEM'") 'Early-boot cleanup must run as SYSTEM before user apps can relock files.'
    Assert ($uninstallText -match 'Win11WindowTilling Uninstall Cleanup') 'Early-boot cleanup must use a deterministic self-removing task.'
    Assert ($uninstallText -match '\[switch\]\$Reboot') 'Unattended uninstall must provide an explicit reboot switch.'
    Assert ($uninstallText -match 'Press Enter to reboot now') 'Interactive uninstall must offer to reboot when locked cleanup remains.'
    Assert ($uninstallText -match '\$NonInteractive[\s\S]+rerun with -Reboot') 'Non-interactive uninstall must not block on a reboot prompt.'
    Assert ($uninstallText -match 'foreach \(\$target in @\(Get-WwtManagedTargets\)\)') 'A locked managed target must not prevent later targets from being removed.'
    foreach ($requiredCall in @('Stop-WwtProcesses','Remove-WwtStartupEntries','Uninstall-WwtConfiguration','Remove-WwtManagedTargets','Uninstall-WwtDependencies','Remove-WwtDependencyLeftovers','Remove-KnownPath -Path \$paths\.ProductRoot')) {
        Assert ($uninstallText -match $requiredCall) "Uninstall purge is missing step: $requiredCall"
    }
    foreach ($dependencyPath in @('komorebi','YASB','WezTerm','AutoHotkey','DWMBlurGlass','oh-my-posh','zoxide','cava')) {
        Assert ($uninstallText -match [regex]::Escape($dependencyPath)) "Uninstall purge does not mention dependency leftover: $dependencyPath"
    }
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
