[CmdletBinding()]
param(
    [ValidateSet('Install','Reinstall','Repair','Doctor','Uninstall')]
    [string]$Action = 'Install',
    [ValidateSet('Win','Caps')]
    [string]$MainModifier = 'Win',
    [switch]$NonInteractive,
    [switch]$ForceReinstall,
    [switch]$ForceUninstall,
    [switch]$RemoveDependencies,
    [switch]$PauseOnFailure,
    [switch]$PauseOnExit,
    [string]$SnapshotCommit,
    [string]$SnapshotSha256
)

# ---------------------------------------------------------------------------
# FIX #1: -InjectFailureStage removed from the public parameter block.
# It is a test-only hook for exercising the Reinstall rollback path and must
# never be reachable via a normal CLI invocation, since it lets any caller
# force the installer to fail mid-purge / mid-dependency-install on a real
# machine. It is now read ONLY from an environment variable that is not
# forwarded across elevation unless it was already present in the parent
# process's environment, so a child elevated process can't have it injected
# by the (potentially different-privilege) command line built here.
# Set it for local testing via:
#   $env:WWT_TEST_INJECT_FAILURE_STAGE = 'before-purge'
# ---------------------------------------------------------------------------
$AllowedInjectStages = @('before-purge','dependency-installation','config-deployment','startup-registration')
$InjectFailureStage = ''
if ($env:WWT_TEST_INJECT_FAILURE_STAGE) {
    if ($AllowedInjectStages -notcontains $env:WWT_TEST_INJECT_FAILURE_STAGE) {
        throw "WWT_TEST_INJECT_FAILURE_STAGE has an unrecognized value: $env:WWT_TEST_INJECT_FAILURE_STAGE"
    }
    $InjectFailureStage = $env:WWT_TEST_INJECT_FAILURE_STAGE
    Write-Warning "Failure injection is ACTIVE for stage '$InjectFailureStage'. This must only be used in test environments."
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$RepositoryRoot = $PSScriptRoot
Import-Module (Join-Path $RepositoryRoot 'src\Win11WindowTiling.psm1') -Force
$paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
$operationId = [guid]::NewGuid().ToString('N')
$script:stage = 'initialization'
$script:step = 0

# ---------------------------------------------------------------------------
# FIX #4: stage totals now match the actual stage sequence each Action takes,
# instead of a single hardcoded 6 / 11 split that was wrong for Doctor and
# Uninstall. Progress reporting is best-effort cosmetic, but it should not
# lie to the user about how close the operation is to finishing.
# ---------------------------------------------------------------------------
$script:total = switch ($Action) {
    'Reinstall' { 11 }
    'Doctor'    { 1 }
    'Uninstall' { if ($RemoveDependencies) { 5 } else { 4 } }
    default     { 6 } # Install / Repair
}

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
    if ($ForceUninstall) { $values += '-ForceUninstall' }
    if ($RemoveDependencies) { $values += '-RemoveDependencies' }
    if ($PauseOnExit) { $values += '-PauseOnExit' }
    # FIX #6: only forward -PauseOnFailure when the user actually asked for it
    # (or defaulted to it interactively) rather than unconditionally forcing
    # it on every interactive elevation regardless of what was passed in.
    # We still default to "pause on failure" for interactive sessions so the
    # elevated window doesn't just vanish on error, but we now do that via an
    # explicit default computed before elevation, not a silent override here.
    if ($PauseOnFailure) { $values += '-PauseOnFailure' }
    if ($SnapshotCommit) { $values += @('-SnapshotCommit',$SnapshotCommit) }
    if ($SnapshotSha256) { $values += @('-SnapshotSha256',$SnapshotSha256) }
    # Deliberately NOT forwarding -InjectFailureStage: the elevated child reads
    # WWT_TEST_INJECT_FAILURE_STAGE from its own environment. Start-Process
    # inherits the parent's environment by default, so a value already set in
    # the parent's environment still propagates for legitimate test setups;
    # it just can't be injected via a crafted command line.
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

# ---------------------------------------------------------------------------
# FIX #5: Show-Plan no longer relies on "whatever isn't captured on the
# pipeline becomes the return value." The human-readable table and the
# returned inventory object are now built and emitted explicitly and
# separately, so a future edit that adds any stray pipeline output inside
# this function can't silently corrupt what the caller receives.
# ---------------------------------------------------------------------------
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

    $tableText = $inventory |
        Select-Object id,@{n='Status';e={if($_.capable){"detected $($_.version)"}elseif($_.detected){'incompatible'}else{'missing'}}},installStrategy |
        Format-Table -AutoSize |
        Out-String
    Write-Host $tableText

    return ,$inventory
}

function Stop-WwtProcesses {
    Get-Process -Name komorebi,yasb,AutoHotkey64,DWMBlurGlass,DWMBlurGlassGUI -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Remove-WwtOperationCaches([string[]]$KeepOperationIds = @()) {
    if (-not (Test-Path -LiteralPath $paths.CacheRoot)) { return }
    $resolvedCacheRoot = [IO.Path]::GetFullPath($paths.CacheRoot).TrimEnd('\') + '\'
    foreach ($directory in @(Get-ChildItem -LiteralPath $paths.CacheRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($KeepOperationIds -contains $directory.Name) { continue }

        # -----------------------------------------------------------------
        # FIX #3: string-prefix matching on GetFullPath does not detect
        # reparse points (junctions/symlinks). A directory entry under
        # CacheRoot could itself be a reparse point pointing anywhere on
        # disk; -Recurse -Force would then delete through the link outside
        # the sandbox even though the string check "passed". We now:
        #   1. Reject the entry outright if it is itself a reparse point.
        #   2. Reject the entry if any child anywhere below it is a reparse
        #      point, so a nested junction can't be used to escape either.
        #   3. Only then apply the resolved-path prefix check as a second,
        #      belt-and-suspenders guard.
        # -----------------------------------------------------------------
        $isReparsePoint = ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if ($isReparsePoint) {
            throw "Refusing to prune cache entry that is itself a reparse point: $($directory.FullName)"
        }
        $nestedReparsePoints = @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
        if ($nestedReparsePoints.Count -gt 0) {
            throw "Refusing to prune cache entry containing reparse points: $($directory.FullName)"
        }

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

        # -------------------------------------------------------------
        # FIX #2: previously winget-downloaded artifacts had no integrity
        # check at all, unlike the immutable-msi and guarded-dwm paths
        # which both verify SHA256 against the manifest. WinGet itself
        # validates its own package signing/source trust, but that's a
        # different guarantee than "matches the exact bytes we pinned."
        # If the manifest pins an expected hash for this component,
        # verify every downloaded file against it; otherwise at minimum
        # record what we got so drift is visible in the prep record
        # instead of being silently trusted.
        #
        # NOTE: this requires the manifest schema to optionally carry
        # $component.asset.sha256 for winget-stable components (it
        # currently only does for immutable-msi / guarded-dwm). That
        # addition belongs in Read-WwtManifest / the manifest file itself.
        # -------------------------------------------------------------
        $downloadedFiles = @(Get-ChildItem -LiteralPath $destination -File -Recurse -ErrorAction SilentlyContinue)
        if ($component.PSObject.Properties.Name -contains 'asset' -and $component.asset -and $component.asset.PSObject.Properties.Name -contains 'sha256' -and $component.asset.sha256) {
            $expected = $component.asset.sha256
            $matched = @($downloadedFiles | Where-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash -eq $expected })
            if ($matched.Count -eq 0) { throw "Downloaded WinGet artifact for '$($component.id)' does not match the pinned SHA256 in the manifest." }
        } else {
            Write-Warning "No pinned SHA256 for winget component '$($component.id)'; integrity relies solely on WinGet's own source trust."
        }

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

# ---------------------------------------------------------------------------
# FIX #6 (continued): compute the effective PauseOnFailure default here,
# before elevation, so the value forwarded to the elevated child reflects
# what the user actually asked for (or the same "pause on interactive
# failure" default this script always had), instead of the elevation
# function unconditionally re-deciding it.
# ---------------------------------------------------------------------------
if (-not $NonInteractive -and -not $PSBoundParameters.ContainsKey('PauseOnFailure')) {
    $PauseOnFailure = $true
}
if (-not $NonInteractive) {
    $PauseOnExit = $PauseOnExit -or $PauseOnFailure
}

# ---------------------------------------------------------------------------
# FIX #7: Uninstall now requires the same explicit opt-in for unattended runs
# that Reinstall already required, instead of proceeding on a destructive
# action with no confirmation at all when -NonInteractive is set.
# ---------------------------------------------------------------------------
if ($Action -eq 'Reinstall' -and $NonInteractive -and -not $ForceReinstall) { throw 'Non-interactive reinstall requires -ForceReinstall.' }
if ($Action -eq 'Uninstall' -and $NonInteractive -and -not $ForceUninstall) { throw 'Non-interactive uninstall requires -ForceUninstall.' }

$mutating = $Action -in @('Install','Reinstall','Repair','Uninstall')
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
