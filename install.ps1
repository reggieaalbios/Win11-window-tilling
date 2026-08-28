[CmdletBinding()]
param(
    [ValidateSet('Install','Reinstall','Repair','Doctor','Uninstall')]
    [string]$Action = 'Install',
    [ValidateSet('Win','Caps')]
    [string]$MainModifier = 'Win',
    [switch]$NonInteractive,
    [switch]$ForceReinstall,
    [switch]$RemoveDependencies,
    [switch]$PauseOnFailure,
    [switch]$PauseOnExit,
    [ValidateSet('','before-purge','dependency-installation','config-deployment','startup-registration')]
    [string]$InjectFailureStage = '',
    [string]$SnapshotCommit,
    [string]$SnapshotSha256
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$RepositoryRoot = $PSScriptRoot
Import-Module (Join-Path $RepositoryRoot 'src\Win11WindowTiling.psm1') -Force
$paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
$operationId = [guid]::NewGuid().ToString('N')
$script:stage = 'initialization'
$script:step = 0
$script:total = if ($Action -eq 'Reinstall') { 11 } else { 6 }

function Write-Stage([string]$Name,[string]$Detail) {
    $script:stage = $Name; $script:step++
    $percent = [Math]::Min(100,[int](100 * $script:step / $script:total))
    Write-Progress -Activity "Win11 Window Tiling - $Action" -Status $Detail -PercentComplete $percent
    Write-Host ("[{0,3}%] {1}: {2}" -f $percent,$Name,$Detail) -ForegroundColor Cyan
    Write-WwtLog -RepositoryRoot $RepositoryRoot -Event 'stage' -Data @{ operationId=$operationId; action=$Action; stage=$Name; detail=$Detail; percent=$percent }
    $status = if ($Name -eq 'complete') { 'complete' } else { 'running' }
    Set-WwtCheckpoint -RepositoryRoot $RepositoryRoot -Mode $Action -Step $Name -Status $status -OperationId $operationId | Out-Null
}
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Join-QuotedArguments([string[]]$Values) {
    ($Values | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join ' '
}
function Wait-WwtInstallerExit {
    if ($NonInteractive) { return }
    Write-Host ''
    Write-Host 'Press any key to close this installer window...'
    try {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        Read-Host 'Press Enter to close this installer window' | Out-Null
    }
}
function Invoke-SelfElevation {
    $values = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Action',$Action,'-MainModifier',$MainModifier)
    if ($NonInteractive) { $values += '-NonInteractive' }
    if ($ForceReinstall) { $values += '-ForceReinstall' }
    if ($RemoveDependencies) { $values += '-RemoveDependencies' }
    if ($PauseOnExit) { $values += '-PauseOnExit' }
    if (-not $NonInteractive) { $values += '-PauseOnFailure' }
    if ($InjectFailureStage) { $values += @('-InjectFailureStage',$InjectFailureStage) }
    if ($SnapshotCommit) { $values += @('-SnapshotCommit',$SnapshotCommit) }
    if ($SnapshotSha256) { $values += @('-SnapshotSha256',$SnapshotSha256) }
    Write-Host 'Administrator permission is required for machine-level components.' -ForegroundColor Yellow
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList (Join-QuotedArguments $values) -Wait -PassThru
    exit $process.ExitCode
}
function Confirm-Choice([string]$Prompt,[bool]$DefaultNo=$true) {
    if ($NonInteractive) { return $true }
    $answer = Read-Host $Prompt
    if ($DefaultNo) { return $answer -match '^[Yy]$' }
    return $answer -notmatch '^[Nn]$'
}
function Show-Plan {
    $inventory = @(Get-WwtComponentInventory -RepositoryRoot $RepositoryRoot)
    Write-Host ''
    Write-Host 'Win11 Window Tiling installation plan' -ForegroundColor Green
    Write-Host "  Action:          $Action"
    Write-Host "  Main modifier:   $MainModifier"
    Write-Host "  Product data:    $($paths.ProductRoot)"
    Write-Host "  User config:     $env:USERPROFILE\.config"
    Write-Host '  Elevation:       required for machine components and startup ownership'
    Write-Host '  Telemetry:       none; JSONL logs remain on this computer'
    Write-Host ''
    $inventory | Select-Object id,@{n='Status';e={if($_.capable){"detected $($_.version)"}elseif($_.detected){'incompatible'}else{'missing'}}},installStrategy | Format-Table -AutoSize | Out-Host
    $inventory
}
function Stop-WwtProcesses {
    Get-Process -Name komorebi,yasb,AutoHotkey64,DWMBlurGlass,DWMBlurGlassGUI -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
function Remove-WwtOperationCaches([string[]]$KeepOperationIds = @()) {
    if (-not (Test-Path -LiteralPath $paths.CacheRoot)) { return }
    $resolvedCacheRoot = [IO.Path]::GetFullPath($paths.CacheRoot).TrimEnd('\') + '\'
    foreach ($directory in @(Get-ChildItem -LiteralPath $paths.CacheRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($KeepOperationIds -contains $directory.Name) { continue }
        $resolvedDirectory = [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\') + '\'
        if (-not $resolvedDirectory.StartsWith($resolvedCacheRoot,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to prune cache outside '$($paths.CacheRoot)': $($directory.FullName)"
        }
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force
    }
}
function Get-WwtSystemInventory {
    $processes = @(Get-Process -Name komorebi,yasb,AutoHotkey64,DWMBlurGlass,DWMBlurGlassGUI -ErrorAction SilentlyContinue | Select-Object ProcessName,Id,Path,@{n='Version';e={$_.FileVersion}})
    $tasks = @()
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'Komorebi|YASB|Win11WindowTiling' } | ForEach-Object {
            [pscustomobject]@{ name=$_.TaskName; path=$_.TaskPath; state=[string]$_.State; actions=@($_.Actions | ForEach-Object { [pscustomobject]@{ execute=$_.Execute; arguments=$_.Arguments } }) }
        })
    }
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runValues = [ordered]@{}
    $run = Get-ItemProperty -LiteralPath $runPath -ErrorAction SilentlyContinue
    if ($run) { foreach($property in $run.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) { $runValues[$property.Name]=[string]$property.Value } }
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Komorebi|YASB|DWMBlurGlass' -or $_.DisplayName -match 'Komorebi|YASB|DWMBlurGlass' } | Select-Object Name,DisplayName,Status,StartType)
    [ordered]@{ capturedAt=(Get-Date).ToString('o'); processes=$processes; tasks=$tasks; runValues=$runValues; services=$services }
}
function Clear-WwtStaleProductData {
    foreach ($directory in @($paths.RuntimeRoot,(Join-Path $paths.ProductRoot 'staging'))) {
        if (Test-Path $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    }
    if (Test-Path $paths.SourceRoot) {
        Get-ChildItem $paths.SourceRoot -Directory | Where-Object { $_.FullName -ne $RepositoryRoot } | Remove-Item -Recurse -Force
    }
    Remove-WwtOperationCaches -KeepOperationIds @($operationId)
    foreach ($state in @($paths.StatePath,$paths.OperationStatePath)) { if(Test-Path $state){Remove-Item -LiteralPath $state -Force} }
}
function Save-PreparationArtifacts([object[]]$Inventory,[switch]$IncludeRecovery) {
    $manifest = Read-WwtManifest -RepositoryRoot $RepositoryRoot
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'WinGet is unavailable. Install or repair Microsoft App Installer before continuing.' }
    $newRoot = Join-Path $paths.CacheRoot (Join-Path $operationId 'new')
    $recoveryRoot = Join-Path $paths.CacheRoot (Join-Path $operationId 'recovery')
    New-Item -ItemType Directory -Path $newRoot -Force | Out-Null
    foreach ($component in @($manifest.components | Where-Object installStrategy -eq 'winget-stable')) {
        $destination = Join-Path $newRoot $component.id
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        # Do not constrain the complete dependency graph to x64. Some x64 packages
        # (notably CAVA) legitimately depend on x86 runtime packages.
        $args = @('download','--id',$component.packageId,'--exact','--source','winget','--download-directory',$destination,'--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
        $p = Start-Process $winget.Source -ArgumentList $args -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) { throw "Could not prepare latest stable artifact for '$($component.id)'." }
        if ($IncludeRecovery) {
            $old = @($Inventory | Where-Object id -eq $component.id)[0]
            if ($old.detected -and -not $old.version) { throw "Cannot resolve the installed version of '$($component.id)' for rollback." }
            if ($old.detected -and $old.version) {
                $destination = Join-Path $recoveryRoot $component.id
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                $args = @('download','--id',$component.packageId,'--version',$old.version,'--exact','--source','winget','--download-directory',$destination,'--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
                $p = Start-Process $winget.Source -ArgumentList $args -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -ne 0) { throw "Could not stage recovery artifact for '$($component.id)' $($old.version)." }
            }
        }
    }
    foreach ($component in @($manifest.components | Where-Object installStrategy -eq 'immutable-msi')) {
        $destination = Join-Path $newRoot $component.asset.file
        Invoke-WebRequest -UseBasicParsing -Uri $component.asset.url -OutFile $destination
        if ((Get-FileHash $destination -Algorithm SHA256).Hash -ne $component.asset.sha256) { throw "Prepared artifact hash mismatch for '$($component.id)'." }
        New-Item -ItemType Directory -Path $paths.ArtifactRoot -Force | Out-Null
        Copy-Item -LiteralPath $destination -Destination (Join-Path $paths.ArtifactRoot $component.asset.file) -Force
        $old = @($Inventory | Where-Object id -eq $component.id)[0]
        if ($IncludeRecovery -and $old.detected) {
            $componentRecovery = Join-Path $recoveryRoot $component.id
            New-Item -ItemType Directory -Path $componentRecovery -Force | Out-Null
            if ($old.recoverySource -and (Test-Path -LiteralPath $old.recoverySource)) {
                $recoveryFile = Join-Path $componentRecovery 'previous.msi'
                Copy-Item -LiteralPath $old.recoverySource -Destination $recoveryFile -Force
                if ((Get-FileHash $recoveryFile -Algorithm SHA256).Hash -ne $old.recoverySha256) { throw "Cached recovery MSI changed for '$($component.id)'." }
            } elseif ($old.capable) {
                Copy-Item -LiteralPath $destination -Destination (Join-Path $componentRecovery $component.asset.file) -Force
            } else { throw "Cannot prepare the exact previous installer for '$($component.id)'." }
        }
    }
    foreach ($component in @($manifest.components | Where-Object installStrategy -eq 'guarded-dwm')) {
        $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
        $mapping = @($component.compatibility | Where-Object { $build -ge [int]$_.minimumBuild -and $build -le [int]$_.maximumBuild })[0]
        if (-not $mapping) { throw 'No tested DWMBlurGlass recovery mapping exists for this Windows build.' }
        $destination = Join-Path $newRoot $mapping.file
        Invoke-WebRequest -UseBasicParsing -Uri $mapping.url -OutFile $destination
        if ((Get-FileHash $destination -Algorithm SHA256).Hash -ne $mapping.sha256) { throw 'Prepared DWMBlurGlass hash mismatch.' }
        New-Item -ItemType Directory -Path $paths.ArtifactRoot -Force | Out-Null
        Copy-Item -LiteralPath $destination -Destination (Join-Path $paths.ArtifactRoot $mapping.file) -Force
        $old = @($Inventory | Where-Object id -eq $component.id)[0]
        if ($IncludeRecovery -and $old.detected) {
            if (-not $old.version -or $old.version -notmatch $mapping.productVersionPattern) { throw "Installed DWMBlurGlass '$($old.version)' does not match a tested recovery artifact." }
            $componentRecovery = Join-Path $recoveryRoot $component.id
            New-Item -ItemType Directory -Path $componentRecovery -Force | Out-Null
            Copy-Item -LiteralPath $destination -Destination (Join-Path $componentRecovery $mapping.file) -Force
        }
    }
    $record = [ordered]@{ schemaVersion=1; createdAt=(Get-Date).ToString('o'); newRoot=$newRoot; recoveryRoot=$recoveryRoot; inventory=$Inventory; system=(Get-WwtSystemInventory) }
    $recordPath = Join-Path $paths.CacheRoot (Join-Path $operationId 'preparation.json')
    [IO.File]::WriteAllText($recordPath,($record | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $recordPath
}
function Restore-WwtRecoveryDependencies([string]$PreparationPath) {
    $record = Get-Content -LiteralPath $PreparationPath -Raw | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $record.recoveryRoot)) { throw 'Recovery artifact directory is missing.' }
    foreach ($item in @($record.inventory | Where-Object { $_.detected -and $_.installStrategy -ne 'bundled-config' })) {
        $root = Join-Path $record.recoveryRoot $item.id
        if (-not (Test-Path $root)) { $root = $record.recoveryRoot }
        $artifact = Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $artifact) { throw "Recovery artifact is missing for '$($item.id)'." }
        switch ($artifact.Extension.ToLowerInvariant()) {
            '.msi' {
                $p=Start-Process msiexec.exe -ArgumentList @('/i',$artifact.FullName,'/qn','/norestart') -Wait -PassThru
                if($p.ExitCode -notin @(0,1641,3010)){throw "Recovery MSI failed for '$($item.id)'."}
                if ($item.id -eq 'yasb') {
                    $yasb=@((Read-WwtManifest -RepositoryRoot $RepositoryRoot).components | Where-Object id -eq 'yasb')[0]
                    if ((Get-FileHash $artifact.FullName -Algorithm SHA256).Hash -eq $yasb.asset.sha256) {
                        $marker=[ordered]@{assetSha256=[string]$yasb.asset.sha256;version=[string]$yasb.asset.version}|ConvertTo-Json -Compress
                        [IO.File]::WriteAllText((Join-Path $env:ProgramFiles 'YASB\wwt-build.json'),$marker,(New-Object Text.UTF8Encoding($false)))
                    }
                }
            }
            '.msix' { Add-AppxPackage -Path $artifact.FullName }
            '.exe' {
                $arguments = if($item.id -eq 'wezterm'){@('/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES')}else{@('/silent')}
                $p=Start-Process $artifact.FullName -ArgumentList $arguments -Wait -PassThru
                if($p.ExitCode -notin @(0,1641,3010)){throw "Recovery executable failed for '$($item.id)'."}
            }
            '.zip' {
                if ($item.id -eq 'dwmblurglass') {
                    & (Join-Path $RepositoryRoot 'scripts\dwmblurglass-deploy.ps1') -Mode Install -ArchivePath $artifact.FullName -StatePath (Join-Path $paths.ProductRoot 'dwmblurglass-state.json') -Apply
                } elseif ($item.id -eq 'zoxide') {
                    $destination=Join-Path $env:LOCALAPPDATA ("Programs\zoxide\{0}" -f $item.version)
                    Expand-Archive $artifact.FullName $destination -Force
                } else { throw "No safe ZIP recovery handler exists for '$($item.id)'." }
            }
            default { throw "Unsupported recovery artifact '$($artifact.Name)'." }
        }
    }
}

if (-not $NonInteractive -and -not $PSBoundParameters.ContainsKey('PauseOnExit')) {
    $PauseOnExit = $true
}
$mutating = $Action -in @('Install','Reinstall','Repair','Uninstall')
if ($Action -eq 'Reinstall' -and $NonInteractive -and -not $ForceReinstall) { throw 'Non-interactive reinstall requires -ForceReinstall.' }
if ($mutating -and -not (Test-Administrator)) { Invoke-SelfElevation }

$backup = $null
$preparation = $null
$inventory = @()
try {
    Write-Stage 'preflight' 'Checking Windows, manifest, and component capabilities'
    $inventory = @(Show-Plan)
    if ($Action -eq 'Doctor') {
        $health = @(Get-WwtHealth -RepositoryRoot $RepositoryRoot)
        $health | Format-Table Name,Healthy,Required,Detail -AutoSize
        if (@($health | Where-Object { $_.Required -and -not $_.Healthy }).Count) { exit 2 }
        exit 0
    }

    if (-not $NonInteractive -and -not (Confirm-Choice 'Continue? [y/N]')) { exit 0 }
    if ($mutating) { Remove-WwtOperationCaches -KeepOperationIds @($operationId) }
    if ($Action -eq 'Uninstall') {
        Write-Stage 'backup' 'Preserving managed baselines before uninstall'
        $backup = Backup-WwtStack -RepositoryRoot $RepositoryRoot -OperationId $operationId -IncludeMachineState
        Write-Stage 'configuration' 'Restoring managed configuration and startup baselines'
        Uninstall-WwtConfiguration -RepositoryRoot $RepositoryRoot -Apply | Out-Host
        if (-not $NonInteractive -and -not $RemoveDependencies) { $RemoveDependencies = Confirm-Choice 'Also remove desktop-stack dependencies? [y/N]' }
        if ($RemoveDependencies) {
            Write-Stage 'dependencies' 'Removing explicitly requested dependencies'
            Uninstall-WwtDependencies -RepositoryRoot $RepositoryRoot
        }
        Write-Stage 'complete' 'Uninstall completed; dependencies were kept unless explicitly selected'
        Remove-WwtOperationCaches
        Write-Progress -Activity "Win11 Window Tiling - $Action" -Completed
        exit 0
    }

    if ($Action -eq 'Reinstall') {
        Write-Stage 'prepare-new' 'Downloading and validating the complete fresh dependency set'
        $preparation = Save-PreparationArtifacts -Inventory $inventory -IncludeRecovery
        Write-Stage 'inventory' 'Recording versions, processes, startup ownership, and recovery materials'
        Write-WwtLog -RepositoryRoot $RepositoryRoot -Event 'reinstall-inventory' -Data @{ operationId=$operationId; preparation=$preparation; components=$inventory }
        Write-Stage 'backup' 'Backing up complete managed targets and product state'
        $backup = Backup-WwtStack -RepositoryRoot $RepositoryRoot -OperationId $operationId -IncludeMachineState
        Write-Stage 'stop' 'Stopping managed desktop processes'
        Stop-WwtProcesses
        Write-Stage 'purge' 'Removing the declared stack and managed configuration targets'
        if ($InjectFailureStage -eq 'before-purge') { throw 'Injected failure before purge.' }
        Uninstall-WwtConfiguration -RepositoryRoot $RepositoryRoot -Apply | Out-Null
        Uninstall-WwtDependencies -RepositoryRoot $RepositoryRoot -PreserveGuardedDwm
        Remove-WwtManagedTargets
        Clear-WwtStaleProductData
        Write-Stage 'dependencies' 'Installing freshly resolved stable dependencies and immutable exceptions'
        if ($InjectFailureStage -eq 'dependency-installation') { throw 'Injected failure during dependency installation.' }
        Install-WwtMissingDependencies -RepositoryRoot $RepositoryRoot -ReinstallAll | Out-Null
    } elseif ($Action -eq 'Install') {
        Write-Stage 'dependencies' 'Installing only missing or incompatible dependencies'
        Install-WwtMissingDependencies -RepositoryRoot $RepositoryRoot | Out-Null
    } else {
        Write-Stage 'dependencies' 'Repairing missing dependencies without upgrading healthy ones'
        Install-WwtMissingDependencies -RepositoryRoot $RepositoryRoot | Out-Null
    }

    Write-Stage 'configuration' 'Rendering and deploying the selected modifier variant'
    $mode = if ($Action -eq 'Repair') { 'Repair' } elseif ($Action -eq 'Reinstall') { 'Upgrade' } else { 'Install' }
    Install-WwtConfiguration -RepositoryRoot $RepositoryRoot -MainModifier $MainModifier -OperationMode $mode -SnapshotCommit $SnapshotCommit -SnapshotSha256 $SnapshotSha256 -InjectFailureStage $InjectFailureStage -Apply | Out-Host
    Write-Stage 'doctor' 'Validating component health and runtime ownership'
    $health = @(Get-WwtHealth -RepositoryRoot $RepositoryRoot)
    $health | Format-Table Name,Healthy,Required,Detail -AutoSize
    $failed = @($health | Where-Object { $_.Required -and -not $_.Healthy })
    if ($failed) { throw "Doctor failed: $(($failed.Name) -join ', ')" }
    Write-Stage 'complete' 'Installation completed successfully'
    Remove-WwtOperationCaches
    Write-Progress -Activity "Win11 Window Tiling - $Action" -Completed
    Write-Host "Complete. State and local logs: $($paths.ProductRoot)" -ForegroundColor Green
    if ($PauseOnExit) { Wait-WwtInstallerExit }
}
catch {
    Write-WwtLog -RepositoryRoot $RepositoryRoot -Event 'operation-failed' -Level Error -Data @{ operationId=$operationId; action=$Action; stage=$script:stage; message=$_.Exception.Message }
    Set-WwtCheckpoint -RepositoryRoot $RepositoryRoot -Mode $Action -Step $script:stage -Status failed -OperationId $operationId | Out-Null
    if ($Action -eq 'Reinstall' -and $backup) {
        Write-Host "Reinstall failed during '$script:stage'. Restoring the previous configuration and state..." -ForegroundColor Red
        try {
            Stop-WwtProcesses
            Uninstall-WwtDependencies -RepositoryRoot $RepositoryRoot
            Remove-WwtManagedTargets
            if ($preparation) { Restore-WwtRecoveryDependencies -PreparationPath $preparation }
            Restore-WwtStack -BackupRecordPath $backup.RecordPath
            Write-Host 'Previous dependencies, configuration, startup ownership, and product state were restored.' -ForegroundColor Yellow
        } catch {
            Write-Host "Rollback also failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    if ($mutating) {
        try { Remove-WwtOperationCaches -KeepOperationIds @($operationId) }
        catch { Write-Warning "Could not prune old operation caches: $($_.Exception.Message)" }
    }
    Write-Error "Action '$Action' failed at stage '$script:stage': $($_.Exception.Message)" -ErrorAction Continue
    if ($PauseOnExit -or $PauseOnFailure) { Wait-WwtInstallerExit }
    exit 1
}
