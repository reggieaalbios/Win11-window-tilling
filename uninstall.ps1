[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$KeepLogs,
    [switch]$RemoveRepositoryCheckout,
    [switch]$ElevatedRelaunch,
    [string]$LogPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TranscriptStarted = $false
if ($LogPath) {
    $logDirectory = Split-Path -Parent $LogPath
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    Start-Transcript -LiteralPath $LogPath -Force | Out-Null
    $script:TranscriptStarted = $true
}

trap {
    if ($script:TranscriptStarted) { Stop-Transcript | Out-Null }
    break
}

$RepositoryRoot = $PSScriptRoot
Import-Module (Join-Path $RepositoryRoot 'src\Win11WindowTiling.psm1') -Force
$paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Join-QuotedArguments([string[]]$Values) {
    ($Values | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','""') + '"' } else { $_ } }) -join ' '
}

function New-UninstallLogPath {
    $root = Join-Path ([IO.Path]::GetTempPath()) 'Win11WindowTilling\uninstall-logs'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Join-Path $root ('uninstall-{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'),[guid]::NewGuid().ToString('N'))
}

function Invoke-SelfElevation {
    $elevatedLogPath = if ($LogPath) { $LogPath } else { New-UninstallLogPath }
    $values = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($Force) { $values += '-Force' }
    if ($NonInteractive) { $values += '-NonInteractive' }
    if ($KeepLogs) { $values += '-KeepLogs' }
    if ($RemoveRepositoryCheckout) { $values += '-RemoveRepositoryCheckout' }
    $values += @('-ElevatedRelaunch','-LogPath',$elevatedLogPath)
    Write-Host 'Launching elevated uninstall purge for machine-level apps and startup entries...' -ForegroundColor Yellow
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList (Join-QuotedArguments $values) -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Elevated uninstall purge failed with exit code $($process.ExitCode). Details: $elevatedLogPath"
    }
    Write-Host "Uninstall log: $elevatedLogPath" -ForegroundColor DarkGray
    exit $process.ExitCode
}

function Assert-UnderKnownRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Roots
    )
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($root in $Roots) {
        if (-not $root) { continue }
        $resolvedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($resolved.Equals($resolvedRoot,[StringComparison]::OrdinalIgnoreCase) -or
            $resolved.StartsWith($resolvedRoot + '\',[StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }
    throw "Refusing to remove path outside known WWT roots: $Path"
}

function Remove-KnownPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Roots
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-UnderKnownRoot -Path $Path -Roots $Roots
    if ($PSCmdlet.ShouldProcess($Path,'Remove')) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Stop-WwtProcesses {
    Get-Process -Name komorebi,yasb,yasbc,AutoHotkey64,DWMBlurGlass,DWMBlurGlassGUI,DWMBlurGlassHost,wezterm-gui -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Remove-WwtStartupEntries {
    foreach ($taskName in @('Komorebi Delayed Startup','DWMBlurGlass_Extend')) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    foreach ($name in @('KomorebiDesktopStack','YASB')) {
        Remove-ItemProperty -LiteralPath $runPath -Name $name -ErrorAction SilentlyContinue
    }
}

function Remove-WwtDependencyLeftovers {
    $knownRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        $env:LOCALAPPDATA,
        $env:USERPROFILE
    )

    $leftovers = @(
        (Join-Path $env:ProgramFiles 'komorebi'),
        (Join-Path $env:ProgramFiles 'YASB'),
        (Join-Path $env:ProgramFiles 'WezTerm'),
        (Join-Path $env:ProgramFiles 'AutoHotkey'),
        (Join-Path $env:ProgramFiles 'DWMBlurGlass'),
        (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey'),
        (Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh'),
        (Join-Path $env:LOCALAPPDATA 'Programs\zoxide'),
        (Join-Path $env:LOCALAPPDATA 'cava')
    )

    foreach ($path in $leftovers) {
        Remove-KnownPath -Path $path -Roots $knownRoots
    }
}

if ($NonInteractive -and -not $Force) {
    throw 'Non-interactive uninstall purge requires -Force.'
}

if (-not (Test-Administrator) -and $ElevatedRelaunch) {
    throw 'UAC returned without administrator rights. Open PowerShell as Administrator and rerun .\uninstall.ps1 -Force -NonInteractive.'
}

if (-not (Test-Administrator)) {
    Invoke-SelfElevation
}

if (-not $Force) {
    Write-Host ''
    Write-Host 'This will remove Win11 Window Tiling configs, startup entries, caches, bundled wallpapers, and desktop-stack dependencies.' -ForegroundColor Yellow
    Write-Host "Product data: $($paths.ProductRoot)"
    Write-Host "User config:  $env:USERPROFILE\.config"
    Write-Host ''
    $answer = Read-Host 'Type PURGE to continue'
    if ($answer -cne 'PURGE') {
        Write-Host 'Uninstall purge cancelled.'
        exit 0
    }
}

Write-Host 'Stopping desktop stack processes...' -ForegroundColor Cyan
Stop-WwtProcesses

Write-Host 'Removing startup entries...' -ForegroundColor Cyan
Remove-WwtStartupEntries

Write-Host 'Removing managed configuration and bundled wallpapers...' -ForegroundColor Cyan
try { Uninstall-WwtConfiguration -RepositoryRoot $RepositoryRoot -Apply | Out-Host } catch { Write-Warning $_.Exception.Message }
try { Remove-WwtManagedTargets } catch { Write-Warning $_.Exception.Message }

Write-Host 'Uninstalling declared dependencies...' -ForegroundColor Cyan
try { Uninstall-WwtDependencies -RepositoryRoot $RepositoryRoot } catch { Write-Warning $_.Exception.Message }

Write-Host 'Removing leftover dependency directories...' -ForegroundColor Cyan
Stop-WwtProcesses
try { Remove-WwtDependencyLeftovers } catch { Write-Warning $_.Exception.Message }

Write-Host 'Purging product caches, artifacts, backups, runtime, source snapshots, and state...' -ForegroundColor Cyan
if ($KeepLogs) {
    foreach ($child in @(Get-ChildItem -LiteralPath $paths.ProductRoot -Force -ErrorAction SilentlyContinue)) {
        if ($child.FullName -eq $paths.LogRoot) { continue }
        Remove-KnownPath -Path $child.FullName -Roots @($paths.ProductRoot)
    }
} else {
    Remove-KnownPath -Path $paths.ProductRoot -Roots @($env:LOCALAPPDATA)
}

if ($RemoveRepositoryCheckout) {
    $deleteRoot = [IO.Path]::GetFullPath($RepositoryRoot)
    $parent = Split-Path -Parent $deleteRoot
    $script = Join-Path ([IO.Path]::GetTempPath()) ('wwt-remove-repo-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $lines = @(
        '$ErrorActionPreference = ''SilentlyContinue''',
        'Start-Sleep -Seconds 2',
        ('Remove-Item -LiteralPath ''{0}'' -Recurse -Force' -f ($deleteRoot -replace '''','''''')),
        ('if ((Test-Path -LiteralPath ''{0}'') -and -not (Get-ChildItem -LiteralPath ''{0}'' -Force)) {{ Remove-Item -LiteralPath ''{0}'' -Force }}' -f ($parent -replace '''',''''''))
    )
    [IO.File]::WriteAllLines($script,$lines,(New-Object Text.UTF8Encoding($false)))
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script) -WindowStyle Hidden
    Write-Host 'Repository checkout removal was scheduled after this process exits.' -ForegroundColor Yellow
}

Write-Host 'Uninstall purge completed.' -ForegroundColor Green
if ($LogPath) { Write-Host "Uninstall log: $LogPath" -ForegroundColor DarkGray }
if ($script:TranscriptStarted) {
    Stop-Transcript | Out-Null
    $script:TranscriptStarted = $false
}
