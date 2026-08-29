Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-WwtPaths {
    param([string]$RepositoryRoot)
    $productRoot = Join-Path $env:LOCALAPPDATA 'Win11WindowTilling'
    [pscustomobject]@{
        RepositoryRoot = $RepositoryRoot
        ProductRoot = $productRoot
        StatePath = Join-Path $productRoot 'install-state.json'
        LogRoot = Join-Path $productRoot 'logs'
        BackupRoot = Join-Path $productRoot 'backups'
        RuntimeRoot = Join-Path $productRoot 'runtime'
        ArtifactRoot = Join-Path $productRoot 'artifacts'
        SourceRoot = Join-Path $productRoot 'source'
        CacheRoot = Join-Path $productRoot 'cache'
        OperationStatePath = Join-Path $productRoot 'operation-state.json'
    }
}

function Write-WwtLog {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Event,
        [ValidateSet('Info','Warning','Error')][string]$Level = 'Info',
        [hashtable]$Data = @{}
    )
    $paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
    New-Item -ItemType Directory -Path $paths.LogRoot -Force | Out-Null
    $entry = [ordered]@{ timestamp=(Get-Date).ToString('o'); level=$Level; event=$Event; data=$Data }
    $line = $entry | ConvertTo-Json -Depth 8 -Compress
    Add-Content -LiteralPath (Join-Path $paths.LogRoot ('installer-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))) -Value $line -Encoding UTF8
}

function Set-WwtCheckpoint {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Step,
        [ValidateSet('running','complete','failed')][string]$Status = 'running',
        [string]$OperationId
    )
    $paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
    if (-not $OperationId) { $OperationId = [guid]::NewGuid().ToString('N') }
    $checkpoint = [ordered]@{
        schemaVersion=1; operationId=$OperationId; mode=$Mode; step=$Step
        status=$Status; updatedAt=(Get-Date).ToString('o')
    }
    Write-WwtJson -Value $checkpoint -Path $paths.OperationStatePath
    Write-WwtLog -RepositoryRoot $RepositoryRoot -Event 'checkpoint' -Data @{ operationId=$OperationId; mode=$Mode; step=$Step; status=$Status }
    return [pscustomobject]$checkpoint
}

function Install-WwtStartupOwnership {
    param([Parameter(Mandatory)][string]$RepositoryRoot, $ExistingRecord)
    $taskName = 'Komorebi Delayed Startup'
    $scriptPath = Join-Path $env:USERPROFILE '.config\komorebi\start-komorebi.ps1'
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runName = 'KomorebiDesktopStack'
    $runItem = Get-ItemProperty -LiteralPath $runPath -Name $runName -ErrorAction SilentlyContinue
    $runValue = if ($runItem) { $runItem.$runName } else { $null }

    # Repair refreshes the managed task, but uninstall must retain the baseline
    # captured before the first install rather than treating our task as input.
    if ($null -ne $ExistingRecord) {
        $previousXml = if ($ExistingRecord.PSObject.Properties.Name -contains 'previousXml') { $ExistingRecord.previousXml } else { $null }
        $previousRunValue = if ($ExistingRecord.PSObject.Properties.Name -contains 'previousRunValue') { $ExistingRecord.previousRunValue } else { $null }
    } else {
        $previousXml = if ($existingTask) { Export-ScheduledTask -TaskName $taskName } else { $null }
        $previousRunValue = $runValue
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Starts the Win11 Window Tiling desktop stack once per sign-in.' -Force | Out-Null
    if ($null -ne $runValue) { Remove-ItemProperty -LiteralPath $runPath -Name $runName -Force }

    [pscustomobject][ordered]@{
        name=$taskName; managedScript=$scriptPath; previousXml=$previousXml
        runKeyPath=$runPath; runValueName=$runName; previousRunValue=$previousRunValue
    }
}

function Uninstall-WwtStartupOwnership {
    param([Parameter(Mandatory)]$Record)
    $task = Get-ScheduledTask -TaskName $Record.name -ErrorAction SilentlyContinue
    if ($task) {
        $managed = @($task.Actions | Where-Object { $_.Arguments -like "*$($Record.managedScript)*" }).Count -gt 0
        if ($managed) { Unregister-ScheduledTask -TaskName $Record.name -Confirm:$false }
    }
    if ($Record.previousXml) {
        Register-ScheduledTask -TaskName $Record.name -Xml $Record.previousXml -Force | Out-Null
    }
    if ($null -ne $Record.previousRunValue) {
        New-Item -Path $Record.runKeyPath -Force | Out-Null
        Set-ItemProperty -LiteralPath $Record.runKeyPath -Name $Record.runValueName -Value $Record.previousRunValue
    }
}

function Set-WwtDesktopWallpaper {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (-not ('Wwt.NativeMethods' -as [type])) {
        Add-Type -Namespace Wwt -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern bool SystemParametersInfo(int action, int parameter, string value, int flags);
'@
    }
    if (-not [Wwt.NativeMethods]::SystemParametersInfo(20, 0, $resolved, 3)) {
        throw "Windows rejected the default wallpaper: $resolved"
    }
}

function Send-WwtExplorerSettingsRefresh {
    if (-not ('Wwt.ExplorerNativeMethods' -as [type])) {
        Add-Type -Namespace Wwt -Name ExplorerNativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr window, uint message, System.IntPtr wParam, string lParam, uint flags, uint timeout, out System.IntPtr result);
'@
    }
    $result = [IntPtr]::Zero
    [void][Wwt.ExplorerNativeMethods]::SendMessageTimeout([IntPtr]0xffff,0x001A,[IntPtr]::Zero,'ShellState',2,1000,[ref]$result)
}

function Switch-WwtDesktopIcons {
    if (-not ('Wwt.DesktopNativeMethods' -as [type])) {
        Add-Type -Namespace Wwt -Name DesktopNativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr FindWindow(string className, string windowName);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr FindWindowEx(System.IntPtr parent, System.IntPtr after, string className, string windowName);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowProc callback, System.IntPtr parameter);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern System.IntPtr SendMessage(System.IntPtr window, uint message, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr window, int command);
public delegate bool EnumWindowProc(System.IntPtr window, System.IntPtr parameter);
public static System.IntPtr FindDesktopHost() {
    System.IntPtr programManager = FindWindow("Progman", null);
    if (programManager != System.IntPtr.Zero && FindWindowEx(programManager, System.IntPtr.Zero, "SHELLDLL_DefView", null) != System.IntPtr.Zero) return programManager;
    System.IntPtr host = System.IntPtr.Zero;
    EnumWindows(delegate(System.IntPtr window, System.IntPtr parameter) {
        if (FindWindowEx(window, System.IntPtr.Zero, "SHELLDLL_DefView", null) != System.IntPtr.Zero) { host = window; return false; }
        return true;
    }, System.IntPtr.Zero);
    return host;
}
public static System.IntPtr FindDesktopListView() {
    System.IntPtr host = FindDesktopHost();
    if (host == System.IntPtr.Zero) return System.IntPtr.Zero;
    System.IntPtr view = FindWindowEx(host, System.IntPtr.Zero, "SHELLDLL_DefView", null);
    if (view == System.IntPtr.Zero) return System.IntPtr.Zero;
    return FindWindowEx(view, System.IntPtr.Zero, "SysListView32", "FolderView");
}
'@
    }
    $desktopHost = [Wwt.DesktopNativeMethods]::FindDesktopHost()
    if ($desktopHost -eq [IntPtr]::Zero) { throw 'Explorer desktop window was not found.' }
    [void][Wwt.DesktopNativeMethods]::SendMessage($desktopHost,0x0111,[IntPtr]0x7402,[IntPtr]::Zero)
}

function Set-WwtDesktopIconsVisible {
    param([bool]$Visible)
    if (-not ('Wwt.DesktopNativeMethods' -as [type])) { Switch-WwtDesktopIcons; Switch-WwtDesktopIcons }
    $listView = [Wwt.DesktopNativeMethods]::FindDesktopListView()
    if ($listView -eq [IntPtr]::Zero) { throw 'Explorer desktop icon list was not found.' }
    $showCommand = if ($Visible) { 5 } else { 0 }
    [void][Wwt.DesktopNativeMethods]::ShowWindow($listView,$showCommand)
}

function Install-WwtDesktopIconPreference {
    param($ExistingRecord)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $currentItem = Get-ItemProperty -LiteralPath $key -Name HideIcons -ErrorAction SilentlyContinue
    if ($null -ne $ExistingRecord) {
        $previouslyPresent = [bool]$ExistingRecord.previouslyPresent
        $previousValue = $ExistingRecord.previousValue
    } else {
        $item = Get-ItemProperty -LiteralPath $key -Name HideIcons -ErrorAction SilentlyContinue
        $previouslyPresent = $null -ne $item
        $previousValue = if ($item) { [int]$item.HideIcons } else { $null }
    }
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    Set-WwtDesktopIconsVisible -Visible $false
    Set-ItemProperty -LiteralPath $key -Name HideIcons -Type DWord -Value 1
    Send-WwtExplorerSettingsRefresh
    [pscustomobject][ordered]@{ key=$key; name='HideIcons'; previouslyPresent=$previouslyPresent; previousValue=$previousValue }
}

function Uninstall-WwtDesktopIconPreference {
    param([Parameter(Mandatory)]$Record)
    if ($Record.previouslyPresent) {
        Set-ItemProperty -LiteralPath $Record.key -Name $Record.name -Type DWord -Value ([int]$Record.previousValue)
    } else {
        Remove-ItemProperty -LiteralPath $Record.key -Name $Record.name -ErrorAction SilentlyContinue
    }
    Set-WwtDesktopIconsVisible -Visible (-not [bool]$Record.previouslyPresent -or [int]$Record.previousValue -ne 1)
    Send-WwtExplorerSettingsRefresh
}

function Read-WwtManifest {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $path = Join-Path $RepositoryRoot 'manifests\components.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Component manifest not found: $path" }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Test-WwtPlatform {
    param([Parameter(Mandatory)]$Manifest)
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $build = [int]$os.BuildNumber
    }
    catch {
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $build = [int]$currentVersion.CurrentBuildNumber
    }
    $is64 = [Environment]::Is64BitOperatingSystem
    [pscustomobject]@{
        Name = 'platform'
        Healthy = ($build -ge [int]$Manifest.platform.minimumBuild -and $is64)
        Required = $true
        Detail = "Windows build $build; 64-bit=$is64"
    }
}

function Find-WwtCommand {
    param([string[]]$Names, [string[]]$DetectionPaths)
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    foreach ($path in $DetectionPaths) {
        $expanded = [Environment]::ExpandEnvironmentVariables($path)
        if (Test-Path -LiteralPath $expanded) { return $expanded }
    }
    return $null
}

function Get-WwtHealth {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $manifest = Read-WwtManifest -RepositoryRoot $RepositoryRoot
    $results = New-Object System.Collections.Generic.List[object]
    $results.Add((Test-WwtPlatform -Manifest $manifest))
    foreach ($item in @(Get-WwtComponentInventory -RepositoryRoot $RepositoryRoot)) {
        $detail = if ($item.capable) { if($item.version){"$($item.path) ($($item.version))"}else{$item.path} } elseif ($item.detected) { "detected but capability or fingerprint check failed: $($item.path)" } else { 'not detected' }
        $results.Add([pscustomobject]@{ Name=$item.id; Healthy=[bool]$item.capable; Required=[bool]$item.required; Detail=$detail })
    }
    $task = Get-ScheduledTask -TaskName 'Komorebi Delayed Startup' -ErrorAction SilentlyContinue
    $startupScript = Join-Path $env:USERPROFILE '.config\komorebi\start-komorebi.ps1'
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $startupHealthy = [bool]$task -and (Test-Path -LiteralPath $startupScript)
    if ($task) {
        $managedAction = @($task.Actions | Where-Object { $_.Arguments -like "*$startupScript*" }).Count -gt 0
        $logonTrigger = @($task.Triggers | Where-Object {
            $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and
            ($_.UserId -eq $currentIdentity -or $_.UserId -eq $env:USERNAME)
        }).Count -gt 0
        $startupHealthy = $startupHealthy -and $managedAction -and $logonTrigger -and
            $task.Settings.Enabled -and $task.Settings.StartWhenAvailable -and
            $task.Settings.RestartCount -ge 3 -and
            $task.Settings.ExecutionTimeLimit -eq 'PT0S' -and
            $task.Principal.LogonType -eq 'Interactive' -and
            $task.Principal.RunLevel -eq 'Limited'
    }
    $results.Add([pscustomobject]@{ Name='startup-task'; Healthy=$startupHealthy; Required=$true; Detail=if($task){"$($task.State); $startupScript"}else{'not detected'} })
    $komorebiConfig = Join-Path $env:USERPROFILE '.config\komorebi\komorebi.json'
    $applicationsConfig = Join-Path $env:USERPROFILE '.config\komorebi\applications.json'
    $komorebiHealthy = (Test-Path -LiteralPath $komorebiConfig) -and (Test-Path -LiteralPath $applicationsConfig)
    if ($komorebiHealthy) {
        $komorebiText = Get-Content -LiteralPath $komorebiConfig -Raw
        $komorebiHealthy = ($komorebiText -notmatch '{{[A-Z0-9_]+}}') -and ($komorebiText -notmatch '\$Env:KOMOREBI_CONFIG_HOME')
        if ($komorebiHealthy) {
            try {
                $komorebiObject = $komorebiText | ConvertFrom-Json
                $workspaces = @($komorebiObject.monitors[0].workspaces)
                $komorebiHealthy = $workspaces.Count -gt 0 -and @($workspaces | Where-Object layout -ne 'Grid').Count -eq 0
            } catch { $komorebiHealthy = $false }
        }
    }
    $results.Add([pscustomobject]@{ Name='komorebi-config'; Healthy=$komorebiHealthy; Required=$true; Detail=$komorebiConfig })
    $yasbConfig = Join-Path $env:USERPROFILE '.config\yasb\config.yaml'
    $yasbHealthy = Test-Path -LiteralPath $yasbConfig
    if ($yasbHealthy) {
        $yasbText = Get-Content -LiteralPath $yasbConfig -Raw
        $yasbHealthy = ($yasbText -notmatch '{{[A-Z0-9_]+}}') -and ($yasbText -notmatch 'data_path:\s*"[A-Za-z]:\\')
    }
    $results.Add([pscustomobject]@{ Name='yasb-config'; Healthy=$yasbHealthy; Required=$true; Detail=$yasbConfig })
    $managedUserFiles = [ordered]@{
        'autohotkey-config' = Join-Path $env:USERPROFILE '.config\komorebi\komorebi.ahk'
        'theme-engine-config' = Join-Path $env:USERPROFILE '.config\theme-engine\AdaptiveTheme.psm1'
        'wezterm-config' = Join-Path $env:USERPROFILE '.wezterm.lua'
        'wezterm-theme' = Join-Path $env:USERPROFILE 'wwt-theme.lua'
        'ohmyposh-config' = Join-Path $env:USERPROFILE '.config\ohmyposh\catppuccin_mocha.omp.json'
    }
    foreach ($managedFile in $managedUserFiles.GetEnumerator()) {
        $healthy = Test-Path -LiteralPath $managedFile.Value
        if ($healthy) {
            $text = Get-Content -LiteralPath $managedFile.Value -Raw
            $healthy = $text -notmatch '{{[A-Z0-9_]+}}'
            if ($healthy -and $managedFile.Key -eq 'ohmyposh-config') {
                try {
                    $prompt = $text | ConvertFrom-Json
                    $healthy = @('blue','lavender','pink','green','yellow','red','background','surface','border' | Where-Object {
                        -not ($prompt.palette.PSObject.Properties.Name -contains $_)
                    }).Count -eq 0
                } catch { $healthy = $false }
            }
        }
        $results.Add([pscustomobject]@{ Name=$managedFile.Key; Healthy=$healthy; Required=$true; Detail=$managedFile.Value })
    }
    $equalizerSource = Join-Path $RepositoryRoot 'config\equalizerapo\config.txt'
    $equalizerConfig = Join-Path $env:ProgramFiles 'EqualizerAPO\config\config.txt'
    $equalizerConfigHealthy = (Test-Path -LiteralPath $equalizerSource) -and (Test-Path -LiteralPath $equalizerConfig) -and
        ((Get-FileHash -LiteralPath $equalizerSource -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $equalizerConfig -Algorithm SHA256).Hash)
    $results.Add([pscustomobject]@{ Name='equalizerapo-config'; Healthy=$equalizerConfigHealthy; Required=$true; Detail=$equalizerConfig })
    return $results
}

function Write-WwtJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $json = $Value | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Get-WwtCompactBackupPath {
    param([Parameter(Mandatory)][string]$BackupRoot,[Parameter(Mandatory)][string]$Destination,[string]$Category='originals')
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Destination)))).Replace('-','').Substring(0,16) }
    finally { $algorithm.Dispose() }
    $leaf = (Split-Path -Leaf $Destination) -replace '[^A-Za-z0-9._-]','_'
    Join-Path (Join-Path $BackupRoot $Category) ("$hash-$leaf")
}

function Copy-WwtManagedFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
        $ExistingRecord
    )
    $destinationExists = Test-Path -LiteralPath $Destination
    if ($null -ne $ExistingRecord) {
        $overwrittenBackups = @()
        if ($ExistingRecord.PSObject.Properties.Name -contains 'overwrittenBackups') {
            $overwrittenBackups = @($ExistingRecord.overwrittenBackups)
        }
        $record = [ordered]@{
            destination=$Destination
            installedHash=$null
            backup=$ExistingRecord.backup
            existed=[bool]$ExistingRecord.existed
            overwrittenBackups=$overwrittenBackups
        }
        if ($destinationExists -and $ExistingRecord.installedHash) {
            $currentHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
            if ($currentHash -ne $ExistingRecord.installedHash) {
                $overwriteBackup = Get-WwtCompactBackupPath -BackupRoot $BackupRoot -Destination $Destination -Category 'repair-overwrites'
                New-Item -ItemType Directory -Path (Split-Path -Parent $overwriteBackup) -Force | Out-Null
                Copy-Item -LiteralPath $Destination -Destination $overwriteBackup -Force
                $record.overwrittenBackups = @($overwrittenBackups) + @($overwriteBackup)
            }
        }
    } else {
        $record = [ordered]@{ destination=$Destination; installedHash=$null; backup=$null; existed=$destinationExists; overwrittenBackups=@() }
    }
    if ($null -eq $ExistingRecord -and $record.existed) {
        $backup = Get-WwtCompactBackupPath -BackupRoot $BackupRoot -Destination $Destination
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        Copy-Item -LiteralPath $Destination -Destination $backup -Force
        $record.backup = $backup
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $record.installedHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    $Records.Add([pscustomobject]$record)
}

function Get-WwtGitBlobHash {
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path
    $sha1 = [Security.Cryptography.SHA1]::Create()
    $stream = [IO.File]::OpenRead($file.FullName)
    try {
        $header = [Text.Encoding]::UTF8.GetBytes("blob $($file.Length)`0")
        [void]$sha1.TransformBlock($header,0,$header.Length,$null,0)
        $buffer = New-Object byte[] (1024 * 1024)
        while (($read = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            [void]$sha1.TransformBlock($buffer,0,$read,$null,0)
        }
        [void]$sha1.TransformFinalBlock((New-Object byte[] 0),0,0)
        ([BitConverter]::ToString($sha1.Hash)).Replace('-','').ToLowerInvariant()
    }
    finally { $stream.Dispose(); $sha1.Dispose() }
}

function Add-WwtWallpaperBankToStaging {
    param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$StagingRoot)
    $manifest = Read-WwtManifest -RepositoryRoot $RepositoryRoot
    $component = @($manifest.components | Where-Object id -eq 'wallpapers')[0]
    if (-not $component -or -not $component.asset) { throw 'Pinned wallpaper asset metadata is missing.' }
    $asset = $component.asset
    $paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
    $cache = Join-Path $paths.ArtifactRoot ("wallpaper-bank\{0}" -f [string]$asset.commit)
    New-Item -ItemType Directory -Path $cache -Force | Out-Null

    try {
        $tree = Invoke-RestMethod -UseBasicParsing -Headers @{'User-Agent'='Win11-window-tilling'} -Uri ([string]$asset.treeApiUrl)
    } catch { throw "Could not retrieve the pinned JaKooLit wallpaper inventory: $($_.Exception.Message)" }
    if ($tree.truncated) { throw 'GitHub returned a truncated wallpaper inventory.' }
    $prefix = ([string]$asset.directory).Trim('/') + '/'
    $files = @($tree.tree | Where-Object {
        $_.type -eq 'blob' -and $_.path.StartsWith($prefix) -and $_.path.Substring($prefix.Length) -notmatch '/'
    })
    $totalBytes = ($files | Measure-Object -Property size -Sum).Sum
    if (@($files).Count -ne [int]$asset.fileCount -or [long]$totalBytes -ne [long]$asset.totalBytes) {
        throw "Pinned wallpaper inventory mismatch: expected $($asset.fileCount) files/$($asset.totalBytes) bytes, received $(@($files).Count) files/$totalBytes bytes."
    }

    $destination = Join-Path $StagingRoot 'Pictures\Wallpapers'
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $index = 0
    foreach ($entry in $files) {
        $index++
        $name = $entry.path.Substring($prefix.Length)
        Write-Progress -Activity 'Preparing JaKooLit wallpapers' -Status "$index/$(@($files).Count): $name" -PercentComplete (($index / @($files).Count) * 100)
        $cached = Join-Path $cache $name
        $valid = (Test-Path -LiteralPath $cached) -and ((Get-WwtGitBlobHash -Path $cached) -eq [string]$entry.sha)
        if (-not $valid) {
            $encodedName = [Uri]::EscapeDataString($name).Replace('%2F','/')
            $temporary = "$cached.download"
            try {
                Invoke-WebRequest -UseBasicParsing -Headers @{'User-Agent'='Win11-window-tilling'} `
                    -Uri (([string]$asset.rawBaseUrl).TrimEnd('/') + '/' + $encodedName) -OutFile $temporary
                if ((Get-WwtGitBlobHash -Path $temporary) -ne [string]$entry.sha) { throw "Git blob hash mismatch for '$name'." }
                Move-Item -LiteralPath $temporary -Destination $cached -Force
            } catch {
                if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
                throw "Wallpaper download $index/$(@($files).Count) failed for '$name': $($_.Exception.Message)"
            }
        }
        Copy-Item -LiteralPath $cached -Destination (Join-Path $destination $name) -Force
    }
    Write-Progress -Activity 'Preparing JaKooLit wallpapers' -Completed
}

function Install-WwtConfiguration {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [ValidateSet('Win','Caps')][string]$MainModifier = 'Caps',
        [ValidateSet('Install','Upgrade','Repair')][string]$OperationMode = 'Install',
        [string]$SnapshotCommit,
        [string]$SnapshotSha256,
        [ValidateSet('','before-purge','dependency-installation','config-deployment','startup-registration')][string]$InjectFailureStage = '',
        [switch]$Apply
    )
    $paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
    $manifest = Read-WwtManifest -RepositoryRoot $RepositoryRoot
    $platform = Test-WwtPlatform -Manifest $manifest
    if (-not $platform.Healthy) { throw "Unsupported platform: $($platform.Detail)" }
    $missing = @(Get-WwtComponentInventory -RepositoryRoot $RepositoryRoot | Where-Object { $_.required -and -not $_.capable -and $_.installStrategy -ne 'bundled-config' })
    if ($missing) { throw "Required dependencies are missing: $(($missing.id) -join ', ')." }

    $staging = Join-Path $paths.ProductRoot 'staging\config'
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    & (Join-Path $RepositoryRoot 'scripts\render-config.ps1') -OutputRoot $staging -MainModifier $MainModifier | Out-Null
    Add-WwtWallpaperBankToStaging -RepositoryRoot $RepositoryRoot -StagingRoot $staging
    if (-not $Apply) {
        return [pscustomobject]@{ Mode='Install'; Applied=$false; Staging=$staging; Message='Preflight passed; no live files changed. Use -Apply to deploy.' }
    }

    $existingState = $null
    if (Test-Path -LiteralPath $paths.StatePath) {
        $existingState = Get-Content -LiteralPath $paths.StatePath -Raw | ConvertFrom-Json
    }
    $existingFiles = @{}
    if ($null -ne $existingState) {
        foreach ($existingFile in @($existingState.files)) {
            $existingFiles[[string]$existingFile.destination] = $existingFile
        }
    }

    $operationId = [guid]::NewGuid().ToString('N')
    Set-WwtCheckpoint -RepositoryRoot $RepositoryRoot -Mode $OperationMode -Step preflight -OperationId $operationId | Out-Null
    Set-WwtCheckpoint -RepositoryRoot $RepositoryRoot -Mode $OperationMode -Step rendered -OperationId $operationId | Out-Null

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRoot = Join-Path $paths.BackupRoot $stamp
    $records = New-Object 'System.Collections.Generic.List[object]'
    if ($InjectFailureStage -eq 'config-deployment') { throw 'Injected failure during configuration deployment.' }
    $files = Get-ChildItem -LiteralPath $staging -File -Recurse
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($staging.Length).TrimStart('\')
        $destination = Join-Path $env:USERPROFILE $relative
        $priorRecord = if ($existingFiles.ContainsKey($destination)) { $existingFiles[$destination] } else { $null }
        Copy-WwtManagedFile -Source $file.FullName -Destination $destination -BackupRoot $backupRoot -Records $records -ExistingRecord $priorRecord
    }

    # The APO engine is machine-wide, but audio endpoint selection is local to
    # each PC. Deploy only portable policy; never record endpoint GUIDs.
    $equalizerConfigRoot = Join-Path $env:ProgramFiles 'EqualizerAPO\config'
    foreach ($name in @('config.txt','policy.json')) {
        $source = Join-Path $RepositoryRoot "config\equalizerapo\$name"
        $destination = Join-Path $equalizerConfigRoot $name
        $priorRecord = if ($existingFiles.ContainsKey($destination)) { $existingFiles[$destination] } else { $null }
        Copy-WwtManagedFile -Source $source -Destination $destination -BackupRoot $backupRoot -Records $records -ExistingRecord $priorRecord
    }

    # Reproduce the repository's canonical purple desktop on the first run.
    # Seed the exact palette so fresh machines do not vary with image decoder,
    # clustering, or cached-theme history, then let the normal theme engine
    # generate every dependent YASB/Komorebi/WezTerm/Oh My Posh file.
    $defaultWallpaper = Join-Path $env:USERPROFILE 'Pictures\Wallpapers\Anime-Purple-eyes.png'
    $defaultThemePath = Join-Path $env:USERPROFILE '.config\theme-engine\default-theme.json'
    $themeEngine = Join-Path $env:USERPROFILE '.config\theme-engine\theme-engine.ps1'
    if (-not (Test-Path -LiteralPath $defaultWallpaper) -or -not (Test-Path -LiteralPath $defaultThemePath) -or -not (Test-Path -LiteralPath $themeEngine)) {
        throw 'Canonical wallpaper or adaptive-theme payload is missing after deployment.'
    }
    $wallpaperHash = (Get-FileHash -LiteralPath $defaultWallpaper -Algorithm SHA256).Hash.ToLowerInvariant()
    $defaultTheme = Get-Content -LiteralPath $defaultThemePath -Raw | ConvertFrom-Json
    if ([string]$defaultTheme.wallpaperHash -ne $wallpaperHash) { throw 'Canonical wallpaper and default-theme hash disagree.' }
    $defaultTheme.wallpaper = $defaultWallpaper
    $themeCachePath = Join-Path $paths.ProductRoot "themes\cache\$wallpaperHash\palette.json"
    Write-WwtJson -Value $defaultTheme -Path $themeCachePath
    $themeArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Apply -Image "{1}" -NoReload' -f $themeEngine,$defaultWallpaper
    $themeProcess = Start-Process powershell.exe -ArgumentList $themeArguments -Wait -PassThru -WindowStyle Hidden
    if ($themeProcess.ExitCode -ne 0) { throw "Default adaptive theme failed with exit code $($themeProcess.ExitCode)." }
    Set-WwtDesktopWallpaper -Path $defaultWallpaper
    $priorDesktopIcons = if ($null -ne $existingState -and $existingState.PSObject.Properties.Name -contains 'desktopIcons') { $existingState.desktopIcons } else { $null }
    $desktopIcons = Install-WwtDesktopIconPreference -ExistingRecord $priorDesktopIcons

    # The theme engine intentionally rewrites managed outputs. Record their
    # final hashes, not the intermediate render, so uninstall removes them.
    foreach ($record in $records) {
        if (Test-Path -LiteralPath $record.destination) {
            $record.installedHash = (Get-FileHash -LiteralPath $record.destination -Algorithm SHA256).Hash
        }
    }
    Set-WwtCheckpoint -RepositoryRoot $RepositoryRoot -Mode $OperationMode -Step configuration-deployed -OperationId $operationId | Out-Null
    $priorStartup = if ($null -ne $existingState -and $existingState.PSObject.Properties.Name -contains 'startup') { $existingState.startup } else { $null }
    if ($InjectFailureStage -eq 'startup-registration') { throw 'Injected failure during startup registration.' }
    $startup = Install-WwtStartupOwnership -RepositoryRoot $RepositoryRoot -ExistingRecord $priorStartup
    Set-WwtCheckpoint -RepositoryRoot $RepositoryRoot -Mode $OperationMode -Step startup-owned -OperationId $operationId | Out-Null
    $installedAt = if ($null -ne $existingState -and $existingState.PSObject.Properties.Name -contains 'installedAt') { $existingState.installedAt } else { (Get-Date).ToString('o') }
    $state = [ordered]@{ schemaVersion=2; snapshotCommit=$SnapshotCommit; snapshotSha256=$SnapshotSha256; installedAt=$installedAt; updatedAt=(Get-Date).ToString('o'); repositoryRoot=$RepositoryRoot; mainModifier=$MainModifier; files=$records; startup=$startup; desktopIcons=$desktopIcons }
    Write-WwtJson -Value $state -Path $paths.StatePath
    Set-WwtCheckpoint -RepositoryRoot $RepositoryRoot -Mode $OperationMode -Step complete -Status complete -OperationId $operationId | Out-Null
    [pscustomobject]@{ Mode=$OperationMode; Applied=$true; State=$paths.StatePath; Files=$records.Count }
}

function Uninstall-WwtConfiguration {
    param([Parameter(Mandatory)][string]$RepositoryRoot, [switch]$Apply)
    $paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
    if (-not (Test-Path -LiteralPath $paths.StatePath)) { return [pscustomobject]@{ Mode='Uninstall'; Applied=$false; Message='No installation state exists.' } }
    $state = Get-Content -LiteralPath $paths.StatePath -Raw | ConvertFrom-Json
    if (-not $Apply) { return [pscustomobject]@{ Mode='Uninstall'; Applied=$false; Files=@($state.files).Count; Message='Uninstall preview only.' } }
    $themeManagedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($themeManagedPath in @(
        (Join-Path $env:USERPROFILE '.config\yasb\styles.theme.css'),
        (Join-Path $env:USERPROFILE '.config\yasb\styles.css'),
        (Join-Path $env:USERPROFILE '.config\yasb\config.yaml'),
        (Join-Path $env:USERPROFILE '.config\komorebi\komorebi.json'),
        (Join-Path $env:USERPROFILE '.wezterm.lua'),
        (Join-Path $env:USERPROFILE 'wwt-theme.lua'),
        (Join-Path $env:USERPROFILE '.config\ohmyposh\catppuccin_mocha.omp.json')
    )) { [void]$themeManagedPaths.Add($themeManagedPath) }
    foreach ($iconName in @('windows-logo.svg','cpu-neon.svg','ram-neon.svg','download-neon.svg','upload-neon.svg','volume-minimal.svg')) {
        [void]$themeManagedPaths.Add((Join-Path $env:USERPROFILE ".config\yasb\assets\$iconName"))
    }
    foreach ($record in @($state.files)) {
        if (-not (Test-Path -LiteralPath $record.destination)) { continue }
        $currentHash = (Get-FileHash -LiteralPath $record.destination -Algorithm SHA256).Hash
        if ($currentHash -ne $record.installedHash -and -not $themeManagedPaths.Contains([string]$record.destination)) { continue }
        Remove-Item -LiteralPath $record.destination -Force
        if ($record.backup -and (Test-Path -LiteralPath $record.backup)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $record.destination) -Force | Out-Null
            Copy-Item -LiteralPath $record.backup -Destination $record.destination -Force
        }
    }
    if ($state.PSObject.Properties.Name -contains 'startup' -and $state.startup) {
        Uninstall-WwtStartupOwnership -Record $state.startup
    }
    if ($state.PSObject.Properties.Name -contains 'desktopIcons' -and $state.desktopIcons) {
        Uninstall-WwtDesktopIconPreference -Record $state.desktopIcons
    }
    Remove-Item -LiteralPath $paths.StatePath -Force
    [pscustomobject]@{ Mode='Uninstall'; Applied=$true; Message='Managed unchanged files removed; recorded originals restored.' }
}

function Get-WwtComponentInventory {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $manifest = Read-WwtManifest -RepositoryRoot $RepositoryRoot
    foreach ($component in @($manifest.components)) {
        $paths = if ($component.PSObject.Properties.Name -contains 'detectionPaths') { @($component.detectionPaths) } else { @() }
        $found = Find-WwtCommand -Names @($component.commands) -DetectionPaths $paths
        $version = $null
        if ($found -and $component.PSObject.Properties.Name -contains 'versionCommand') {
            try {
                $output = & $found @($component.versionCommand.arguments) 2>$null | Select-Object -First 1
                if ($output -match [string]$component.versionCommand.pattern) { $version = $Matches[1] }
            } catch { $version = $null }
        }
        if ($found -and -not $version -and $component.PSObject.Properties.Name -contains 'packageId' -and $component.packageId) {
            $version = Get-WwtInstalledWingetVersion -PackageId ([string]$component.packageId)
        }
        if ($found -and -not $version -and $component.id -eq 'dwmblurglass') {
            try { $version = [string](Get-Item -LiteralPath $found).VersionInfo.ProductVersion } catch { $version = $null }
        }
        if ($found -and $component.id -eq 'equalizerapo') { $version = Get-WwtRegisteredDisplayVersion -DisplayName 'Equalizer APO' }
        $capable = [bool]$found
        if ($component.id -eq 'autohotkey' -and $found) { $capable = Test-WwtAutoHotkeyV2 -Path $found -Version $version }
        if ($component.id -eq 'yasb' -and $found) {
            $fingerprint = [string]$component.requiredFingerprint
            $marker = Join-Path (Split-Path -Parent $found) 'wwt-build.json'
            $capable = (Test-Path -LiteralPath $marker) -and ((Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash -eq $fingerprint)
        }
        if ($component.id -eq 'dwmblurglass' -and $found) {
            $task = Get-ScheduledTask -TaskName 'DWMBlurGlass_Extend' -ErrorAction SilentlyContinue
            $state = Join-Path (Get-WwtPaths -RepositoryRoot $RepositoryRoot).ProductRoot 'dwmblurglass-state.json'
            $expectedConfiguration = Join-Path $RepositoryRoot 'config\dwmblurglass\config.ini'
            $installedConfiguration = Join-Path (Split-Path -Parent $found) 'data\config.ini'
            $configurationMatches = (Test-Path -LiteralPath $expectedConfiguration) -and
                (Test-Path -LiteralPath $installedConfiguration) -and
                ((Get-FileHash -LiteralPath $expectedConfiguration -Algorithm SHA256).Hash -eq
                    (Get-FileHash -LiteralPath $installedConfiguration -Algorithm SHA256).Hash)
            $capable = [bool]$task -and (Test-Path -LiteralPath $state) -and $configurationMatches
        }
        if ($component.id -eq 'equalizerapo' -and $found) {
            $capable = [bool]$version -and $version.StartsWith(([string]$component.asset.version),[StringComparison]::OrdinalIgnoreCase)
        }
        if ($component.installStrategy -eq 'bundled-config') {
            $capable = @($paths).Count -gt 0 -and @($paths | Where-Object {
                -not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables([string]$_)))
            }).Count -eq 0
        }
        $recoverySource = $null
        if ($found -and $component.installStrategy -eq 'immutable-msi' -and $component.PSObject.Properties.Name -contains 'displayName') {
            $recoverySource = Get-WwtMsiRecoverySource -DisplayName ([string]$component.displayName)
            if (-not $version -and $recoverySource) { $version = [string]$recoverySource.Version }
        }
        [pscustomobject][ordered]@{
            id=[string]$component.id; required=[bool]$component.required; detected=[bool]$found
            capable=[bool]$capable; version=$version; path=$found; installStrategy=[string]$component.installStrategy
            packageId=if($component.PSObject.Properties.Name -contains 'packageId'){[string]$component.packageId}else{$null}
            recoverySource=if($recoverySource){[string]$recoverySource.Path}else{$null}
            recoverySha256=if($recoverySource){[string]$recoverySource.SHA256}else{$null}
        }
    }
}

function Get-WwtMsiRecoverySource {
    param([Parameter(Mandatory)][string]$DisplayName)
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
    foreach ($product in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $properties = Get-ItemProperty (Join-Path $product.PSPath 'InstallProperties') -ErrorAction SilentlyContinue
        if ($properties.DisplayName -eq $DisplayName -and $properties.LocalPackage -and (Test-Path -LiteralPath $properties.LocalPackage)) {
            return [pscustomobject]@{ Path=[string]$properties.LocalPackage; Version=[string]$properties.DisplayVersion; SHA256=(Get-FileHash -LiteralPath $properties.LocalPackage -Algorithm SHA256).Hash }
        }
    }
    return $null
}

function Get-WwtRegisteredDisplayVersion {
    param([Parameter(Mandatory)][string]$DisplayName)
    foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $record = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($record -and [string]$record.DisplayName -like "$DisplayName*") { return [string]$record.DisplayVersion }
        }
    }
    return $null
}

function Get-WwtInstalledWingetVersion {
    param([Parameter(Mandatory)][string]$PackageId)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { return $null }
    try {
        foreach ($line in @(& $winget.Source list --id $PackageId --exact --source winget --accept-source-agreements --disable-interactivity 2>$null)) {
            $text = [string]$line
            $index = $text.IndexOf($PackageId,[StringComparison]::OrdinalIgnoreCase)
            if ($index -lt 0) { continue }
            $tail = $text.Substring($index + $PackageId.Length).Trim()
            $tokens = @($tail -split '\s+' | Where-Object { $_ })
            if (@($tokens).Count -and $tokens[0] -match '^[0-9][0-9A-Za-z.+_-]*$') { return $tokens[0] }
        }
    } catch { return $null }
    return $null
}

function Test-WwtAutoHotkeyV2 {
    param([string]$Path,[string]$Version)
    [bool]($Path -match '[\\/]v2[\\/]' -or $Version -match '^2\.')
}

function Get-WwtManagedTargets {
    @(
        (Join-Path $env:USERPROFILE '.config\komorebi'),
        (Join-Path $env:USERPROFILE '.config\yasb'),
        (Join-Path $env:USERPROFILE '.config\theme-engine'),
        (Join-Path $env:USERPROFILE '.config\ohmyposh'),
        (Join-Path $env:USERPROFILE '.wezterm.lua'),
        (Join-Path $env:USERPROFILE 'wwt-theme.lua'),
        (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
    )
}

function Backup-WwtStack {
    param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$OperationId,[switch]$IncludeMachineState)
    $paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
    $root = Join-Path $paths.BackupRoot $OperationId
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $records = New-Object 'System.Collections.Generic.List[object]'
    $index = 0
    $recoveryTargets = @(Get-WwtManagedTargets)
    if($IncludeMachineState){$recoveryTargets += (Join-Path $env:ProgramFiles 'DWMBlurGlass')}
    foreach ($target in $recoveryTargets) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        $label = ('{0:D2}-{1}' -f $index,((Split-Path -Leaf $target) -replace '[^A-Za-z0-9._-]','_'))
        $index++
        $destination = Join-Path (Join-Path $root 'targets') $label
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $target -Destination $destination -Recurse -Force
        $records.Add([pscustomobject]@{ target=$target; backup=$destination; directory=(Get-Item -LiteralPath $target).PSIsContainer })
    }
    $state = Get-WwtPaths -RepositoryRoot $RepositoryRoot
    foreach ($path in @($state.StatePath,$state.OperationStatePath)) {
        if (Test-Path -LiteralPath $path) {
            $destination = Join-Path $root ('product-' + (Split-Path -Leaf $path))
            Copy-Item -LiteralPath $path -Destination $destination -Force
            $records.Add([pscustomobject]@{ target=$path; backup=$destination; directory=$false })
        }
    }
    $recordPath = Join-Path $root 'backup.json'
    Write-WwtJson -Value ([ordered]@{ schemaVersion=1; createdAt=(Get-Date).ToString('o'); records=$records }) -Path $recordPath
    if($IncludeMachineState){
        $tasks = New-Object 'System.Collections.Generic.List[object]'
        foreach ($taskName in @('Komorebi Delayed Startup','DWMBlurGlass_Extend')) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $tasks.Add([pscustomobject]@{ name=$taskName; existed=[bool]$task; xml=if($task){Export-ScheduledTask -TaskName $taskName}else{$null} })
        }
        $runPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';$runValues=[ordered]@{}
        $run=Get-ItemProperty -LiteralPath $runPath -ErrorAction SilentlyContinue
        foreach($name in @('KomorebiDesktopStack','YASB')){$runValues[$name]=if($run -and $run.PSObject.Properties.Name -contains $name){[string]$run.$name}else{$null}}
        Write-WwtJson -Value ([ordered]@{ schemaVersion=1; tasks=$tasks; runPath=$runPath; runValues=$runValues }) -Path (Join-Path $root 'startup.json')
    }
    [pscustomobject]@{ Root=$root; RecordPath=$recordPath; Records=$records }
}

function Restore-WwtStack {
    param([Parameter(Mandatory)][string]$BackupRecordPath)
    $backup = Get-Content -LiteralPath $BackupRecordPath -Raw | ConvertFrom-Json
    foreach ($record in @($backup.records)) {
        if (Test-Path -LiteralPath $record.target) { Remove-Item -LiteralPath $record.target -Recurse -Force }
        New-Item -ItemType Directory -Path (Split-Path -Parent $record.target) -Force | Out-Null
        Copy-Item -LiteralPath $record.backup -Destination $record.target -Recurse -Force
    }
    $startupPath=Join-Path (Split-Path -Parent $BackupRecordPath) 'startup.json'
    if(Test-Path $startupPath){
        $startup=Get-Content -LiteralPath $startupPath -Raw|ConvertFrom-Json
        foreach($task in @($startup.tasks)){
            Unregister-ScheduledTask -TaskName $task.name -Confirm:$false -ErrorAction SilentlyContinue
            if($task.existed -and $task.xml){Register-ScheduledTask -TaskName $task.name -Xml $task.xml -Force|Out-Null}
        }
        New-Item -Path $startup.runPath -Force|Out-Null
        foreach($property in $startup.runValues.PSObject.Properties){
            Remove-ItemProperty -LiteralPath $startup.runPath -Name $property.Name -ErrorAction SilentlyContinue
            if($null -ne $property.Value){Set-ItemProperty -LiteralPath $startup.runPath -Name $property.Name -Value ([string]$property.Value)}
        }
    }
}

function Remove-WwtManagedTargets {
    foreach ($target in @(Get-WwtManagedTargets)) {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    }
    $wallpaperRoot = Join-Path $env:USERPROFILE 'Pictures\Wallpapers'
    foreach ($wallpaperName in @('wwt-mountain-dawn.png','Anime-Purple-eyes.png','jakoolit-anime-purple-eyes.png')) {
        $wallpaper = Join-Path $wallpaperRoot $wallpaperName
        if (Test-Path -LiteralPath $wallpaper) { Remove-Item -LiteralPath $wallpaper -Force }
    }
}

function Install-WwtMissingDependencies {
    param([Parameter(Mandatory)][string]$RepositoryRoot,[switch]$ReinstallAll)
    $manifest = Read-WwtManifest -RepositoryRoot $RepositoryRoot
    $inventory = @(Get-WwtComponentInventory -RepositoryRoot $RepositoryRoot)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    foreach ($component in @($manifest.components)) {
        $current = @($inventory | Where-Object id -eq $component.id)[0]
        if ($component.installStrategy -eq 'guarded-dwm' -and $current.capable) { continue }
        if ($component.id -eq 'equalizerapo' -and $current.capable) { continue }
        if (-not $ReinstallAll -and $current.capable) { continue }
        if ($component.installStrategy -eq 'winget-stable') {
            if (-not $winget) { throw "WinGet is required to install '$($component.id)'." }
            $process = Start-Process -FilePath $winget.Source -ArgumentList @('install','--id',$component.packageId,'--exact','--source','winget','--force','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -Wait -PassThru -NoNewWindow
            if ($process.ExitCode -notin @(0,-1978335189)) { throw "WinGet failed installing '$($component.id)' with exit $($process.ExitCode)." }
        } elseif ($component.installStrategy -eq 'immutable-msi') {
            $paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
            $file = Join-Path $paths.ArtifactRoot ([string]$component.asset.file)
            New-Item -ItemType Directory -Path $paths.ArtifactRoot -Force | Out-Null
            if (-not (Test-Path $file) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne [string]$component.asset.sha256) {
                Invoke-WebRequest -UseBasicParsing -Uri $component.asset.url -OutFile $file
            }
            if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne [string]$component.asset.sha256) { throw "Hash mismatch for '$($component.id)'." }
            $process = Start-Process msiexec.exe -ArgumentList @('/i',$file,'/qn','/norestart') -Wait -PassThru
            if ($process.ExitCode -notin @(0,1641,3010)) { throw "MSI failed installing '$($component.id)' with exit $($process.ExitCode)." }
            if ($component.id -eq 'yasb') {
                $marker = [ordered]@{ assetSha256=[string]$component.asset.sha256; version=[string]$component.asset.version } | ConvertTo-Json -Compress
                [IO.File]::WriteAllText((Join-Path $env:ProgramFiles 'YASB\wwt-build.json'),$marker,(New-Object Text.UTF8Encoding($false)))
            }
        } elseif ($component.installStrategy -eq 'immutable-exe') {
            $paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
            $file = Join-Path $paths.ArtifactRoot ([string]$component.asset.file)
            New-Item -ItemType Directory -Path $paths.ArtifactRoot -Force | Out-Null
            if (-not (Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne [string]$component.asset.sha256) {
                $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
                if (-not $curl) { throw "curl.exe is required to download '$($component.id)' from SourceForge." }
                & $curl.Source @('-L','--fail','--retry','3','--output',$file,[string]$component.asset.url)
                if ($LASTEXITCODE -ne 0) { throw "Download failed for '$($component.id)' with exit $LASTEXITCODE." }
            }
            if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne [string]$component.asset.sha256) { throw "Hash mismatch for '$($component.id)'." }
            $process = Start-Process -FilePath $file -ArgumentList @($component.asset.silentArguments) -Wait -PassThru
            if ($process.ExitCode -notin @(0,1641,3010)) { throw "Installer failed for '$($component.id)' with exit $($process.ExitCode)." }
        } elseif ($component.installStrategy -eq 'guarded-dwm') {
            $paths = Get-WwtPaths -RepositoryRoot $RepositoryRoot
            $mapping = @($component.compatibility | Where-Object { [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber -ge [int]$_.minimumBuild -and [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber -le [int]$_.maximumBuild })[0]
            if (-not $mapping) { throw 'No tested DWMBlurGlass build supports this Windows build.' }
            $archive = Join-Path $paths.ArtifactRoot $mapping.file
            if (-not (Test-Path $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $mapping.sha256) {
                Invoke-WebRequest -UseBasicParsing -Uri $mapping.url -OutFile $archive
            }
            if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $mapping.sha256) { throw 'DWMBlurGlass archive hash mismatch.' }
            & (Join-Path $RepositoryRoot 'scripts\dwmblurglass-deploy.ps1') -Mode Install -ArchivePath $archive -StatePath (Join-Path $paths.ProductRoot 'dwmblurglass-state.json') -Apply
        }
    }
    @(Get-WwtComponentInventory -RepositoryRoot $RepositoryRoot)
}

function Uninstall-WwtDependencies {
    param([Parameter(Mandatory)][string]$RepositoryRoot,[switch]$PreserveGuardedDwm)
    $manifest = Read-WwtManifest -RepositoryRoot $RepositoryRoot
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    $components = @($manifest.components)
    for ($index = @($components).Count - 1; $index -ge 0; $index--) {
        $component = $components[$index]
        if ($PreserveGuardedDwm -and $component.installStrategy -eq 'guarded-dwm') { continue }
        if ($PreserveGuardedDwm -and $component.id -eq 'equalizerapo') { continue }

        # Kill the component again immediately before invoking its uninstaller.
        # This closes helpers that were started after the initial uninstall purge
        # (for example by a scheduled task or a package background service).
        $runtimeNames = @($component.commands | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension([string]$_) })
        switch ([string]$component.id) {
            'komorebi' { $runtimeNames += @('komorebic-no-console') }
            'autohotkey' { $runtimeNames += @('AutoHotkey','AutoHotkey32') }
            'wezterm' { $runtimeNames += @('wezterm-gui','wezterm-mux-server') }
            'dwmblurglass' { $runtimeNames += @('DWMBlurGlass','DWMBlurGlassHost') }
        }
        if (@($runtimeNames).Count) {
            Get-Process -Name ($runtimeNames | Select-Object -Unique) -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
        }
        $servicePattern = [regex]::Escape([string]$component.id) -replace '\\-','.?'
        Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $servicePattern -or $_.DisplayName -match $servicePattern } |
            ForEach-Object {
                Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue
                Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
            }
        Start-Sleep -Milliseconds 200

        if ($component.installStrategy -eq 'winget-stable' -and $winget) {
            Start-Process -FilePath $winget.Source -ArgumentList @('uninstall','--id',$component.packageId,'--exact','--silent','--disable-interactivity') -Wait -PassThru -NoNewWindow | Out-Null
        } elseif ($component.id -eq 'yasb' -and $component.productCode) {
            Start-Process msiexec.exe -ArgumentList @('/x',$component.productCode,'/qn','/norestart') -Wait -PassThru | Out-Null
        } elseif ($component.id -eq 'equalizerapo') {
            $uninstaller = Join-Path $env:ProgramFiles 'EqualizerAPO\Uninstall.exe'
            if (Test-Path -LiteralPath $uninstaller) {
                Start-Process -FilePath $uninstaller -ArgumentList @('/S') -Wait -PassThru | Out-Null
            }
        } elseif ($component.id -eq 'dwmblurglass') {
            $state = Join-Path (Get-WwtPaths $RepositoryRoot).ProductRoot 'dwmblurglass-state.json'
            if (Test-Path $state) {
                & (Join-Path $RepositoryRoot 'scripts\dwmblurglass-deploy.ps1') -Mode Uninstall -StatePath $state -Apply
            } else {
                Stop-ScheduledTask -TaskName 'DWMBlurGlass_Extend' -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName 'DWMBlurGlass_Extend' -Confirm:$false -ErrorAction SilentlyContinue
                $directory = Join-Path $env:ProgramFiles 'DWMBlurGlass'
                if (Test-Path $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
            }
        }
    }
}

Export-ModuleMember -Function Get-WwtPaths,Write-WwtLog,Set-WwtCheckpoint,Read-WwtManifest,Get-WwtHealth,Install-WwtConfiguration,Uninstall-WwtConfiguration,Get-WwtComponentInventory,Test-WwtAutoHotkeyV2,Get-WwtManagedTargets,Backup-WwtStack,Restore-WwtStack,Remove-WwtManagedTargets,Install-WwtMissingDependencies,Uninstall-WwtDependencies
