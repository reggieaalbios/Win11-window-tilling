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
    Assert ($developmentBootstrapText -match '\$resolvedCommit/bootstrap\.ps1') 'Development entrypoint must load bootstrap.ps1 from the commit resolved for dev.'
    Assert ($developmentBootstrapText -match "Ref = 'dev'") 'Development entrypoint must explicitly select dev.'
    Assert ($developmentBootstrapText -match 'ExpectedCommit = \$resolvedCommit') 'Development entrypoint must prevent a moving-dev source race.'
    Assert ($developmentBootstrapText -match 'bootstrapParameterNames' -and $developmentBootstrapText -match 'older bootstrap\.ps1') 'Development entrypoint must explain an incompatible remote bootstrap instead of surfacing a parameter-binding error.'
    Assert ($developmentBootstrapText -match '\$ForceUninstall' -and $developmentBootstrapText -match '\$RemoveDependencies') 'Development bootstrap must forward complete uninstall options.'
    foreach ($defaultCapsScript in @('bootstrap.ps1','bootstrap-dev.ps1','install.ps1','scripts\render-config.ps1','src\Win11WindowTiling.psm1')) {
        $defaultCapsText = Get-Content -LiteralPath (Join-Path $repositoryRoot $defaultCapsScript) -Raw
        Assert ($defaultCapsText -match "MainModifier = 'Caps'") "$defaultCapsScript must default to the canonical live Caps modifier."
    }

    $manifest = Get-Content -LiteralPath (Join-Path $repositoryRoot 'manifests\components.json') -Raw | ConvertFrom-Json
    $immutable = Get-Content -LiteralPath (Join-Path $repositoryRoot 'manifests\immutable-assets.json') -Raw | ConvertFrom-Json
    Assert ($manifest.schemaVersion -eq 2) 'Manifest schema 2 is required.'
    Assert ($manifest.dependencyPolicy.ordinaryPackages -eq 'skip-capable-or-install-latest-stable') 'Ordinary dependency policy is incorrect.'
    Assert (-not $manifest.dependencyPolicy.allowPrerelease) 'Prerelease dependencies must be disabled.'
    $ordinary = @($manifest.components | Where-Object installStrategy -eq 'winget-stable')
    Assert ($ordinary.Count -ge 6) 'The ordinary stable dependency set is incomplete.'
    Assert (-not @($ordinary | Where-Object { $_.PSObject.Properties.Name -contains 'version' })) 'Ordinary dependencies must not be exact-version locked.'
    foreach ($id in @('yasb','dwmblurglass','wallpapers')) {
        Assert (@($manifest.dependencyPolicy.immutableExceptions | Where-Object { $_ -eq $id }).Count -eq 1) "Missing immutable exception: $id"
    }
    $yasb = @($manifest.components | Where-Object id -eq 'yasb')[0]
    $yasbLock = @($immutable.assets | Where-Object component -eq 'yasb')[0]
    Assert ($yasb.asset.url -eq $yasbLock.url -and $yasb.asset.sha256 -eq $yasbLock.sha256) 'YASB manifest and immutable lock disagree.'
    $dwm = @($manifest.components | Where-Object id -eq 'dwmblurglass')[0]
    $dwmLock = @($immutable.assets | Where-Object component -eq 'dwmblurglass')[0]
    Assert ($dwm.compatibility[0].url -eq $dwmLock.url -and $dwm.compatibility[0].sha256 -eq $dwmLock.sha256) 'DWMBlurGlass manifest and immutable lock disagree.'
    $wallpapers = @($manifest.components | Where-Object id -eq 'wallpapers')[0]
    $wallpaperLock = @($immutable.assets | Where-Object component -eq 'wallpapers')[0]
    Assert ($wallpapers.asset.commit -eq $wallpaperLock.version -and $wallpapers.asset.fileCount -eq 163 -and $wallpapers.asset.totalBytes -eq 942253131) 'Wallpaper manifest and immutable lock disagree.'
    $dwmConfigurationPath = Join-Path $repositoryRoot 'config\dwmblurglass\config.ini'
    Assert (Test-Path -LiteralPath $dwmConfigurationPath) 'Canonical DWMBlurGlass configuration is missing.'
    $dwmConfiguration = Get-Content -LiteralPath $dwmConfigurationPath -Raw
    foreach ($setting in @('applyglobal=true','customAmount=true','disableFramerateLimit=true','extendRound=10','blurAmount=45','customBlurAmount=41','luminosityOpacity=0.62','effectType=2','blurQuality=1')) {
        Assert ($dwmConfiguration -match "(?m)^$([regex]::Escape($setting))$") "Canonical DWMBlurGlass setting is missing: $setting"
    }
    $dwmDeployText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'scripts\dwmblurglass-deploy.ps1') -Raw
    Assert ($dwmDeployText -match 'ConfigurationPath') 'DWMBlurGlass deployment does not accept the canonical configuration.'
    Assert ($dwmDeployText -match 'Copy-Item -LiteralPath \$ConfigurationPath -Destination \$deployedConfiguration') 'DWMBlurGlass deployment does not apply the canonical configuration.'
    Assert ($dwmDeployText -match 'configurationSha256') 'DWMBlurGlass deployment state does not record the applied configuration.'
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
        $renderedProfile = Get-Content -LiteralPath (Join-Path $renderRoot 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1') -Raw
        $renderedWezTermTheme = [IO.File]::ReadAllText((Join-Path $renderRoot 'wwt-theme.lua'))
        $renderedAhkBytes = [IO.File]::ReadAllBytes((Join-Path $renderRoot '.config\komorebi\komorebi.ahk'))
        Assert (-not ([Text.Encoding]::UTF8.GetString($renderedAhkBytes).Contains("`r"))) "AHK rendering must use canonical LF line endings for $modifier."
        Assert ($renderedProfile -match [regex]::Escape((Join-Path $originalUserProfile '.config\ohmyposh\catppuccin_mocha.omp.json'))) "PowerShell profile did not render its portable Oh My Posh path for $modifier."
        foreach ($terminalFunction in @('dev','win','gs','gb','gr','gsw','gtl','op','t','la')) {
            Assert ($renderedProfile -match "(?m)^function $terminalFunction\s") "PowerShell profile is missing canonical function $terminalFunction for $modifier."
        }
        Assert ($renderedProfile -notmatch '(?m)^function rel\s') "Non-canonical rel function leaked into the PowerShell profile for $modifier."
        Assert (-not $renderedWezTermTheme.EndsWith("`n")) "Generated WezTerm theme serialization differs from the canonical live file for $modifier."
        $renderedOhMyPosh = Get-Content -LiteralPath (Join-Path $renderRoot '.config\ohmyposh\catppuccin_mocha.omp.json') -Raw | ConvertFrom-Json
        Assert ($renderedOhMyPosh.palette.blue -eq '#8D70CC' -and $renderedOhMyPosh.palette.lavender -eq '#816BDE') "Oh My Posh palette differs from the canonical live theme for $modifier."
        Assert ($renderedYasb -match 'data_path: "[A-Za-z]:/') "YASB shortcut data_path is not rendered as a YAML-safe Windows path for $modifier."
        Assert ($renderedYasb -notmatch 'data_path: "[A-Za-z]:\\') "YASB shortcut data_path contains unescaped backslashes for $modifier."
        foreach ($hiddenWidget in @('quick_launch','wallpapers','power_menu')) {
            Assert ($renderedYasb -match "(?s)$hiddenWidget\:.*?label\: `"`"") "YASB $hiddenWidget must retain an empty label for $modifier."
        }
        Assert ($renderedKomorebi -match '"app_specific_configuration_path": "[A-Za-z]:/.+/.config/komorebi/applications.json"') "Komorebi application config path is not rendered as an absolute path for $modifier."
        Assert ($renderedKomorebi -notmatch '\$Env:KOMOREBI_CONFIG_HOME|{{USER_PROFILE_URI}}') "Komorebi config contains unresolved environment or render tokens for $modifier."
        $komorebiObject = $renderedKomorebi | ConvertFrom-Json
        Assert (@($komorebiObject.monitors[0].workspaces).Count -eq 5) "Komorebi must render five preconfigured workspaces for $modifier."
        foreach ($workspace in 1..5) {
            $zeroBased = $workspace - 1
            Assert ($renderedAhk -match "(?m)^$workspace::Komorebic\(`"focus-workspace $zeroBased`"\)") "AHK focus binding is missing for workspace $workspace with $modifier."
            Assert ($renderedAhk -match "(?m)^\+$workspace::MoveAndFollow\($zeroBased\)") "AHK move-and-follow binding is missing for workspace $workspace with $modifier."
        }
        Assert ($renderedAhk -notmatch '(?m)^[6-9]::Komorebic\(') "AHK exposes non-canonical workspaces 6-9 for $modifier."
        Assert ($renderedAhk -notmatch '(?m)^\+[6-9]::MoveAndFollow\(') "AHK exposes non-canonical move bindings 6-9 for $modifier."
        Assert ($komorebiObject.animation.enabled.movement) "Komorebi movement animation must remain enabled for $modifier."
        Assert ($renderedAhk -match '(?s)DisableDragAnimation\(\).*?movement enable') "Drag cleanup must restore movement animation for $modifier."
        Assert ($renderedAhk -match '(?m)^\+d::Komorebic\("cycle-move-to-monitor previous"\)') "Shift+D monitor movement differs from the canonical live mapping for $modifier."
        Assert ($renderedAhk -notmatch '(?m)^\^(Left|Up)::') "Non-canonical Ctrl+Left/Up monitor mappings leaked into $modifier."
        Assert (@($renderedShortcuts.sections.items | Where-Object { $_.keys -contains '1-5' }).Count -ge 1) "Shortcut guide does not match the canonical visible workspaces 1-5 for $modifier."
        if ($modifier -eq 'Win') {
            Assert (-not (@($renderedShortcuts.sections.items.keys) -contains 'Caps')) 'Win shortcut guide leaked Caps labels.'
        }
        foreach ($wallpaperName in @('Anime-Purple-eyes.png','JAKOOLIT-WALLPAPER-SOURCE.txt')) {
            Assert (Test-Path -LiteralPath (Join-Path $renderRoot "Pictures\Wallpapers\$wallpaperName")) "Renderer did not copy bundled wallpaper $wallpaperName for $modifier."
        }
        Assert (-not (Test-Path -LiteralPath (Join-Path $renderRoot 'Pictures\Wallpapers\wwt-mountain-dawn.png'))) 'Non-canonical project wallpaper must not alter the maintained live collection.'
    }
    $yasbStyle = Get-Content -LiteralPath (Join-Path $repositoryRoot 'config\yasb\styles.css') -Raw
    Assert ($yasbStyle -match '\.komorebi-workspaces \.ws-btn\.button-6') 'YASB CSS must preserve the canonical five-button bar.'
    Assert ($yasbStyle -match '(?s)\.quick-launch-widget,.*?min-width:\s*0') 'Quick Launch must remain registered but visually hidden.'
    Assert ($yasbStyle -match '(?s)\.wallpapers-widget,.*?min-width:\s*0') 'Wallpaper gallery must remain registered but visually hidden.'
    Assert ($yasbStyle -match '(?s)\.power-menu-widget,.*?min-width:\s*6px') 'Power menu must retain the canonical invisible edge target.'

    Import-Module (Join-Path $repositoryRoot 'src\Win11WindowTiling.psm1') -Force
    $moduleText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\Win11WindowTiling.psm1') -Raw
    Assert ($moduleText -match 'Add-WwtWallpaperBankToStaging' -and $moduleText -match 'Get-WwtGitBlobHash') 'Pinned wallpaper download and integrity validation are missing.'
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

    Remove-WwtManagedTargets
    $operationStatePath = (Get-WwtPaths -RepositoryRoot $repositoryRoot).OperationStatePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $operationStatePath) -Force | Out-Null
    [IO.File]::WriteAllText($operationStatePath,'{"status":"running"}')
    $emptyTargetBackup = Backup-WwtStack -RepositoryRoot $repositoryRoot -OperationId 'operation-state-only'
    Assert (Test-Path -LiteralPath $emptyTargetBackup.RecordPath) 'Backup record was not created when only operation state existed.'
    Assert (Test-Path -LiteralPath (Join-Path $emptyTargetBackup.Root 'product-operation-state.json')) 'Operation state was not backed up when no managed targets existed.'

    New-Item -ItemType Directory -Path $komorebi,$yasb -Force | Out-Null
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
    Assert ($installText -match '\$Action -in @\(''Install'',''Repair''\)') 'Install and Repair must restore configuration and startup ownership after failure.'
    Assert ($installText -match 'Bootstrap commit provenance does not match') 'Installer must validate downloaded source commit provenance.'
    Assert ($installText -match 'Bootstrap archive provenance does not match') 'Installer must validate downloaded archive provenance.'
    Assert ($installText -match '\$failureException = \$_\.Exception') 'Failure reporting must preserve the original exception before rollback and logging attempts.'
    Assert ($installText -match 'Non-interactive reinstall requires -ForceReinstall') 'Destructive unattended guard is missing.'
    Assert ($installText -match "ReadKey\('NoEcho,IncludeKeyDown'\)") 'Interactive installer exits must wait for a key press.'
    Assert ($installText -match 'if \(\$PauseOnExit\) \{ Wait-WwtInstallerExit \}') 'Successful interactive installs do not remain visible.'
    Assert ($bootstrapText -match "\`$arguments \+= '-PauseOnExit'") 'Bootstrap must keep the interactive installer visible after success or failure.'
    Assert ($installText -match 'Write-Host \$failureMessage -ForegroundColor Red') 'Installer failure details must remain visible before the interactive pause.'
    Assert ($installText -notmatch '(?m)^\s*exit\s') 'Installer actions must not terminate the caller PowerShell host.'
    Assert ($installText -notmatch "'download'[^\r\n]+--architecture") 'WinGet download must allow mixed-architecture dependency graphs.'
    $bootstrapText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'bootstrap.ps1') -Raw
    Assert ($bootstrapText -notmatch 'if \(\$LASTEXITCODE -ne 0\) \{ exit') 'Bootstrap must not close the caller PowerShell session on installer failure.'
    Assert ($bootstrapText -notmatch '(?m)^\s*exit\s') 'Bootstrap decline paths must not terminate the caller PowerShell host.'
    Assert ($bootstrapText -match '\$ExpectedCommit' -and $bootstrapText -match 'Source changed while bootstrapping') 'Bootstrap must reject a source commit race.'
    Assert ($bootstrapText -match "arguments \+= '-ForceUninstall'" -and $bootstrapText -match "arguments \+= '-RemoveDependencies'") 'Bootstrap must forward complete uninstall options to install.ps1.'
    Assert ($bootstrapText -match "previousOperation\.status -in @\('failed','running'\)") 'Bootstrap does not continue failed and interrupted installs through repair.'
    Assert ($bootstrapText -match "previousOperation\.mode -in @\('Install','Reinstall','Repair','Uninstall'\)") 'Bootstrap must not treat stale Doctor state as an interrupted mutation.'
    Assert ($installText -match 'function Remove-WwtOperationCaches') 'Bounded operation-cache cleanup is missing.'
    Assert ($installText -match 'Remove-WwtOperationCaches -KeepOperationIds @\(\$operationId\)') 'Failed-operation cache retention is not bounded to the current operation.'
    Assert ($installText -match 'if \(\$Name -eq ''complete''\) \{ ''complete'' \}') 'Completed operations remain marked as running.'
    $moduleText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\Win11WindowTiling.psm1') -Raw
    Assert ($moduleText -notmatch 'Select-Object\s+-Reverse') 'Module uses Select-Object -Reverse, which is unavailable in Windows PowerShell 5.1.'
    Assert ($moduleText -notmatch '\$missing\.Name') 'Missing dependency reporting must use the inventory id property.'
    Assert ($moduleText -match "DWMBlurGlass_Extend'") 'DWMBlurGlass health must verify its logon task.'
    Assert ($moduleText -match 'StartWhenAvailable') 'Desktop startup must run after a missed or delayed logon trigger.'
    Assert ($moduleText -match 'RestartCount 3') 'Desktop startup must retry after a transient launch failure.'
    Assert ($moduleText -match "ExecutionTimeLimit \(\[TimeSpan\]::Zero\)") 'Desktop startup must not be terminated by an arbitrary task timeout.'
    Assert ($moduleText -match 'MSFT_TaskLogonTrigger') 'Doctor must verify that desktop startup is actually triggered at logon.'
    Assert ($moduleText -match "Principal\.LogonType -eq 'Interactive'") 'Doctor must verify interactive startup ownership.'
    Assert ($moduleText -match 'Set-WwtDesktopWallpaper') 'Installation must apply the canonical desktop wallpaper.'
    Assert ($moduleText -match 'default-theme\.json') 'Installation must seed the canonical adaptive-theme palette.'
    Assert ($moduleText -match 'final hashes, not the intermediate render') 'Managed hashes must be refreshed after adaptive-theme generation.'
    Assert ($moduleText -match "\.config\\ohmyposh'") 'Complete backup and purge targets must include Oh My Posh configuration.'
    Assert ($moduleText -match "'wwt-theme\.lua'") 'Complete backup and purge targets must include the generated WezTerm theme.'
    Assert ($moduleText -match "installStrategy -eq 'bundled-config'") 'Bundled-component health must validate every declared file.'
    Assert ($moduleText -match 'dwmblurglass-state\.json') 'DWMBlurGlass health must verify deployment state.'
    Assert ($moduleText -match 'configurationMatches') 'DWMBlurGlass health must detect configuration drift for Repair.'
    Assert ($moduleText -match 'PreserveGuardedDwm') 'Full reinstall must preserve healthy guarded DWM components that Windows may lock.'
    Assert ($moduleText -match 'installStrategy -eq ''guarded-dwm'' -and \$current\.capable') 'Healthy guarded DWM components must be skipped during forced dependency reinstall.'
    Assert ($moduleText -match "@\('install','--id',\`$component\.packageId[\s\S]+?'--force'") 'Missing or broken WinGet packages must be force-reinstalled when stale registration exists.'
    Assert ($moduleText -match 'komorebi-config') 'Doctor must validate the rendered Komorebi config.'
    Assert ($moduleText -match 'yasb-config') 'Doctor must validate the rendered YASB config.'
    $startupText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'config\komorebi\start-komorebi.ps1') -Raw
    Assert ($startupText -match '\$env:ProgramFiles ''AutoHotkey\\v2\\AutoHotkey64\.exe''') 'Startup must find the Program Files AutoHotkey v2 install.'
    Assert ($startupText -match '\$env:LOCALAPPDATA ''Programs\\AutoHotkey\\v2\\AutoHotkey64\.exe''') 'Startup must retain the per-user AutoHotkey v2 fallback.'
    Assert ($startupText.IndexOf('Test-Path -LiteralPath $installedYasb') -lt $startupText.IndexOf('{ $managedYasb }')) 'Startup must prefer the fingerprinted Program Files YASB over obsolete runtime copies.'
    Assert ($installText -match 'if \(\$Action -eq ''Repair''\)[\s\S]+?Stop-WwtProcesses[\s\S]+?Install-WwtConfiguration') 'Repair must stop YASB before replacing watched configuration files.'
    Assert ($installText -match "Write-Stage 'startup'") 'Install, Reinstall, and Repair must start the configured desktop stack immediately.'
    Assert ($installText.IndexOf("Installed DWMBlurGlass '") -gt $installText.IndexOf("installStrategy -eq 'guarded-dwm'")) 'DWM recovery validation is outside the guarded DWM preparation block.'
    $uninstallText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'uninstall.ps1') -Raw
    Assert ($uninstallText -match 'Non-interactive uninstall purge requires -Force') 'Uninstall purge must guard unattended destructive runs.'
    Assert ($uninstallText -match '\[switch\]\$ElevatedRelaunch') 'Uninstall purge must mark the elevated relaunch to prevent confusing loops.'
    Assert ($uninstallText -match 'UAC returned without administrator rights') 'Uninstall purge must clearly fail if elevation does not produce admin rights.'
    Assert ($uninstallText -notmatch 'Start-Transcript|Stop-Transcript|uninstall-logs') 'Uninstall must not create transcript logs.'
    $powerShellQuoteEscape = [regex]::Escape("-replace '`"','`"`"'")
    Assert ($uninstallText -match $powerShellQuoteEscape) 'Elevation arguments must use Windows PowerShell-compatible quote escaping.'
    Assert ($uninstallText -notmatch 'exit \$process\.ExitCode') 'Successful elevation must not close the caller PowerShell session.'
    Assert ($uninstallText -match 'Invoke-SelfElevation\s+return') 'The unelevated script must return after the elevated child completes.'
    Assert ($uninstallText -match 'cleanup warning\(s\)') 'Partial cleanup must not be reported as a complete purge.'
    Assert ($uninstallText -match 'komorebi,komorebic,yasb,yasbc,cava') 'Uninstall must stop every managed desktop process, including Cava.'
    Assert ($uninstallText -match 'protectedProcessIds') 'Uninstall must protect its elevated PowerShell process ancestry while closing terminal applications.'
    Assert ($uninstallText -match 'MoveFileEx') 'Locked injected files must be scheduled for deletion after reboot.'
    Assert ($uninstallText -match "New-ScheduledTaskTrigger -AtStartup") 'MoveFileEx failures must fall back to an early-boot cleanup task.'
    Assert ($uninstallText -match "New-ScheduledTaskPrincipal -UserId 'SYSTEM'") 'Early-boot cleanup must run as SYSTEM before user apps can relock files.'
    Assert ($uninstallText -match 'Win11WindowTilling Uninstall Cleanup') 'Early-boot cleanup must use a deterministic self-removing task.'
    Assert ($uninstallText -match '\[switch\]\$Reboot') 'Unattended uninstall must provide an explicit reboot switch.'
    Assert ($uninstallText -match 'Press Enter to reboot now') 'Interactive uninstall must offer to reboot when locked cleanup remains.'
    Assert ($uninstallText -match '\$NonInteractive[\s\S]+rerun with -Reboot') 'Non-interactive uninstall must not block on a reboot prompt.'
    Assert ($uninstallText -match 'foreach \(\$target in @\(Get-WwtManagedTargets\)\)') 'A locked managed target must not prevent later targets from being removed.'
    Assert ($uninstallText -match 'Remove-WwtOrphanedUninstallEntries') 'Uninstall must remove stale Programs and Features records after deleting leftovers.'
    foreach ($managedProgram in @('\^AutoHotkey\(\?: \\\(user\\\)\)\?\$','\^cava\$','\^komorebi\$','\^YASB Reborn\$','\^zoxide\$')) {
        Assert ($uninstallText -match $managedProgram) "Orphan cleanup is missing an exact managed-program pattern: $managedProgram"
    }
    Assert ($uninstallText -match 'Uninstall-WwtUserPackages[\s\S]+Invoke-SelfElevation') 'User-scoped WinGet packages must be removed before elevation.'
    Assert ($uninstallText -match "'AutoHotkey.AutoHotkey','JanDeDobbeleer.OhMyPosh','ajeetdsouza.zoxide','karlstav.cava'") 'The user-context uninstall pass must cover every potentially per-user package.'
    Assert ($uninstallText -match '\^AutoHotkey\(\?: \\\(user\\\)\)\?\$') 'Uninstall must recognize the actual AutoHotkey user registration.'
    Assert ($uninstallText -match 'Uninstall-WwtRegisteredApplications') 'Elevated dependency removal must use registered MSI and quiet uninstallers.'
    Assert ($uninstallText -notmatch 'try \{ Uninstall-WwtDependencies') 'Elevated uninstall must not use WinGet for user-scoped packages.'
    Assert ($uninstallText -match 'Start-Process msiexec\.exe -ArgumentList @\(''/x'',\$keyName') 'MSI product codes must be discovered from installed registry entries.'
    Assert ($uninstallText -match 'Remove-WwtShortcuts') 'Uninstall must remove managed desktop and Start menu shortcuts.'
    Assert ($uninstallText -match 'Get-WwtUninstallLeftovers') 'Uninstall must verify that registrations and install directories are gone.'
    foreach ($requiredCall in @('Stop-WwtProcesses','Remove-WwtStartupEntries','Uninstall-WwtConfiguration','Remove-WwtManagedTargets','Uninstall-WwtRegisteredApplications','Remove-WwtDependencyLeftovers','Remove-WwtShortcuts','Remove-KnownPath -Path \$paths\.ProductRoot')) {
        Assert ($uninstallText -match $requiredCall) "Uninstall purge is missing step: $requiredCall"
    }
    foreach ($dependencyPath in @('komorebi','YASB','WezTerm','AutoHotkey','DWMBlurGlass','oh-my-posh','zoxide','cava')) {
        Assert ($uninstallText -match [regex]::Escape($dependencyPath)) "Uninstall purge does not mention dependency leftover: $dependencyPath"
    }
    Assert ($uninstallText -match [regex]::Escape('.local\cava')) 'Uninstall must remove the actual per-user Cava payload.'
    Assert ($uninstallText -match [regex]::Escape('Microsoft\WinGet\Packages')) 'Uninstall must purge managed WinGet portable-package payloads.'
    Assert ($uninstallText -match [regex]::Escape('Microsoft\WinGet\Links')) 'Uninstall must purge managed WinGet command links.'
    foreach ($cacheName in @("LOCALAPPDATA 'YASB'","LOCALAPPDATA 'komorebi'","APPDATA 'YASB'","APPDATA 'komorebi'")) {
        Assert ($uninstallText -match [regex]::Escape($cacheName)) "Uninstall cache purge is missing: $cacheName"
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
