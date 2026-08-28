[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$KeepLogs,
    [switch]$RemoveRepositoryCheckout,
    [switch]$Reboot,
    [switch]$UserPackagePassComplete,
    [switch]$ElevatedRelaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepositoryRoot = $PSScriptRoot
Import-Module (Join-Path $RepositoryRoot 'src\Win11WindowTiling.psm1') -Force
$paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
$cleanupWarnings = New-Object System.Collections.Generic.List[string]
$rebootCleanup = New-Object System.Collections.Generic.List[string]

function Add-CleanupWarning {
    param([Parameter(Mandatory)][string]$Message)
    [void]$cleanupWarnings.Add($Message)
    Write-Warning $Message
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Join-QuotedArguments([string[]]$Values) {
    ($Values | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','""') + '"' } else { $_ } }) -join ' '
}

function Invoke-SelfElevation {
    $values = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($Force) { $values += '-Force' }
    if ($NonInteractive) { $values += '-NonInteractive' }
    if ($KeepLogs) { $values += '-KeepLogs' }
    if ($RemoveRepositoryCheckout) { $values += '-RemoveRepositoryCheckout' }
    if ($Reboot) { $values += '-Reboot' }
    if ($UserPackagePassComplete) { $values += '-UserPackagePassComplete' }
    $values += '-ElevatedRelaunch'
    Write-Host 'Launching elevated uninstall purge for machine-level apps and startup entries...' -ForegroundColor Yellow
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList (Join-QuotedArguments $values) -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Elevated uninstall purge failed with exit code $($process.ExitCode)."
    }
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

function Register-DeleteOnReboot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not ('Wwt.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Wwt {
    public static class NativeMethods {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool MoveFileEx(string existingName, string newName, int flags);
    }
}
'@
    }

    $items = @()
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $items += @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            Select-Object -ExpandProperty FullName)
    }
    $items += $Path
    foreach ($item in $items) {
        [void][Wwt.NativeMethods]::MoveFileEx($item,$null,4)
    }
    if (-not $rebootCleanup.Contains($Path)) { [void]$rebootCleanup.Add($Path) }
}

function Register-RebootCleanupTask {
    param([Parameter(Mandatory)][string[]]$Paths)
    $taskName = 'Win11WindowTilling Uninstall Cleanup'
    $cleanupRoot = Join-Path $env:ProgramData 'Win11WindowTilling\uninstall-cleanup'
    $cleanupScript = Join-Path $cleanupRoot 'cleanup.ps1'
    New-Item -ItemType Directory -Path $cleanupRoot -Force | Out-Null

    $pathLiterals = @($Paths | ForEach-Object { "    '" + ($_ -replace "'","''") + "'" }) -join ",`r`n"
    $scriptText = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$paths = @(
$pathLiterals
)
foreach (`$attempt in 1..10) {
    foreach (`$path in `$paths) {
        if (Test-Path -LiteralPath `$path) { Remove-Item -LiteralPath `$path -Recurse -Force }
    }
    if (-not @(`$paths | Where-Object { Test-Path -LiteralPath `$_ }).Count) { break }
    Start-Sleep -Seconds 2
}
if (-not @(`$paths | Where-Object { Test-Path -LiteralPath `$_ }).Count) {
    Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false
    Start-Process powershell.exe -ArgumentList '-NoProfile -WindowStyle Hidden -Command "Start-Sleep -Seconds 2; Remove-Item -LiteralPath ''$cleanupRoot'' -Recurse -Force"' -WindowStyle Hidden
}
"@
    [IO.File]::WriteAllText($cleanupScript,$scriptText,(New-Object Text.UTF8Encoding($false)))

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $cleanupScript)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Finishes deleting files locked during Win11 Window Tiling uninstall.' -Force | Out-Null
}

function Remove-KnownPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Roots
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-UnderKnownRoot -Path $Path -Roots $Roots
    if ($PSCmdlet.ShouldProcess($Path,'Remove')) {
        foreach ($attempt in 1..3) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $Path)) { return }
            Start-Sleep -Milliseconds 250
        }
        Register-DeleteOnReboot -Path $Path
    }
}

function Stop-WwtProcesses {
    # Some packages use helper executables whose names vary by release. Catch
    # those by their known installation directories as well as by process name.
    $managedPathFragments = @(
        '\komorebi\','\YASB\','\AutoHotkey\','\WezTerm\','\DWMBlurGlass\',
        '\Programs\oh-my-posh\','\Programs\zoxide\','\cava\'
    )

    foreach ($attempt in 1..3) {
        Get-Process -Name komorebi,komorebic,yasb,yasbc,cava,komorebic-no-console,AutoHotkey,AutoHotkey32,AutoHotkey64,DWMBlurGlass,DWMBlurGlassGUI,DWMBlurGlassHost,wezterm,wezterm-gui,wezterm-mux-server -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue

        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $executablePath = [string]$_.ExecutablePath
                $executablePath -and @($managedPathFragments | Where-Object {
                    $executablePath.IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -ge 0
                }).Count
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

        Start-Sleep -Milliseconds 200
    }
}

function Stop-WwtServices {
    $servicePattern = 'komorebi|yasb|autohotkey|wezterm|dwmblurglass|oh.?my.?posh|zoxide|cava'
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $servicePattern -or $_.DisplayName -match $servicePattern } |
        ForEach-Object {
            Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
        }
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

function Uninstall-WwtUserPackages {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { return }
    foreach ($packageId in @('ajeetdsouza.zoxide','JanDeDobbeleer.OhMyPosh')) {
        & $winget.Source uninstall --id $packageId --exact --silent --disable-interactivity
    }
}

function Uninstall-WwtRegisteredApplications {
    $uninstallRoots = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $managedNames = @('^AutoHotkey$','^cava$','^komorebi$','^WezTerm(?: version .+)?$','^YASB Reborn$')

    foreach ($root in $uninstallRoots) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $record = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue
            if (-not $record -or -not $record.DisplayName) { continue }
            if (-not @($managedNames | Where-Object { $record.DisplayName -match $_ }).Count) { continue }

            $keyName = $entry.PSChildName
            if ($keyName -match '^\{[0-9A-Fa-f-]{36}\}$') {
                $process = Start-Process msiexec.exe -ArgumentList @('/x',$keyName,'/qn','/norestart') -Wait -PassThru
                if ($process.ExitCode -notin @(0,1605,1614,1641,3010)) {
                    Write-Warning "MSI uninstall for $($record.DisplayName) returned exit code $($process.ExitCode); cleanup will continue."
                }
                continue
            }

            $command = [string]$record.QuietUninstallString
            if (-not $command) { $command = [string]$record.UninstallString }
            if ($command -match '^"([^"]+)"\s*(.*)$') {
                $executable = $matches[1]
                $arguments = $matches[2]
            } elseif ($command -match '^(\S+)\s*(.*)$') {
                $executable = $matches[1]
                $arguments = $matches[2]
            } else {
                continue
            }
            if (-not (Test-Path -LiteralPath $executable)) { continue }
            $process = Start-Process -FilePath $executable -ArgumentList $arguments -Wait -PassThru
            if ($process.ExitCode -ne 0) {
                Write-Warning "Registered uninstaller for $($record.DisplayName) returned exit code $($process.ExitCode); cleanup will continue."
            }
        }
    }
}

function Remove-WwtOrphanedUninstallEntries {
    $uninstallRoots = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $managedNames = @(
        '^AutoHotkey$',
        '^cava$',
        '^komorebi$',
        '^WezTerm(?: version .+)?$',
        '^YASB Reborn$',
        '^Oh My Posh$',
        '^zoxide$'
    )

    foreach ($root in $uninstallRoots) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $record = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue
            if (-not $record -or -not $record.DisplayName) { continue }
            if (-not @($managedNames | Where-Object { $record.DisplayName -match $_ }).Count) { continue }
            if ($PSCmdlet.ShouldProcess($entry.PSPath,"Remove orphaned uninstall record for $($record.DisplayName)")) {
                Remove-Item -LiteralPath $entry.PSPath -Recurse -Force
            }
        }
    }
}

if ($NonInteractive -and -not $Force) {
    throw 'Non-interactive uninstall purge requires -Force.'
}

if (-not (Test-Administrator) -and $ElevatedRelaunch) {
    throw 'UAC returned without administrator rights. Open PowerShell as Administrator and rerun .\uninstall.ps1 -Force -NonInteractive.'
}

if (-not (Test-Administrator)) {
    if (-not $UserPackagePassComplete) {
        Write-Host 'Uninstalling user-scoped packages before elevation...' -ForegroundColor Cyan
        Uninstall-WwtUserPackages
        $UserPackagePassComplete = $true
    }
    Invoke-SelfElevation
    return
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

Write-Host 'Removing startup entries...' -ForegroundColor Cyan
Remove-WwtStartupEntries

Write-Host 'Stopping desktop stack processes and background services...' -ForegroundColor Cyan
Stop-WwtServices
Stop-WwtProcesses

Write-Host 'Removing managed configuration and bundled wallpapers...' -ForegroundColor Cyan
try { Uninstall-WwtConfiguration -RepositoryRoot $RepositoryRoot -Apply | Out-Host } catch { Add-CleanupWarning $_.Exception.Message }
try { Remove-WwtManagedTargets } catch { Write-Warning "Immediate managed-target removal was blocked; reboot cleanup will retry. $($_.Exception.Message)" }
foreach ($target in @(Get-WwtManagedTargets)) {
    try { Remove-KnownPath -Path $target -Roots @($env:USERPROFILE) } catch { Add-CleanupWarning $_.Exception.Message }
}

Write-Host 'Uninstalling declared dependencies...' -ForegroundColor Cyan
Stop-WwtServices
Stop-WwtProcesses
try { Uninstall-WwtRegisteredApplications } catch { Write-Warning "A registered uninstaller failed; leftover cleanup will continue. $($_.Exception.Message)" }

Write-Host 'Removing leftover dependency directories...' -ForegroundColor Cyan
Stop-WwtProcesses
try { Remove-WwtDependencyLeftovers } catch { Add-CleanupWarning $_.Exception.Message }

Write-Host 'Removing orphaned Programs and Features entries...' -ForegroundColor Cyan
try { Remove-WwtOrphanedUninstallEntries } catch { Add-CleanupWarning $_.Exception.Message }

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

if ($rebootCleanup.Count -gt 0) {
    try {
        Register-RebootCleanupTask -Paths @($rebootCleanup)
        Write-Warning "Locked paths will be removed by an early-boot cleanup task. Reboot Windows to finish removing: $($rebootCleanup -join ', ')"
    } catch {
        Add-CleanupWarning "Could not register early-boot cleanup: $($_.Exception.Message)"
    }
}
if ($cleanupWarnings.Count -gt 0) {
    Write-Warning "Uninstall finished with $($cleanupWarnings.Count) cleanup warning(s). Locked files may require a reboot and another uninstall run."
} else {
    Write-Host 'Uninstall purge completed.' -ForegroundColor Green
}
if ($rebootCleanup.Count -gt 0) {
    if ($Reboot) {
        Write-Host 'Restarting Windows to finish uninstall cleanup...' -ForegroundColor Yellow
        Restart-Computer -Force
    } elseif ($NonInteractive) {
        Write-Warning 'A reboot is required to finish uninstall cleanup. Reboot manually, or rerun with -Reboot to restart automatically.'
    } else {
        Write-Host ''
        $answer = Read-Host 'A reboot is required to finish uninstall cleanup. Press Enter to reboot now, or type N to reboot later'
        if ([string]::IsNullOrWhiteSpace($answer)) {
            Restart-Computer -Force
        } else {
            Write-Warning 'Reboot Windows later to finish uninstall cleanup.'
        }
    }
}
